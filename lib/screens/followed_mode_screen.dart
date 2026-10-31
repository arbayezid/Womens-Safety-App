import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../core/app_colors.dart';
import '../models/journey_model.dart';
import '../models/safe_zone_model.dart';
import '../services/emergency_service.dart';
import '../services/journey_service.dart';
import '../services/live_tracking_service.dart';
import '../services/location_service.dart';
import '../services/navigation_service.dart';
import '../services/pin_security_service.dart';
import '../services/safe_zone_repository.dart';
import '../services/siren_service.dart';
import '../widgets/fake_call_dialog.dart';
import '../widgets/pin_input_dialog.dart';

/// Active command interface for "I'm Being Followed" Mode.
///
/// Provides rapid turn-by-turn navigation to the nearest police station,
/// instant and scheduled fake call deterrence, loud siren toggle,
/// one-tap manual SOS escalation, and duress-aware safety resolution.
class FollowedModeScreen extends StatefulWidget {
  const FollowedModeScreen({super.key});

  @override
  State<FollowedModeScreen> createState() => _FollowedModeScreenState();
}

class _FollowedModeScreenState extends State<FollowedModeScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  late AnimationController _pulseController;
  late Animation<double> _pulseScale;

  Timer? _secondTimer;
  Timer? _fakeCall30sTimer;
  int _fakeCallCountdown = 0;

  bool _isSosLoading = false;
  bool _isResolving = false;
  bool _isSirenActive = false;

  Position? _devicePosition;
  StreamSubscription<Position>? _positionSub;
  bool _isLoadingLocation = true;
  bool _hasCenteredMap = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 0.90, end: 1.10).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _secondTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    SafeZoneRepository.instance.loadSafeZones().then((_) {
      if (mounted) setState(() {});
    });

    _acquireLiveLocation();
  }

  Future<void> _acquireLiveLocation() async {
    // 1. First check if LocationService already holds a valid fix
    final cached = LocationService.instance.lastKnownLocation;
    if (cached != null && mounted) {
      setState(() {
        _devicePosition = Position(
          latitude: cached.latitude,
          longitude: cached.longitude,
          timestamp: cached.timestamp,
          accuracy: 0,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
        _isLoadingLocation = false;
      });
      if (!_hasCenteredMap) {
        _hasCenteredMap = true;
        _mapController.move(LatLng(cached.latitude, cached.longitude), 15.0);
      }
    }

    // 2. Fetch fresh high-accuracy position
    try {
      final livePos = await LocationService.instance.getCurrentPositionHighAccuracy();
      if (livePos != null && mounted) {
        setState(() {
          _devicePosition = livePos;
          _isLoadingLocation = false;
        });
        if (!_hasCenteredMap) {
          _hasCenteredMap = true;
          _mapController.move(LatLng(livePos.latitude, livePos.longitude), 15.0);
        }
      }
    } catch (_) {}

    // 3. Listen to position stream for live movement
    _positionSub = LocationService.instance.positionStream.listen((pos) {
      if (mounted) {
        setState(() {
          _devicePosition = pos;
          _isLoadingLocation = false;
        });
        if (!_hasCenteredMap) {
          _hasCenteredMap = true;
          _mapController.move(LatLng(pos.latitude, pos.longitude), 15.0);
        }
      }
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _secondTimer?.cancel();
    _fakeCall30sTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatElapsed(DateTime startTime) {
    final diff = DateTime.now().difference(startTime);
    if (diff.isNegative) return '0s';
    final m = diff.inMinutes;
    final s = diff.inSeconds % 60;
    return '${m}m ${s}s';
  }

  void _scheduleFakeCallIn30s() {
    if (_fakeCallCountdown > 0) return;

    HapticFeedback.mediumImpact();
    setState(() => _fakeCallCountdown = 30);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '⏱️ Fake Call scheduled in 30 seconds. Act natural!',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.actionPurple,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );

    _fakeCall30sTimer?.cancel();
    _fakeCall30sTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_fakeCallCountdown <= 1) {
        timer.cancel();
        setState(() => _fakeCallCountdown = 0);
        FakeCallDialog.show(context);
      } else {
        setState(() => _fakeCallCountdown--);
      }
    });
  }

  Future<void> _toggleLoudSiren() async {
    HapticFeedback.heavyImpact();
    final isNowPlaying = await SirenService.instance.toggleSiren();
    if (!mounted) return;
    setState(() => _isSirenActive = isNowPlaying);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isNowPlaying ? '📢 Loud Siren Activated!' : '🔇 Siren Deactivated',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: isNowPlaying ? AppColors.sosRed : AppColors.textPrimary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _sendSosNow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.emergency_rounded, color: AppColors.sosRed, size: 28),
            const SizedBox(width: 8),
            Text(
              'Dispatch Emergency SOS?',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ],
        ),
        content: Text(
          'This will immediately broadcast an active emergency SOS alert to all your guardians, send offline SMS messages, and initiate escalation.',
          style: GoogleFonts.poppins(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sosRed,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('DISPATCH SOS', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isSosLoading = true);
    HapticFeedback.heavyImpact();

    try {
      final activeJourney = JourneyService.instance.activeJourney;
      await EmergencyService.instance.triggerEmergency(
        source: 'FOLLOWED_SOS',
        customMessage: 'EMERGENCY: User activated Followed Mode and pressed Emergency SOS! Immediate response needed.',
        linkedJourneyId: activeJourney?.id,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '🚨 Emergency SOS Dispatched to Guardians!',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
          ),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSosLoading = false);
    }
  }

  Future<void> _handleConfirmSafe() async {
    final isPinEnabled = await PinSecurityService.instance.isPinEnabled();
    final isRealConfigured = await PinSecurityService.instance.isRealPinConfigured();

    if (isPinEnabled && isRealConfigured) {
      if (!mounted) return;
      final verified = await PinInputDialog.show(
        context,
        mode: PinDialogMode.verify,
        customTitle: 'Verify Safety',
        customSubtitle: 'Enter Security PIN to end Followed Mode safely',
      );
      if (verified != true || !mounted) return;
    } else {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.shield_rounded, color: AppColors.safeGreen, size: 26),
              const SizedBox(width: 8),
              Text(
                'Are you safe now?',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 17),
              ),
            ],
          ),
          content: Text(
            'Confirming safety will end Followed Mode, stop live GPS broadcasting, and inform your guardians that you are safe.',
            style: GoogleFonts.poppins(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.safeGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('I Am Safe', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;
    }

    setState(() => _isResolving = true);
    HapticFeedback.heavyImpact();

    try {
      await JourneyService.instance.completeJourney();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '✅ Followed Mode ended. Guardians notified that you are safe.',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
          ),
          backgroundColor: AppColors.safeGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<JourneyModel?>(
      valueListenable: JourneyService.instance.activeJourneyNotifier,
      builder: (context, journey, _) {
        final liveTrackingPos = LiveTrackingService.instance.currentPositionNotifier.value;
        final double curLat = _devicePosition?.latitude ??
            liveTrackingPos?.latitude ??
            journey?.currentLat ??
            (LocationService.instance.lastKnownLocation?.latitude ?? 23.7806);
        final double curLng = _devicePosition?.longitude ??
            liveTrackingPos?.longitude ??
            journey?.currentLng ??
            (LocationService.instance.lastKnownLocation?.longitude ?? 90.4267);
        final userLatLng = LatLng(curLat, curLng);

        // Find nearest police checkpoints via unified SafeZoneRepository
        final nearestPolice = SafeZoneRepository.instance.getNearestPoliceStation(
          curLat: curLat,
          curLng: curLng,
        );

        final startTime = journey?.startedAt ?? DateTime.now();

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0.5,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.textPrimary, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "I'm Being Followed",
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  'Active Defense & Live Guardian Tracking',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.actionOrange,
                  ),
                ),
              ],
            ),
            actions: [
              Container(
                margin: const EdgeInsets.only(right: 14, top: 12, bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.actionOrange.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ScaleTransition(
                      scale: _pulseScale,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.actionOrange,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatElapsed(startTime),
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.actionOrange,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.of(context).padding.bottom + 32,
              ),
              children: [
              // 1. Prominent Warning & Status Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.actionOrange.withValues(alpha: 0.4), width: 1.5),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: AppColors.actionOrange,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.radar_rounded, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'GUARDIANS ALERTED & TRACKING',
                            style: GoogleFonts.poppins(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.deepOrange.shade800,
                            ),
                          ),
                          Text(
                            'Periodic 10-minute check-ins active. If unanswered, SOS is automatically dispatched.',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: AppColors.textPrimary,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 2. Nearest Police Station (Priority Safe Haven)
              if (nearestPolice != null) ...[
                _buildNearestPoliceCard(nearestPolice, curLat, curLng),
                const SizedBox(height: 16),
              ],

              // 3. Mini Map with Radar
              _buildRadarMap(userLatLng, nearestPolice),

              const SizedBox(height: 16),

              // 4. De-escalation & Deterrence Tools
              _buildDeterrenceToolsCard(),

              const SizedBox(height: 24),

              // 5. Emergency Action Buttons
              _buildActionButtons(),
            ],
          ),
        ),
      );
      },
    );
  }

  Widget _buildNearestPoliceCard(SafeZone policeZone, double curLat, double curLng) {
    final distance = policeZone.calculateDistanceKm(curLat, curLng);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.actionBlue.withValues(alpha: 0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.actionBlue.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: policeZone.bgColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.local_police_rounded, color: policeZone.iconColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'NEAREST SAFE HAVEN',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppColors.actionBlue,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            SafeZone.formatDistance(distance),
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: AppColors.actionBlue,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      policeZone.name,
                      style: GoogleFonts.poppins(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (policeZone.address != null) ...[
            const SizedBox(height: 8),
            Text(
              policeZone.address!,
              style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () => NavigationService.instance.navigateTo(
                destLat: policeZone.latitude,
                destLng: policeZone.longitude,
                destLabel: policeZone.name,
              ),
              icon: const Icon(Icons.navigation_rounded, color: Colors.white, size: 20),
              label: Text(
                'NAVIGATE TO POLICE STATION',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.actionBlue,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarMap(LatLng userLatLng, SafeZone? nearestPolice) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.my_location_rounded, size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  'Live Radar Location',
                  style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                if (_isLoadingLocation) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.actionOrange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Locating...',
                      style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.actionOrange),
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.center_focus_strong_rounded, size: 18, color: AppColors.primary),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _mapController.move(userLatLng, 15.5),
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 220,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: userLatLng,
                  initialZoom: 15.0,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.smart_safety.app',
                  ),
                  MarkerLayer(
                    markers: [
                      // Nearest Police Station Marker
                      if (nearestPolice != null)
                        Marker(
                          point: nearestPolice.latLng,
                          width: 44,
                          height: 44,
                          child: GestureDetector(
                            onTap: () => NavigationService.instance.navigateTo(
                              destLat: nearestPolice.latitude,
                              destLng: nearestPolice.longitude,
                              destLabel: nearestPolice.name,
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFFDDEEFD),
                                shape: BoxShape.circle,
                                border: Border.all(color: AppColors.actionBlue, width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.local_police_rounded, color: AppColors.actionBlue, size: 22),
                            ),
                          ),
                        ),
                      // User Radar Pin
                      Marker(
                        point: userLatLng,
                        width: 50,
                        height: 50,
                        child: Center(
                          child: ScaleTransition(
                            scale: _pulseScale,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: AppColors.actionOrange,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.actionOrange.withValues(alpha: 0.5),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.person_pin_circle_rounded, color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeterrenceToolsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology_alt_rounded, color: AppColors.actionPurple, size: 18),
              const SizedBox(width: 8),
              Text(
                'Deterrence & Escape Tools',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => FakeCallDialog.show(context),
                  icon: const Icon(Icons.phone_in_talk_rounded, size: 16, color: AppColors.actionPurple),
                  label: Text(
                    'Fake Call Now',
                    style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.actionPurple),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.actionPurple, width: 1.3),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scheduleFakeCallIn30s,
                  icon: const Icon(Icons.timer_rounded, size: 16, color: AppColors.actionPurple),
                  label: Text(
                    _fakeCallCountdown > 0 ? 'Ringing in ${_fakeCallCountdown}s' : 'Call in 30s',
                    style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.actionPurple),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.actionPurple, width: 1.3),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _toggleLoudSiren,
              icon: Icon(
                _isSirenActive ? Icons.volume_off_rounded : Icons.campaign_rounded,
                size: 18,
                color: _isSirenActive ? AppColors.textPrimary : AppColors.sosRed,
              ),
              label: Text(
                _isSirenActive ? 'Turn Off Loud Siren' : 'Activate Loud Siren (Deterrent)',
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _isSirenActive ? AppColors.textPrimary : AppColors.sosRed,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _isSirenActive ? AppColors.textPrimary : AppColors.sosRed, width: 1.3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        // Huge Red SOS Button
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton.icon(
            onPressed: _isSosLoading ? null : _sendSosNow,
            icon: _isSosLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.emergency_rounded, color: Colors.white, size: 24),
            label: Text(
              _isSosLoading ? 'DISPATCHING SOS...' : 'SEND SOS NOW',
              style: GoogleFonts.poppins(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 0.8,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sosRed,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 4,
              shadowColor: AppColors.sosRed.withValues(alpha: 0.4),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // I Am Safe Now Button (PIN Guarded)
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _isResolving ? null : _handleConfirmSafe,
            icon: _isResolving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
            label: Text(
              _isResolving ? 'Resolving...' : "I'M SAFE NOW",
              style: GoogleFonts.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.4,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.safeGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }
}
