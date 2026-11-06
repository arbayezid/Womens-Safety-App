import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../models/safe_zone_model.dart';
import '../services/contact_service.dart';
import '../services/journey_service.dart';
import '../services/place_search_service.dart';
import '../services/route_service.dart';
import '../services/safe_zone_repository.dart';
import '../utils/duration_format.dart';

/// Modal bottom sheet for configuring and starting a new Safe Journey session.
class StartJourneySheet extends StatefulWidget {
  const StartJourneySheet({super.key});

  @override
  State<StartJourneySheet> createState() => _StartJourneySheetState();
}

class _StartJourneySheetState extends State<StartJourneySheet> {
  SafeZone? _selectedSafeZone;
  final TextEditingController _customDestController = TextEditingController();
  int _estimatedMinutes = 20;
  bool _notifySms = true;
  bool _isStarting = false;
  List<ContactModel> _guardians = [];
  Position? _currentPosition;
  List<SafeZone> _suggestedZones = [];

  // ── Road route preview ───────────────────────────────────────────────────
  JourneyTravelMode _travelMode = JourneyTravelMode.walking;
  JourneyRoute? _route;
  LatLng? _routeDest; // destination the route/ETA were computed for
  String? _routeLabel; // destination text the route/ETA were computed for
  String? _routeNotice; // why there is no road route (shown under the ETA)
  bool _loadingRoute = false;
  bool _etaAdjustedByUser = false;
  int _routeRequestId = 0;

  // ── Destination search-as-you-type ──────────────────────────────────────
  PlaceSuggestion? _selectedPlace; // picked from the suggestions
  List<PlaceSuggestion> _suggestions = const [];
  bool _searching = false;
  Timer? _searchDebounce;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    try {
      _currentPosition = await Geolocator.getLastKnownPosition();
      if (_currentPosition == null) {
        try {
          _currentPosition = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 5),
            ),
          );
        } catch (_) {}
      }
      final contacts = await ContactService.instance.getContacts();
      final repo = SafeZoneRepository.instance;
      await repo.loadSafeZones();
      if (!mounted) return;

      // Suggest the nearest safe zones when location is known
      final zones = _currentPosition != null
          ? repo.getNearestSafeZones(
              curLat: _currentPosition!.latitude,
              curLng: _currentPosition!.longitude,
              count: 5,
            )
          : repo.allSafeZones.take(5).toList();
      setState(() {
        _guardians = contacts;
        _suggestedZones = zones;
      });

      // Default to the first suggested safe zone if available
      if (zones.isNotEmpty) {
        _selectSafeZone(zones.first);
      }
    } catch (_) {}
  }

  void _selectSafeZone(SafeZone zone) {
    _searchDebounce?.cancel();
    _searchRequestId++;
    setState(() {
      _selectedSafeZone = zone;
      _selectedPlace = null;
      _suggestions = const [];
      _searching = false;
      _customDestController.text = zone.name;
    });
    _refreshRoute();
  }

  /// Destination text changed by typing: the chip selection and the old route no longer apply,
  /// and matching places are looked up after a short pause in typing.
  void _onDestinationTextChanged(String text) {
    final trimmed = text.trim();
    final stillZone = _selectedSafeZone != null && _selectedSafeZone!.name == trimmed;
    final stillPlace = _selectedPlace != null && _selectedPlace!.name == trimmed;
    if (!(stillZone || stillPlace) || _routeLabel != trimmed) {
      setState(() {
        if (!stillZone) _selectedSafeZone = null;
        if (!stillPlace) _selectedPlace = null;
        _route = null;
        _routeDest = null;
        _routeLabel = null;
        _routeNotice = null;
      });
    }

    _searchDebounce?.cancel();
    if (stillZone || stillPlace || trimmed.length < 2) {
      _searchRequestId++; // drop any search still in flight
      setState(() {
        _suggestions = const [];
        _searching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _runSearch(trimmed));
  }

  /// Fills the suggestion list: the app's own matching safe zones first, then map results.
  Future<void> _runSearch(String query) async {
    if (!mounted) return;
    final requestId = ++_searchRequestId;
    final lower = query.toLowerCase();
    final zoneMatches = SafeZoneRepository.instance.allSafeZones
        .where((z) => z.name.toLowerCase().contains(lower))
        .take(3)
        .map((z) => PlaceSuggestion(
              name: z.name,
              subtitle: z.address ?? 'Safe zone',
              latitude: z.latitude,
              longitude: z.longitude,
              isSafeZone: true,
            ))
        .toList();
    setState(() {
      _searching = true;
      _suggestions = zoneMatches;
    });

    final pos = _currentPosition;
    final places = await PlaceSearchService.instance.search(
      query,
      near: pos == null ? null : LatLng(pos.latitude, pos.longitude),
    );
    if (!mounted || requestId != _searchRequestId) return;

    final zoneNames = zoneMatches.map((z) => z.name.toLowerCase()).toSet();
    setState(() {
      _searching = false;
      _suggestions = [
        ...zoneMatches,
        ...places.where((p) => !zoneNames.contains(p.name.toLowerCase())),
      ].take(7).toList();
    });
  }

  /// User picked a suggestion: it becomes the destination and the route is calculated.
  void _selectSuggestion(PlaceSuggestion s) {
    FocusScope.of(context).unfocus();
    if (s.isSafeZone) {
      final zone = SafeZoneRepository.instance.allSafeZones
          .where((z) => z.name == s.name && z.latitude == s.latitude)
          .firstOrNull;
      if (zone != null) {
        _selectSafeZone(zone);
        return;
      }
    }
    _searchDebounce?.cancel();
    _searchRequestId++;
    setState(() {
      _selectedSafeZone = null;
      _selectedPlace = s;
      _suggestions = const [];
      _searching = false;
      _customDestController.text = s.name;
      _customDestController.selection = TextSelection.collapsed(offset: s.name.length);
    });
    _refreshRoute();
  }

  /// Search button / keyboard "search": take the top suggestion rather than guessing.
  void _submitDestination() {
    if (_suggestions.isNotEmpty) {
      _selectSuggestion(_suggestions.first);
    } else {
      FocusScope.of(context).unfocus();
      _refreshRoute();
    }
  }

  String _distanceFromUser(PlaceSuggestion s) {
    final pos = _currentPosition;
    if (pos == null) return '';
    return _formatDistance(
        JourneyService.haversineDistance(pos.latitude, pos.longitude, s.latitude, s.longitude));
  }

  IconData _suggestionIcon(PlaceSuggestion s) {
    if (s.isSafeZone) return Icons.shield_rounded;
    final c = s.category;
    if (c.contains('hospital') || c.contains('clinic') || c.contains('doctors')) return Icons.local_hospital_rounded;
    if (c.contains('police')) return Icons.local_police_rounded;
    if (c.startsWith('aeroway')) return Icons.flight_rounded;
    if (c.contains('school') || c.contains('college') || c.contains('university')) return Icons.school_rounded;
    if (c.contains('bus') || c.startsWith('railway') || c.contains('station')) return Icons.directions_bus_rounded;
    if (c.startsWith('highway')) return Icons.add_road_rounded;
    if (c.startsWith('place')) return Icons.location_city_rounded;
    if (c.startsWith('shop') || c.contains('retail') || c.contains('marketplace')) return Icons.storefront_rounded;
    return Icons.place_rounded;
  }

  void _selectTravelMode(JourneyTravelMode mode) {
    if (mode == _travelMode) return;
    setState(() => _travelMode = mode);
    _refreshRoute();
  }

  /// Where [label] is: the selected safe zone or suggestion, else the top place-search result
  /// (its real name is returned so the field shows which place was used).
  Future<({LatLng point, String label})?> _resolveDestination(String label) async {
    final zone = _selectedSafeZone;
    if (zone != null && zone.name == label) {
      return (point: LatLng(zone.latitude, zone.longitude), label: label);
    }
    final place = _selectedPlace;
    if (place != null && place.name == label) return (point: place.point, label: label);

    final pos = _currentPosition;
    final results = await PlaceSearchService.instance.search(
      label,
      near: pos == null ? null : LatLng(pos.latitude, pos.longitude),
      limit: 1,
    );
    if (results.isEmpty) return null;
    if (mounted) _selectedPlace = results.first;
    return (point: results.first.point, label: results.first.name);
  }

  /// Looks up the road route and travel time for the current destination and travel mode.
  Future<void> _refreshRoute() async {
    var label = _customDestController.text.trim();
    if (label.isEmpty) return;
    final requestId = ++_routeRequestId;
    final mode = _travelMode;
    setState(() {
      _loadingRoute = true;
      _routeNotice = null;
    });

    final resolved = await _resolveDestination(label);
    if (!mounted || requestId != _routeRequestId) return;
    final dest = resolved?.point;
    if (resolved != null && resolved.label != label) {
      // Show the place that was actually found, not the half-typed text
      label = resolved.label;
      _customDestController.text = label;
    }
    final pos = _currentPosition;
    JourneyRoute? route;
    if (dest != null && pos != null) {
      route = await RouteService.instance.fetchRoute(
        from: LatLng(pos.latitude, pos.longitude),
        to: dest,
        mode: mode,
      );
    }
    if (!mounted || requestId != _routeRequestId) return; // a newer request is running

    setState(() {
      _loadingRoute = false;
      _route = route;
      _routeDest = dest;
      _routeLabel = label;
      _etaAdjustedByUser = false;
      if (route != null) {
        _estimatedMinutes = route.durationMinutes;
      } else if (dest == null) {
        _routeNotice = 'Couldn\'t find "$label" on the map. Try a nearby landmark or area name from the '
            'suggestions, or set the time yourself and tap "I\'ve Arrived" when you get there.';
      } else if (pos == null) {
        _routeNotice = 'Your location isn\'t available yet, so this is a rough estimate.';
        _estimatedMinutes = 25;
      } else {
        _routeNotice = 'Road route unavailable (offline?). Using a straight-line estimate.';
        final meters = JourneyService.haversineDistance(pos.latitude, pos.longitude, dest.latitude, dest.longitude);
        // Roads are longer than the straight line; 1.3x is a common detour factor
        final minutes = JourneyService.estimateWalkingDurationMinutes(meters * 1.3);
        _estimatedMinutes = mode == JourneyTravelMode.vehicle ? (minutes / 2).ceil().clamp(5, 600) : minutes;
      }
    });
  }

  String _formatDistance(double meters) =>
      meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m';

  Future<void> _handleStartJourney() async {
    final destLabel = _customDestController.text.trim();
    if (destLabel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select or enter a destination.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isStarting = true);

    try {
      // Only use the safe zone's coordinates if the field still holds its name; a typed
      // destination is geocoded. If it can't be found the journey runs without a pin.
      // (A made-up pin can never be reached, so the journey would never end on its own.)
      final zone = (_selectedSafeZone != null && _selectedSafeZone!.name == destLabel)
          ? _selectedSafeZone
          : null;
      // Reuse the previewed route when it is for this destination and travel mode
      final previewValid = _routeLabel == destLabel && _routeDest != null;
      final dest = previewValid ? _routeDest : (await _resolveDestination(destLabel))?.point;
      final place = (_selectedPlace != null && _selectedPlace!.name == destLabel) ? _selectedPlace : null;
      final route = previewValid && _route?.mode == _travelMode ? _route : null;
      final double? destLat = dest?.latitude;
      final double? destLng = dest?.longitude;
      final hasPin = destLat != null && destLng != null;

      final guardianUids = _guardians
          .where((g) => g.contactUid != null && g.contactUid!.isNotEmpty)
          .map((g) => g.contactUid!)
          .toList();
      final guardianEmails = _guardians
          .where((g) => g.email.isNotEmpty)
          .map((g) => g.email.toLowerCase().trim())
          .toList();

      final destinationMap = {
        if (hasPin) 'latitude': destLat,
        if (hasPin) 'longitude': destLng,
        'label': destLabel,
        'address': zone?.address ??
            (place != null && place.subtitle.isNotEmpty ? '${place.name}, ${place.subtitle}' : destLabel),
      };

      await JourneyService.instance.startJourney(
        destination: destinationMap,
        customEstimatedMinutes: _estimatedMinutes,
        notifySms: _notifySms,
        guardianUids: guardianUids,
        guardianEmails: guardianEmails,
        route: route,
        travelMode: _travelMode,
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.directions_walk_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hasPin
                      ? '🚶 Safe Journey active! Monitoring route & Dead-Man\'s switch.'
                      : '🚶 Safe Journey active. "$destLabel" isn\'t on the map, so tap "I\'ve Arrived" when you get there.',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.actionGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start journey: $e', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _customDestController.dispose();
    super.dispose();
  }

  /// Suggestions shown under the destination field while typing.
  Widget _buildSuggestionList() {
    if (_suggestions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < _suggestions.length; i++) ...[
            if (i > 0) Divider(height: 1, color: Colors.black.withValues(alpha: 0.05)),
            InkWell(
              onTap: () => _selectSuggestion(_suggestions[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _suggestions[i].isSafeZone ? const Color(0xFFDFF5E3) : AppColors.background,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _suggestionIcon(_suggestions[i]),
                        size: 18,
                        color: _suggestions[i].isSafeZone ? AppColors.actionGreen : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _suggestions[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                          ),
                          if (_suggestions[i].subtitle.isNotEmpty)
                            Text(
                              _suggestions[i].subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _distanceFromUser(_suggestions[i]),
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeChip(JourneyTravelMode mode, IconData icon, String label) {
    final selected = _travelMode == mode;
    return Expanded(
      child: ChoiceChip(
        avatar: Icon(icon, size: 18, color: selected ? AppColors.primary : AppColors.textSecondary),
        label: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
        ),
        selected: selected,
        showCheckmark: false,
        onSelected: _loadingRoute ? null : (_) => _selectTravelMode(mode),
        selectedColor: AppColors.primarySurface,
        backgroundColor: AppColors.background,
        labelStyle: TextStyle(color: selected ? AppColors.primary : AppColors.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? AppColors.primary : Colors.black.withValues(alpha: 0.08)),
        ),
      ),
    );
  }

  /// Small, non-interactive map of the road route, plus distance or the reason there is none.
  Widget _buildRoutePreview() {
    final route = _route;
    final pos = _currentPosition;
    if (_loadingRoute) {
      return Container(
        height: 56,
        margin: const EdgeInsets.only(bottom: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            ),
            const SizedBox(width: 10),
            Text('Finding the road route…', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    if (route == null || pos == null || _routeDest == null) {
      final notice = _routeNotice;
      if (notice == null) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7ED),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.actionOrange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(notice, style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textPrimary, height: 1.4)),
            ),
          ],
        ),
      );
    }

    final points = route.points;
    final start = LatLng(pos.latitude, pos.longitude);
    final dest = _routeDest!;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 160,
            child: FlutterMap(
              // New key = new map, so the camera re-fits when the route changes
              key: ValueKey('${route.mode.name}:${route.polyline.hashCode}'),
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints([...points, start, dest]),
                  padding: const EdgeInsets.all(28),
                ),
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.smart_safety.app',
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: points,
                      strokeWidth: 5,
                      color: AppColors.primary,
                      borderStrokeWidth: 1.5,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: start,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.actionBlue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                    Marker(
                      point: dest,
                      width: 30,
                      height: 30,
                      child: const Icon(Icons.flag_circle_rounded, color: AppColors.actionGreen, size: 30),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: AppColors.background,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.route_rounded, size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_formatDistance(route.distanceMeters)} by road • ${formatMinutes(route.durationMinutes)}',
                    style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('© OpenStreetMap', style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDFF5E3),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.shield_rounded, color: AppColors.actionGreen, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Start Safe Journey',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Live route tracking with Dead-Man\'s Switch',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Quick Safe Zones Chips
            Text(
              'Select Destination or Safe Zone',
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),

            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _suggestedZones.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final zone = _suggestedZones[i];
                  final isSelected = _selectedSafeZone?.id == zone.id;
                  return ChoiceChip(
                    label: Text(zone.name, style: GoogleFonts.poppins(fontSize: 12, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                    selected: isSelected,
                    onSelected: (_) => _selectSafeZone(zone),
                    selectedColor: AppColors.primarySurface,
                    backgroundColor: AppColors.background,
                    labelStyle: TextStyle(
                      color: isSelected ? AppColors.primary : AppColors.textPrimary,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isSelected ? AppColors.primary : Colors.black.withValues(alpha: 0.08),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // Destination Input field
            TextField(
              controller: _customDestController,
              textInputAction: TextInputAction.search,
              onChanged: _onDestinationTextChanged,
              onSubmitted: (_) => _submitDestination(),
              decoration: InputDecoration(
                labelText: 'Destination Name / Location',
                hintText: 'Search a place, area or landmark',
                prefixIcon: const Icon(Icons.place_rounded, color: AppColors.primary),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Find route',
                        icon: const Icon(Icons.directions_rounded, color: AppColors.primary),
                        onPressed: _loadingRoute ? null : _submitDestination,
                      ),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              style: GoogleFonts.poppins(fontSize: 14),
            ),
            _buildSuggestionList(),
            const SizedBox(height: 14),

            // Travel mode
            Row(
              children: [
                _buildModeChip(JourneyTravelMode.walking, Icons.directions_walk_rounded, 'Walking'),
                const SizedBox(width: 8),
                _buildModeChip(JourneyTravelMode.vehicle, Icons.directions_car_rounded, 'Rickshaw / Car'),
              ],
            ),
            const SizedBox(height: 14),

            // Road route preview
            _buildRoutePreview(),

            // Travel time (from the road route; adjustable)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_rounded, color: AppColors.actionOrange, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _travelMode == JourneyTravelMode.walking
                              ? 'Estimated Walking Time'
                              : 'Estimated Travel Time',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        _loadingRoute
                            ? Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Text(
                                  'Calculating…',
                                  style: GoogleFonts.poppins(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              )
                            : Text(
                                formatMinutes(_estimatedMinutes, suffix: ' mins'),
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                        if (!_loadingRoute && _route != null)
                          Text(
                            _etaAdjustedByUser
                                ? 'Adjusted (road route: ${formatMinutes(_route!.durationMinutes)})'
                                : _travelMode == JourneyTravelMode.vehicle
                                    ? 'By road, with traffic allowance'
                                    : 'By road',
                            style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: _estimatedMinutes > 5 && !_loadingRoute
                        ? () => setState(() {
                              _estimatedMinutes -= 5;
                              _etaAdjustedByUser = true;
                            })
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: _loadingRoute
                        ? null
                        : () => setState(() {
                              _estimatedMinutes += 5;
                              _etaAdjustedByUser = true;
                            }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // SMS Checkbox Tile
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Send SMS to trusted contacts',
                style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Alerts phone contacts on start and arrival',
                style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
              ),
              value: _notifySms,
              activeTrackColor: AppColors.actionGreen,
              onChanged: (val) => setState(() => _notifySms = val),
            ),
            const SizedBox(height: 18),

            // Start Button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _isStarting || _loadingRoute ? null : _handleStartJourney,
                icon: _isStarting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.directions_walk_rounded, color: Colors.white, size: 22),
                label: Text(
                  _isStarting ? 'Starting Journey...' : 'START SAFE JOURNEY',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.actionGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
