import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../core/app_colors.dart';
import '../models/safe_zone_model.dart';
import '../services/location_service.dart';
import '../utils/url_launcher_helper.dart';

/// Available map tile styling presets.
enum MapTileTheme {
  standard(
    name: 'OpenStreetMap',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    icon: Icons.map_rounded,
  ),
  voyager(
    name: 'CartoDB Voyager',
    urlTemplate: 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
    icon: Icons.travel_explore_rounded,
  ),
  dark(
    name: 'CartoDB Dark',
    urlTemplate: 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    icon: Icons.dark_mode_rounded,
  );

  final String name;
  final String urlTemplate;
  final IconData icon;

  const MapTileTheme({
    required this.name,
    required this.urlTemplate,
    required this.icon,
  });
}

/// Dynamic, interactive Map screen with real GPS geolocation, dynamic distance
/// calculation, interactive safe zone pins, Google Maps turn-by-turn navigation,
/// safe corridor routing, and tile layer switching.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  /// Converts decimal coordinates into degree-minute format (e.g. 23°48'N  90°24'E).
  static String formatDegreeMinutes(double lat, double lng) {
    String formatPart(double val, String posDir, String negDir) {
      final dir = val >= 0 ? posDir : negDir;
      final abs = val.abs();
      final deg = abs.floor();
      final min = ((abs - deg) * 60).round();
      return '$deg°$min\'$dir';
    }

    return '${formatPart(lat, 'N', 'S')}  ${formatPart(lng, 'E', 'W')}';
  }

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with TickerProviderStateMixin {
  // Default coordinates: Banani, Dhaka, Bangladesh
  static const LatLng _defaultDhakaCoords = LatLng(23.7937, 90.4066);

  final MapController _mapController = MapController();

  bool _safeRouteEnabled = true;
  bool _isLoadingLocation = false;
  MapTileTheme _currentTileTheme = MapTileTheme.standard;

  LatLng _userPosition = _defaultDhakaCoords;
  String _currentAddress = 'Road 11, Banani, Dhaka';
  String _formattedCoords = '23°48\'N  90°24\'E';
  String _currentAreaName = 'Banani, Dhaka';

  SafeZone? _selectedZone;
  List<SafeZone> _allSafeZones = SafeZone.defaultDhakaSafeZones;
  List<SafeZone> _sortedZones = [];

  late AnimationController _pingController;
  late Animation<double> _pingAnimation;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    _pingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();

    _pingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pingController, curve: Curves.easeOut),
    );

    // Initial safe zones sorting using default Banani coordinates
    _recalculateSafeZones();

    // Check if LocationService already has cached data
    final cached = LocationService.instance.lastKnownLocation;
    if (cached != null) {
      _applyLocationData(
        LatLng(cached.latitude, cached.longitude),
        cached.formattedAddress,
      );
    }

    // Load custom database from assets if available, then acquire live GPS
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadSafeZonesDatabase();
      _fetchLiveLocation(animateCamera: true);
    });
  }

  /// Loads custom safe zones catalog from assets/data/safe_zones.json
  Future<void> _loadSafeZonesDatabase() async {
    try {
      final jsonString =
          await rootBundle.loadString('assets/data/safe_zones.json');
      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;
      final loaded = jsonList
          .map((item) => SafeZone.fromJson(item as Map<String, dynamic>))
          .toList();
      if (loaded.isNotEmpty && mounted) {
        setState(() {
          _allSafeZones = loaded;
          _recalculateSafeZones();
        });
      }
    } catch (e) {
      debugPrint('[MapScreen] Using default in-memory safe zone catalog ($e)');
    }
  }

  @override
  void dispose() {
    _pingController.dispose();
    super.dispose();
  }

  /// Applies fresh location coordinates and reverse-geocoded address segments.
  void _applyLocationData(LatLng position, String address) {
    setState(() {
      _userPosition = position;
      _currentAddress = address;
      _formattedCoords =
          MapScreen.formatDegreeMinutes(position.latitude, position.longitude);

      // Extract short area name for the map pill overlay
      final parts = address.split(',');
      if (parts.length >= 2) {
        _currentAreaName = '${parts[0].trim()}, ${parts[1].trim()}';
      } else if (parts.isNotEmpty) {
        _currentAreaName = parts[0].trim();
      } else {
        _currentAreaName = 'Dhaka, Bangladesh';
      }

      _recalculateSafeZones();
    });
  }

  /// Fetches live GPS position and updates the map view accordingly.
  Future<void> _fetchLiveLocation({bool animateCamera = false}) async {
    if (_isLoadingLocation) return;

    setState(() => _isLoadingLocation = true);

    try {
      final result = await LocationService.instance.getCurrentLocation();
      if (result.isSuccess && result.data != null) {
        final loc = result.data!;
        final newPos = LatLng(loc.latitude, loc.longitude);
        _applyLocationData(newPos, loc.formattedAddress);

        if (animateCamera && mounted) {
          _animatedMapMove(newPos, 15.0);
        }
      } else if (mounted && result.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage!),
            backgroundColor: AppColors.sosRed,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('[MapScreen] Live GPS fetch error: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingLocation = false);
      }
    }
  }

  /// Recalculates distances from the user's live position to all safe zones
  /// and sorts them in ascending order of proximity.
  void _recalculateSafeZones() {
    final zones = List<SafeZone>.from(_allSafeZones);

    // If Safe Route Mode is active, prioritize police stations and checkpoints
    if (_safeRouteEnabled) {
      zones.sort((a, b) {
        final distA = a.calculateDistanceKm(_userPosition.latitude, _userPosition.longitude);
        final distB = b.calculateDistanceKm(_userPosition.latitude, _userPosition.longitude);

        // Police stations first when safe route is engaged
        if (a.type == SafeZoneType.police && b.type != SafeZoneType.police) return -1;
        if (b.type == SafeZoneType.police && a.type != SafeZoneType.police) return 1;

        return distA.compareTo(distB);
      });
    } else {
      zones.sort((a, b) {
        final distA = a.calculateDistanceKm(_userPosition.latitude, _userPosition.longitude);
        final distB = b.calculateDistanceKm(_userPosition.latitude, _userPosition.longitude);
        return distA.compareTo(distB);
      });
    }

    _sortedZones = zones;
  }

  /// Smoothly animates the map camera to the target coordinate and zoom level.
  void _animatedMapMove(LatLng destLocation, double destZoom) {
    final camera = _mapController.camera;
    final latTween = Tween<double>(
      begin: camera.center.latitude,
      end: destLocation.latitude,
    );
    final lngTween = Tween<double>(
      begin: camera.center.longitude,
      end: destLocation.longitude,
    );
    final zoomTween = Tween<double>(
      begin: camera.zoom,
      end: destZoom,
    );

    final controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    final animation = CurvedAnimation(
      parent: controller,
      curve: Curves.fastOutSlowIn,
    );

    controller.addListener(() {
      _mapController.move(
        LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
        zoomTween.evaluate(animation),
      );
    });

    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        controller.dispose();
      }
    });

    controller.forward();
  }

  /// Cycles between available map tile themes (OSM -> Voyager -> Dark).
  void _toggleMapTileTheme() {
    final nextIndex = (_currentTileTheme.index + 1) % MapTileTheme.values.length;
    final newTheme = MapTileTheme.values[nextIndex];
    setState(() {
      _currentTileTheme = newTheme;
    });

    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(newTheme.icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text('Layer changed to ${newTheme.name}'),
          ],
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Selects a safe zone and focuses the map camera onto it.
  void _selectZone(SafeZone zone) {
    setState(() => _selectedZone = zone);
    _animatedMapMove(zone.latLng, 16.0);
  }

  /// Computes a safe corridor route line from the user position to the nearest police station.
  List<LatLng> _getSafeCorridorPoints() {
    final policeZones = _sortedZones.where((z) => z.type == SafeZoneType.police);
    if (policeZones.isEmpty) return [];

    final nearestPolice = policeZones.first;
    // Generate an interpolated safe waypoint simulating street corridor
    final midLat = (_userPosition.latitude + nearestPolice.latitude) / 2;
    final midLng = (_userPosition.longitude + nearestPolice.longitude) / 2;

    return [
      _userPosition,
      LatLng(midLat, _userPosition.longitude), // Right-angle street alignment
      LatLng(midLat, midLng),
      nearestPolice.latLng,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────
            _buildHeader(),

            // ── Interactive Map View ──────────────────────────────────
            _buildInteractiveMap(),

            // ── Dynamic Bottom Panel ──────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLocationInfoCard(),
                    const SizedBox(height: 16),
                    _buildSafeRouteToggle(),
                    const SizedBox(height: 20),
                    _buildSafeZonesSection(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          Text(
            'Live Map',
            style: GoogleFonts.poppins(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          // Recenter / GPS Refresh Button
          _IconBtn(
            icon: _isLoadingLocation
                ? Icons.sync_rounded
                : Icons.my_location_rounded,
            color: AppColors.primary,
            onTap: () => _fetchLiveLocation(animateCamera: true),
          ),
          const SizedBox(width: 8),
          // Layer Theme Switcher Button
          _IconBtn(
            icon: _currentTileTheme.icon,
            color: AppColors.textSecondary,
            onTap: _toggleMapTileTheme,
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveMap() {
    final corridorPoints = _safeRouteEnabled ? _getSafeCorridorPoints() : <LatLng>[];

    return Container(
      height: 270,
      margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // ── FlutterMap Core Engine ────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userPosition,
              initialZoom: 14.5,
              minZoom: 3.0,
              maxZoom: 18.5,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              // Tile Layer
              TileLayer(
                urlTemplate: _currentTileTheme.urlTemplate,
                userAgentPackageName: 'com.example.smart_safety',
                maxZoom: 19,
              ),

              // Safe Route Polyline Corridor (when enabled)
              if (_safeRouteEnabled && corridorPoints.isNotEmpty) ...[
                // Glowing background aura for safe corridor
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: corridorPoints,
                      strokeWidth: 9.0,
                      color: AppColors.primary.withValues(alpha: 0.3),
                    ),
                    Polyline(
                      points: corridorPoints,
                      strokeWidth: 4.5,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ],

              // Safe Zone & User Position Markers
              MarkerLayer(
                markers: [
                  // Safe Zone Markers
                  ..._sortedZones.map((zone) {
                    final isSelected = _selectedZone?.id == zone.id;
                    return Marker(
                      point: zone.latLng,
                      width: 90,
                      height: 52,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: () => _selectZone(zone),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2.5),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primary
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 5,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                zone.name.length > 12
                                    ? '${zone.name.substring(0, 11)}…'
                                    : zone.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? Colors.white
                                      : AppColors.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Icon(
                              Icons.location_pin,
                              color: zone.iconColor,
                              size: 22,
                            ),
                          ],
                        ),
                      ),
                    );
                  }),

                  // Dynamic Live User Pulsing Marker
                  Marker(
                    point: _userPosition,
                    width: 80,
                    height: 80,
                    alignment: Alignment.center,
                    child: AnimatedBuilder(
                      animation: _pingAnimation,
                      builder: (_, __) {
                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            // Outer Ping Ring
                            Opacity(
                              opacity:
                                  (1.0 - _pingAnimation.value).clamp(0.0, 1.0),
                              child: Container(
                                width: 80 * _pingAnimation.value,
                                height: 80 * _pingAnimation.value,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary
                                      .withValues(alpha: 0.25),
                                ),
                              ),
                            ),
                            // Mid Accuracy Circle
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary
                                    .withValues(alpha: 0.15),
                                border: Border.all(
                                  color: AppColors.primary
                                      .withValues(alpha: 0.4),
                                  width: 1,
                                ),
                              ),
                            ),
                            // Center User Location Dot
                            Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary
                                        .withValues(alpha: 0.5),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),

          // ── Map Location Pill Overlay (Top Left) ──────────────────
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.map_rounded,
                      size: 13, color: AppColors.primary),
                  const SizedBox(width: 5),
                  Text(
                    _currentAreaName,
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Safe Route Active Indicator Pill (Top Right) ──────────
          if (_safeRouteEnabled)
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.successBackground.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.successForeground.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.successForeground,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Safe Corridor Active',
                      style: GoogleFonts.poppins(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.successForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Loading GPS Overlay ───────────────────────────────────
          if (_isLoadingLocation)
            Positioned(
              bottom: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Updating GPS...',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocationInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.location_on_rounded,
              color: AppColors.primary,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current Location',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _currentAddress,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.successBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Safe Zone',
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.successForeground,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formattedCoords,
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSafeRouteToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _safeRouteEnabled
              ? [AppColors.primary, AppColors.primaryLight]
              : [const Color(0xFFEEEEF2), const Color(0xFFE5E5EA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: _safeRouteEnabled
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ]
            : [],
      ),
      child: Row(
        children: [
          Icon(
            Icons.route_rounded,
            color: _safeRouteEnabled ? Colors.white : AppColors.textSecondary,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Safe Route Mode',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _safeRouteEnabled
                        ? Colors.white
                        : AppColors.textPrimary,
                  ),
                ),
                Text(
                  _safeRouteEnabled
                      ? 'Corridor to nearest police station active'
                      : 'Tap to activate safe routing',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: _safeRouteEnabled
                        ? Colors.white.withValues(alpha: 0.8)
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _safeRouteEnabled,
            onChanged: (val) {
              setState(() {
                _safeRouteEnabled = val;
                _recalculateSafeZones();
              });
            },
            activeThumbColor: Colors.white,
            activeTrackColor: Colors.white.withValues(alpha: 0.4),
            inactiveThumbColor: AppColors.textSecondary,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
          ),
        ],
      ),
    );
  }

  Widget _buildSafeZonesSection() {
    final zonesToDisplay = _sortedZones.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Nearby Safe Zones',
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${zonesToDisplay.length} Available',
                style: GoogleFonts.poppins(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...zonesToDisplay.map((zone) {
          final distKm = zone.calculateDistanceKm(
            _userPosition.latitude,
            _userPosition.longitude,
          );
          final distanceStr = SafeZone.formatDistance(distKm);
          final isSelected = _selectedZone?.id == zone.id;

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SafeZoneCard(
              zone: zone,
              distanceStr: distanceStr,
              isSelected: isSelected,
              onTapCard: () => _selectZone(zone),
              onTapNavigate: () => _launchNavigation(zone),
            ),
          );
        }),
      ],
    );
  }

  /// Triggers native turn-by-turn navigation in Google Maps.
  Future<void> _launchNavigation(SafeZone zone) async {
    final launched = await UrlLauncherHelper.openMapNavigation(
      zone.latitude,
      zone.longitude,
    );

    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open navigation to ${zone.name}.'),
          backgroundColor: AppColors.sosRed,
        ),
      );
    }
  }
}

// ─── Sub-widgets ────────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _IconBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

class _SafeZoneCard extends StatelessWidget {
  final SafeZone zone;
  final String distanceStr;
  final bool isSelected;
  final VoidCallback onTapCard;
  final VoidCallback onTapNavigate;

  const _SafeZoneCard({
    required this.zone,
    required this.distanceStr,
    required this.isSelected,
    required this.onTapCard,
    required this.onTapNavigate,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTapCard,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? Border.all(color: AppColors.primary, width: 1.5)
              : Border.all(color: Colors.transparent, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: isSelected ? 14 : 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: zone.bgColor,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(zone.icon, color: zone.iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    zone.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        zone.type.label,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      if (zone.isVerifiedCheckpoint &&
                          zone.type == SafeZoneType.police) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.successBackground,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '24/7 Patrol',
                            style: GoogleFonts.poppins(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: AppColors.successForeground,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  distanceStr,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: onTapNavigate,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      'Navigate',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.actionBlue,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
