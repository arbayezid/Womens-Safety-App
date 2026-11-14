import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/emergency_service.dart';
import '../services/location_service.dart';
import '../services/siren_service.dart';
import '../services/auth_service.dart';
import '../services/activity_service.dart';
import '../services/contact_sync_service.dart';
import '../services/battery_alert_service.dart';
import '../services/notification_service.dart';
import '../utils/auth_guard.dart';
import 'package:permission_handler/permission_handler.dart';
import 'map_screen.dart';
import 'contacts_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'incident_room_screen.dart';
import 'followed_mode_screen.dart';
import '../widgets/fake_call_caller_sheet.dart';
import '../models/journey_model.dart';
import '../services/journey_service.dart';
import '../widgets/active_journey_card.dart';
import '../widgets/incoming_journey_card.dart';
import '../widgets/safety_check_dialog.dart';
import '../widgets/pin_input_dialog.dart';
import '../services/pin_security_service.dart';
import '../services/motion_detection_service.dart';
import '../services/shake_sos_service.dart';
import 'start_journey_sheet.dart';
import '../models/ride_checkin.dart';
import '../services/ride_checkin_service.dart';
import '../services/esp32_ble_service.dart';
import '../widgets/esp32_scan_sheet.dart';
import 'ride_checkin_screen.dart';
import 'active_ride_screen.dart';
import 'ride_details_screen.dart';
import 'inbox_screen.dart';
import '../services/inbox_service.dart';
import '../utils/duration_format.dart';

/// Root shell widget for Smart Safety.
///
/// Hosts a persistent [BottomNavigationBar] and uses an [IndexedStack]
/// to keep all tab screens alive while switching between them:
///   0 → Safety (dashboard)  1 → Map  2 → Contacts  3 → Settings
///
/// The avatar on the Safety tab navigates to [ProfileScreen].
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  /// Active tab index for the [BottomNavigationBar]
  int _selectedIndex = 0;

  /// Drives the breathing / pulsating animation on the SOS outer rings
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  /// Tracks loading state during SOS trigger pipeline execution
  bool _isSOSLoading = false;
  bool _isSafetyCheckShowing = false;
  bool _isFallCheckShowing = false;
  bool _isShakeCheckShowing = false;

  @override
  void initState() {
    super.initState();

    // Restore dark status-bar icons for this light-background screen
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    // Continuous breathing pulse for the SOS rings
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.93, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Restore any active SOS session, safe journey, and initialize battery & motion monitoring
    EmergencyService.instance.restoreActiveAlertId();
    BatteryAlertService.instance.initialize();
    JourneyService.instance.restoreActiveJourney();
    JourneyService.instance.activeSafetyCheckNotifier.addListener(_handleSafetyCheckChange);
    MotionDetectionService.instance.initialize();
    MotionDetectionService.instance.activeCountdownNotifier.addListener(_handleFallCheckChange);
    ShakeSosService.instance.initialize();
    ShakeSosService.instance.activeCountdownNotifier.addListener(_handleShakeCheckChange);

    // Initialize ESP32 BLE hardware service safely
    Esp32BleService.instance.initialize();

    // Initialize real-time incoming guardian emergency alerts
    NotificationService.instance.startSosAlertStreamListener();
    NotificationService.instance.startGuardianRideCheckinListener();
    NotificationService.instance.startGuardianJourneyListener();
    NotificationService.instance.activeIncomingSosNotifier.addListener(_handleIncomingSosChange);

    // App open PIN check and incoming emergency modal verification
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Check if an incoming emergency alert is active and pop up modal immediately
      if (mounted) {
        NotificationService.instance.showActiveSosDialogIfAvailable(context);
      }

      final pinEnabled = await PinSecurityService.instance.isPinEnabled();
      final requireOnOpen = await PinSecurityService.instance.isPinRequiredOnOpen();
      final hasRealPin = await PinSecurityService.instance.isRealPinConfigured();
      if (pinEnabled && requireOnOpen && hasRealPin && mounted) {
        await PinInputDialog.show(
          context,
          mode: PinDialogMode.verify,
          customTitle: 'App Locked',
          customSubtitle: 'Enter your security PIN to access Woman Guard',
          cancellable: false,
        );
      }
    });
  }

  void _handleIncomingSosChange() {
    final alert = NotificationService.instance.activeIncomingSosNotifier.value;
    if (alert != null && mounted && !NotificationService.instance.isSosDialogShowing) {
      NotificationService.instance.showActiveSosDialogIfAvailable(context);
    }
  }

  void _handleSafetyCheckChange() {
    final state = JourneyService.instance.activeSafetyCheckNotifier.value;
    if (state != null && mounted && !_isSafetyCheckShowing) {
      _isSafetyCheckShowing = true;
      SafetyCheckDialog.show(context, state).whenComplete(() {
        _isSafetyCheckShowing = false;
      });
    }
  }

  void _handleShakeCheckChange() {
    final seconds = ShakeSosService.instance.activeCountdownNotifier.value;
    if (seconds != null && mounted && !_isShakeCheckShowing) {
      _isShakeCheckShowing = true;
      ShakeSosDialog.show(context).whenComplete(() {
        _isShakeCheckShowing = false;
      });
    }
  }

  void _handleFallCheckChange() {
    final seconds = MotionDetectionService.instance.activeCountdownNotifier.value;
    if (seconds != null && mounted && !_isFallCheckShowing) {
      _isFallCheckShowing = true;
      SafetyCheckDialog.showFallCheck(context).whenComplete(() {
        _isFallCheckShowing = false;
      });
    }
  }

  @override
  void dispose() {
    NotificationService.instance.activeIncomingSosNotifier.removeListener(_handleIncomingSosChange);
    JourneyService.instance.activeSafetyCheckNotifier.removeListener(_handleSafetyCheckChange);
    MotionDetectionService.instance.activeCountdownNotifier.removeListener(_handleFallCheckChange);
    ShakeSosService.instance.activeCountdownNotifier.removeListener(_handleShakeCheckChange);
    _pulseController.dispose();
    super.dispose();
  }

  /// Opens the [ProfileScreen] via a slide-up hero transition.
  void _openProfile() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => const ProfileScreen(),
        transitionsBuilder: (_, animation, __, child) {
          final tween = Tween(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic));
          return SlideTransition(
            position: animation.drive(tween),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 320),
      ),
    );
  }

  /// Central Big Red SOS Button Action:
  /// Guarded by [AuthGuard.run] so Guest users must authenticate first.
  /// Calls [EmergencyService.instance.triggerEmergency] to obtain location & send background SMS.
  Future<void> _onSOSPressed() async {
    final emergency = EmergencyService.instance;

    // A round is already going out (from this button, the ESP32 pendant, shake, voice...).
    if (_isSOSLoading || emergency.sosInProgressNotifier.value) {
      HapticFeedback.selectionClick();
      return;
    }

    // An alert is already live: never re-run the pipeline from a plain tap (that would ring every
    // guardian again). Offer the explicit actions instead. The pendant is unaffected: it calls
    // EmergencyService directly and keeps its own behaviour.
    final activeId = emergency.activeAlertId;
    if (activeId != null) {
      HapticFeedback.mediumImpact();
      await _showActiveSosActions(activeId);
      return;
    }

    await AuthGuard.run(
      context,
      actionName: 'trigger Emergency SOS',
      customSubtitle:
          'To dispatch emergency alerts, notify guardians, and share real-time GPS coordinates, please sign in with Google.',
      onAuthenticated: () async {
        await _executeSOSPipeline();
      },
    );
  }

  Future<void> _executeSOSPipeline() async {
    if (_isSOSLoading) return;

    HapticFeedback.heavyImpact();

    setState(() {
      _isSOSLoading = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(
              '🚨 Triggering Emergency SOS...',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        backgroundColor: AppColors.sosRed,
        behavior: SnackBarBehavior.floating,
        shape: const StadiumBorder(),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final EmergencyResult result =
          await EmergencyService.instance.triggerEmergency(source: 'SOS Button', origin: SosOrigin.manual);

      if (!mounted) return;

      if (result.isSuccess) {
        _showSosResultSnackBar(result);
      } else if (result.hasNoRecipients) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.person_add_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.message,
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'Contacts',
              textColor: Colors.amberAccent,
              onPressed: () => setState(() => _selectedIndex = 2),
            ),
            backgroundColor: AppColors.sosRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 5),
          ),
        );
      } else if (result.isPermissionDenied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.settings_suggest_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.message,
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'Settings',
              textColor: Colors.amberAccent,
              onPressed: () => openAppSettings(),
            ),
            backgroundColor: AppColors.sosRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '⚠️ ${result.message}',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            ),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '❌ SOS Failed: ${e.toString().replaceAll('Exception: ', '')}',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
          ),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
          shape: const StadiumBorder(),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSOSLoading = false;
        });
      }
    }
  }

  /// Short result message: the full SMS / guardian status lives in the active-alert banner, so the
  /// snackbar stays one or two lines and does not cover the Quick Actions for long.
  void _showSosResultSnackBar(EmergencyResult result, {bool isResend = false}) {
    final emergency = EmergencyService.instance;
    final bool needsManualSmsFallback =
        result.contactsSentCount == 0 && result.recipientPhones.isNotEmpty;
    final bool statusShownAbove =
        emergency.activeAlertId != null || emergency.sosInProgressNotifier.value;

    final String text;
    if (needsManualSmsFallback) {
      text = isResend
          ? '🔁 Guardians rung again. SMS not sent automatically; tap Send in Messages.'
          : '🚨 Alert sent. SMS not sent automatically; tap Send in Messages.';
    } else if (statusShownAbove) {
      text = isResend
          ? '🔁 Alert re-sent. Guardians are being rung again.'
          : '🚨 SOS sent. Live status is shown at the top.';
    } else {
      text = result.message.isNotEmpty
          ? result.message
          : '✅ SOS Alert Dispatched! Location sent to ${result.contactsSentCount} contact(s).';
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              needsManualSmsFallback ? Icons.mark_email_read_rounded : Icons.check_circle_rounded,
              color: Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12.5),
              ),
            ),
          ],
        ),
        action: needsManualSmsFallback
            ? SnackBarAction(
                label: 'SMS App',
                textColor: Colors.amberAccent,
                onPressed: () {
                  EmergencyService.instance.launchNativeSmsApp(
                    phoneNumber: result.recipientPhones.first,
                    mapUrl: result.googleMapsUrl,
                  );
                },
              )
            : null,
        backgroundColor:
            needsManualSmsFallback ? AppColors.primaryViolet : AppColors.successForeground,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        duration: Duration(seconds: needsManualSmsFallback ? 5 : 3),
      ),
    );
  }

  /// Bottom sheet offered when the SOS button is tapped while an alert is already live.
  Future<void> _showActiveSosActions(String alertId) async {
    final action = await showModalBottomSheet<_ActiveSosAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ActiveSosActionsSheet(alertId: alertId),
    );
    // Dismissed by tapping outside or dragging down: do nothing.
    if (!mounted || action == null) return;

    switch (action) {
      case _ActiveSosAction.resend:
        await _resendActiveSos();
      case _ActiveSosAction.incidentRoom:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => IncidentRoomScreen(alertId: alertId)),
        );
      case _ActiveSosAction.markSafe:
        await _markSafeFromSheet(alertId);
    }
  }

  /// Re-rings guardians and re-sends the SMS round for the live alert (same alert document).
  Future<void> _resendActiveSos() async {
    if (_isSOSLoading) return;
    HapticFeedback.heavyImpact();
    setState(() => _isSOSLoading = true);
    try {
      final result = await EmergencyService.instance.resendActiveAlert();
      if (!mounted) return;
      if (result.isSuccess) {
        _showSosResultSnackBar(result, isResend: true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '⚠️ ${result.message}',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w500, fontSize: 12.5),
            ),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '❌ Re-send failed: ${e.toString().replaceAll('Exception: ', '')}',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
          ),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
          shape: const StadiumBorder(),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSOSLoading = false);
    }
  }

  /// "I'm Safe" from the sheet: the hold-to-confirm gesture replaces the yes/no dialog, but the
  /// security PIN (when set) is still required.
  Future<void> _markSafeFromSheet(String alertId) async {
    final confirmed = await _confirmMarkSafe(context, alreadyConfirmed: true);
    if (!confirmed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Marking you safe…',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.safeGreen,
        behavior: SnackBarBehavior.floating,
        shape: const StadiumBorder(),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        duration: const Duration(seconds: 2),
      ),
    );
    await EmergencyService.instance.markSafe(alertId: alertId);
    if (!mounted) return;
    _showMarkedSafeSnackBar(context);
  }

  /// Handles Quick Action cards (e.g. Loud Siren trigger).
  Future<void> _onQuickAction(String label) async {
    HapticFeedback.selectionClick();

    if (label == 'Fake Call') {
      // Pick the caller (remembered), then ring Now or After 10s.
      await FakeCallCallerSheet.show(context);
      return;
    }

    if (label == 'Safe Route') {
      setState(() => _selectedIndex = 1);
      return;
    }

    if (label == 'Loud Siren') {
      final bool isNowPlaying = await SirenService.instance.toggleSiren();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isNowPlaying ? '📢 Loud Siren Activated!' : '🔇 Loud Siren Deactivated',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
          ),
          backgroundColor: isNowPlaying ? AppColors.sosRed : AppColors.textPrimary,
          behavior: SnackBarBehavior.floating,
          shape: const StadiumBorder(),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (label == 'Camouflage') {
      final isConfigured = await PinSecurityService.instance.isRealPinConfigured();
      if (!isConfigured) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Please set up your Security PIN in Settings before using Camouflage.',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: AppColors.primary,
            action: SnackBarAction(
              label: 'Setup PIN',
              textColor: Colors.white,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          ),
        );
        return;
      }
      await PinSecurityService.instance.enterCamouflageManually();
      return;
    }

    if (label == 'Silent Panic') {
      await PinInputDialog.show(
        context,
        mode: PinDialogMode.verify,
        customTitle: 'Discreet Verification',
        customSubtitle: 'Enter security PIN to confirm emergency state',
      );
      return;
    }

    if (label == 'Safe Journey') {
      await AuthGuard.run(
        context,
        actionName: 'start a Safe Journey',
        customSubtitle:
            'To monitor your route with Dead-Man\'s Switch protection and broadcast live GPS tracking to guardians, please sign in.',
        onAuthenticated: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const StartJourneySheet(),
          );
        },
      );
      return;
    }

    if (label == 'Being Followed') {
      await AuthGuard.run(
        context,
        actionName: 'activate "I\'m Being Followed" Mode',
        customSubtitle:
            'To alert your guardians, activate live tracking, and get guidance to the nearest safe police checkpoint, please sign in.',
        onAuthenticated: () async {
          final activeJourney = JourneyService.instance.activeJourneyNotifier.value;
          if (activeJourney != null && activeJourney.isActive && activeJourney.isFollowedMode) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FollowedModeScreen()),
            );
            return;
          }

          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  const Icon(Icons.radar_rounded, color: AppColors.actionOrange, size: 28),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'Being Followed?',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 18),
                  )),
                ],
              ),
              content: Text(
                'This will activate high-alert mode:\n\n'
                '• Notify your emergency contacts via SMS & live map link\n'
                '• Start continuous GPS live tracking\n'
                '• Guide you to the nearest police station or safe zone\n'
                '• Require a safety check-in every 10 minutes\n\n'
                'Are you sure you want to activate this mode now?',
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
                    backgroundColor: AppColors.actionOrange,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    'Activate Now',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ],
            ),
          );

          if (confirmed != true || !mounted) return;

          try {
            await JourneyService.instance.startFollowedMode(notifySms: true);
            if (!mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FollowedModeScreen()),
            );
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to start Followed Mode: $e'),
                backgroundColor: AppColors.sosRed,
              ),
            );
          }
        },
      );
      return;
    }

    if (label == 'Ride Check-in') {
      await AuthGuard.run(
        context,
        actionName: 'start a Ride Safety Check-in',
        customSubtitle:
            'To record your ride details, alert guardians, and broadcast live GPS tracking, please sign in.',
        onAuthenticated: () {
          final activeRide = RideCheckinService.instance.activeRide;
          if (activeRide != null && activeRide.isActive) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ActiveRideScreen(rideId: activeRide.id)),
            );
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RideCheckinScreen()),
            );
          }
        },
      );
      return;
    }

    // Log the quick action event
    ActivityService.instance.logQuickAction(label);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label activated',
          style: GoogleFonts.poppins(),
        ),
        behavior: SnackBarBehavior.floating,
        shape: const StadiumBorder(),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,

      // ── IndexedStack keeps all screens alive for instant switching ──
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          // Tab 0 — Safety dashboard
          _SafetyDashboard(
            pulseAnimation: _pulseAnimation,
            isSOSLoading: _isSOSLoading,
            onSOSPressed: _onSOSPressed,
            onQuickAction: _onQuickAction,
            onAvatarTap: _openProfile,
            onOpenContacts: () => setState(() => _selectedIndex = 2),
          ),

          // Tab 1 — Map
          const MapScreen(),

          // Tab 2 — Contacts
          ContactsScreen(isActive: _selectedIndex == 2),

          // Tab 3 — Settings
          const SettingsScreen(),
        ],
      ),

      // ── Bottom Navigation Bar ──────────────────────────────────────
      bottomNavigationBar: _AppBottomNav(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  SAFETY DASHBOARD  (extracted from the old HomeScreen body)
// ─────────────────────────────────────────────────────────────

/// The Safety tab body — contains the top bar, location card,
/// SOS button, and quick-actions grid.
class _SafetyDashboard extends StatelessWidget {
  final Animation<double> pulseAnimation;
  final bool isSOSLoading;
  final VoidCallback onSOSPressed;
  final void Function(String) onQuickAction;
  final VoidCallback onAvatarTap;
  final VoidCallback onOpenContacts;

  const _SafetyDashboard({
    required this.pulseAnimation,
    required this.isSOSLoading,
    required this.onSOSPressed,
    required this.onQuickAction,
    required this.onAvatarTap,
    required this.onOpenContacts,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),

            // ── 1. Custom Top App Bar ──────────────────────────────
            _TopAppBar(onAvatarTap: onAvatarTap),

            // ── Incoming Guardian Requests Alert Banner ─────────────
            ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: ContactSyncService.instance.incomingRequestsNotifier,
              builder: (context, requests, _) {
                if (requests.isEmpty) return const SizedBox.shrink();

                final first = requests.first;
                final senderName = first['senderName'] ?? first['sender_name'] ?? 'Someone';

                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: GestureDetector(
                    onTap: onOpenContacts,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF9E6),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFFFD56B), width: 1.2),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEDBA),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.mark_email_unread_rounded, color: AppColors.actionOrange, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Guardian Request (${requests.length})',
                                  style: GoogleFonts.poppins(
                                      fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                                ),
                                Text(
                                  '$senderName wants to connect with you. Tap to review.',
                                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded, color: AppColors.actionOrange),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),

            // ── Active SOS Emergency Alert Banner ("I'm Safe") ──────
            ValueListenableBuilder<String?>(
              valueListenable: EmergencyService.instance.activeAlertIdNotifier,
              builder: (context, activeAlertId, _) {
                if (activeAlertId == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _ActiveSosEmergencyBanner(alertId: activeAlertId),
                );
              },
            ),

            // ── Active Incoming Guardian SOS Alert Banner ───────────
            ValueListenableBuilder<Map<String, dynamic>?>(
              valueListenable: NotificationService.instance.activeIncomingSosNotifier,
              builder: (context, incomingSos, _) {
                if (incomingSos == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _ActiveIncomingGuardianSosBanner(alertData: incomingSos),
                );
              },
            ),

            // ── Active Safe Journey Card ───────────────────────────
            ValueListenableBuilder<JourneyModel?>(
              valueListenable: JourneyService.instance.activeJourneyNotifier,
              builder: (context, activeJourney, _) {
                if (activeJourney == null || !activeJourney.isActive) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: ActiveJourneyCard(journey: activeJourney),
                );
              },
            ),

            // ── Protected Contacts' Live Safe Journeys (Receiver) ──
            ValueListenableBuilder<List<JourneyModel>>(
              valueListenable: NotificationService.instance.incomingActiveJourneysNotifier,
              builder: (context, incomingJourneys, _) {
                if (incomingJourneys.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: [
                    for (final journey in incomingJourneys)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: IncomingJourneyCard(key: ValueKey(journey.id), journey: journey),
                      ),
                  ],
                );
              },
            ),

            // ── Active Ride Safety Check-in Card (Sender) ─────────
            ValueListenableBuilder<RideCheckinModel?>(
              valueListenable: RideCheckinService.instance.activeRideNotifier,
              builder: (context, activeRide, _) {
                if (activeRide == null || !activeRide.isActive) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _ActiveRideCard(ride: activeRide),
                );
              },
            ),

            // ── Incoming Protected Contacts Active Ride Card (Receiver) ─
            ValueListenableBuilder<List<RideCheckinModel>>(
              valueListenable: NotificationService.instance.incomingActiveRidesNotifier,
              builder: (context, incomingRides, _) {
                if (incomingRides.isEmpty) {
                  return const SizedBox.shrink();
                }
                final latestRide = incomingRides.first;
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _IncomingProtectedRideCard(ride: latestRide),
                );
              },
            ),

            const SizedBox(height: 16),

            // ── 2. Current Location Card ───────────────────────────
            const CurrentLocationCard(),

            const SizedBox(height: 28),

            // ── 3 + 4. SOS Button and hint pill ──────────────────
            // Driven by EmergencyService state, not by this screen's taps, so an SOS from the
            // ESP32 pendant, shake or voice switches the button to its LIVE look as well.
            ListenableBuilder(
              listenable: Listenable.merge([
                EmergencyService.instance.activeAlertIdNotifier,
                EmergencyService.instance.activeAlertStartedAtNotifier,
                EmergencyService.instance.sosInProgressNotifier,
                EmergencyService.instance.lastDispatchNotifier,
              ]),
              builder: (context, _) {
                final emergency = EmergencyService.instance;
                final bool isActive = emergency.activeAlertId != null;
                final bool isBusy = isSOSLoading || emergency.sosInProgressNotifier.value;
                return Column(
                  children: [
                    Center(
                      child: _SOSButton(
                        pulseAnimation: pulseAnimation,
                        isLoading: isBusy,
                        isActive: isActive,
                        activeSince: emergency.activeAlertStartedAtNotifier.value,
                        onPressed: onSOSPressed,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: _TapHintBadge(
                        isActive: isActive,
                        isBusy: isBusy,
                        status: emergency.lastDispatchNotifier.value,
                      ),
                    ),
                  ],
                );
              },
            ),

            const SizedBox(height: 28),

            // ── 5. Quick Actions heading ───────────────────────────
            Text(
              'Quick Actions',
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),

            const SizedBox(height: 14),

            // ── 6. Quick Actions 2×2 grid ─────────────────────────
            _QuickActionsGrid(onAction: onQuickAction),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  SUB-WIDGETS  (private, file-scoped)
// ─────────────────────────────────────────────────────────────

/// Prominent banner displayed on the Safety dashboard when an emergency SOS alert
/// is currently active and broadcasting live GPS tracking data.
class _ActiveSosEmergencyBanner extends StatefulWidget {
  final String alertId;

  const _ActiveSosEmergencyBanner({required this.alertId});

  @override
  State<_ActiveSosEmergencyBanner> createState() => _ActiveSosEmergencyBannerState();
}

class _ActiveSosEmergencyBannerState extends State<_ActiveSosEmergencyBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  bool _isResolving = false;
  bool _isRetryingSms = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _handleMarkSafe() async {
    final confirmed = await _confirmMarkSafe(context);
    if (!confirmed || !mounted) return;

    setState(() => _isResolving = true);
    try {
      await EmergencyService.instance.markSafe(alertId: widget.alertId);
      if (!mounted) return;
      _showMarkedSafeSnackBar(context);
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  Future<void> _retrySms() async {
    if (_isRetryingSms) return;
    setState(() => _isRetryingSms = true);
    try {
      await EmergencyService.instance.retryFailedSms();
    } finally {
      if (mounted) setState(() => _isRetryingSms = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.sosRed.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.sosRed.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScaleTransition(
                scale: _pulseScale,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: AppColors.sosRed,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sensors_rounded, color: Colors.white, size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🚨 SOS EMERGENCY ACTIVE',
                      style: GoogleFonts.poppins(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.sosRed,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      'Broadcasting live GPS tracking to guardians',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Delivery status of the last round (replaces the long SMS snackbar).
          ValueListenableBuilder<SosDispatchStatus?>(
            valueListenable: EmergencyService.instance.lastDispatchNotifier,
            builder: (context, status, _) {
              if (status == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _SosDeliveryStatusRow(
                  status: status,
                  isRetrying: _isRetryingSms,
                  onRetry: _retrySms,
                ),
              );
            },
          ),

          const SizedBox(height: 12),
          // minHeight instead of a fixed height, and a label that scales down instead of
          // wrapping, so the text is never clipped at large system font sizes.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => IncidentRoomScreen(alertId: widget.alertId),
                        ),
                      );
                    },
                    icon: const Icon(Icons.meeting_room_rounded, size: 16, color: AppColors.sosRed),
                    label: _OneLineButtonLabel(
                      'Incident Room',
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.sosRed,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      side: const BorderSide(color: AppColors.sosRed, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isResolving ? null : _handleMarkSafe,
                    icon: _isResolving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                    label: _OneLineButtonLabel(
                      _isResolving ? 'Resolving...' : "I'M SAFE NOW",
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      backgroundColor: AppColors.safeGreen,
                      disabledBackgroundColor: AppColors.safeGreen.withValues(alpha: 0.6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Prominent, high-urgency banner displayed on the Safety dashboard when an emergency SOS alert
/// has been triggered by a contact/ward and the current user is an emergency guardian.
class _ActiveIncomingGuardianSosBanner extends StatefulWidget {
  final Map<String, dynamic> alertData;

  const _ActiveIncomingGuardianSosBanner({required this.alertData});

  @override
  State<_ActiveIncomingGuardianSosBanner> createState() =>
      _ActiveIncomingGuardianSosBannerState();
}

class _ActiveIncomingGuardianSosBannerState
    extends State<_ActiveIncomingGuardianSosBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  bool _isResponding = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 0.95, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _handleAcknowledge() async {
    final alertId = widget.alertData['alertId']?.toString() ?? '';
    if (alertId.isEmpty) return;

    setState(() => _isResponding = true);
    HapticFeedback.heavyImpact();
    SirenService.instance.stopSiren();

    try {
      await NotificationService.instance.acknowledgeAlert(alertId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '✅ Confirmed: You are responding to this emergency!',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.actionGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          margin: const EdgeInsets.all(16),
        ),
      );
    } finally {
      if (mounted) setState(() => _isResponding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final alertId = widget.alertData['alertId']?.toString() ?? '';
    final senderName = widget.alertData['senderName']?.toString() ??
        widget.alertData['sender_name']?.toString() ??
        'Emergency Contact';
    final address = widget.alertData['address']?.toString() ??
        widget.alertData['location']?['address']?.toString() ??
        'Live GPS Tracking Active';

    final dynamic rawTime = widget.alertData['triggeredAt'] ?? widget.alertData['timestamp'];
    String timeAgo = 'Just now';
    if (rawTime != null) {
      DateTime? dt;
      if (rawTime is Timestamp) dt = rawTime.toDate();
      if (rawTime is DateTime) dt = rawTime;
      if (rawTime is String) dt = DateTime.tryParse(rawTime);
      if (dt != null) {
        final diff = DateTime.now().difference(dt);
        if (diff.inSeconds < 45) {
          timeAgo = 'Just now';
        } else if (diff.inMinutes < 60) {
          timeAgo = '${diff.inMinutes}m ago';
        } else {
          timeAgo = '${diff.inHours}h ago';
        }
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.sosRed, width: 2),
        boxShadow: [
          BoxShadow(
            color: AppColors.sosRed.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScaleTransition(
                scale: _pulseScale,
                child: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: const BoxDecoration(
                    color: AppColors.sosRed,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.warning_rounded, color: Colors.white, size: 22),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🚨 INCOMING EMERGENCY SOS',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.sosRed,
                        letterSpacing: 0.4,
                      ),
                    ),
                    Text(
                      '$senderName needs immediate assistance!',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '$timeAgo • $address',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: SirenService.instance.isPlayingNotifier,
                builder: (context, isPlaying, _) {
                  return IconButton(
                    onPressed: () {
                      if (isPlaying) {
                        SirenService.instance.stopSiren();
                      } else {
                        SirenService.instance.startSiren();
                      }
                    },
                    icon: Icon(
                      isPlaying ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                      color: isPlaying ? AppColors.sosRed : AppColors.textSecondary,
                      size: 22,
                    ),
                    tooltip: isPlaying ? 'Mute Siren' : 'Play Siren',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      SirenService.instance.stopSiren();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => IncidentRoomScreen(
                            alertId: alertId,
                            initialData: widget.alertData,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.meeting_room_rounded, size: 17, color: Colors.white),
                    label: Text(
                      'Incident Room',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.sosRed,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      NotificationService.instance
                          .showActiveSosDialogIfAvailable(context, userRequested: true);
                    },
                    icon: const Icon(Icons.visibility_rounded, size: 16, color: AppColors.sosRed),
                    label: Text(
                      'View Details',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.sosRed,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.sosRed, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 42,
                child: ElevatedButton(
                  onPressed: _isResponding ? null : _handleAcknowledge,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.actionGreen,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    elevation: 0,
                  ),
                  child: _isResponding
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          "RESPOND",
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Custom header row: tappable avatar · greeting · ESP32 badge
///
/// [onAvatarTap] is forwarded from the shell to open [ProfileScreen].
class _TopAppBar extends StatefulWidget {
  final VoidCallback onAvatarTap;
  const _TopAppBar({required this.onAvatarTap});

  @override
  State<_TopAppBar> createState() => _TopAppBarState();
}

class _TopAppBarState extends State<_TopAppBar> {
  int _secretTapCount = 0;
  DateTime? _lastSecretTap;

  void _onGreetingTapped() {
    final now = DateTime.now();
    if (_lastSecretTap == null || now.difference(_lastSecretTap!) > const Duration(milliseconds: 900)) {
      _secretTapCount = 1;
    } else {
      _secretTapCount++;
      if (_secretTapCount >= 3) {
        _secretTapCount = 0;
        PinSecurityService.instance.isRealPinConfigured().then((configured) {
          if (configured) {
            PinSecurityService.instance.enterCamouflageManually();
          }
        });
        return;
      }
    }
    _lastSecretTap = now;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AuthService.instance.profileNotifier,
      builder: (context, _, __) {
        final greeting = 'Hi, ${AuthService.instance.greetingName}! 👋';
        final photoUrl = AuthService.instance.photoUrl;
        final initials = AuthService.instance.initials;
        final isAuthenticated = AuthService.instance.isAuthenticated;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── Tappable avatar circle (opens Profile) ──────────────────
            GestureDetector(
              onTap: widget.onAvatarTap,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primarySurface,
                  image: photoUrl != null
                      ? DecorationImage(
                          image: NetworkImage(photoUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                alignment: Alignment.center,
                child: photoUrl == null
                    ? Text(
                        initials,
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      )
                    : null,
              ),
            ),

            const SizedBox(width: 12),

            // ── Greeting + guardian mode subtitle (triple-tap enters Camouflage) ──
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onGreetingTapped,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      greeting,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      isAuthenticated
                          ? 'Guardian Mode: Active'
                          : 'Guest Mode: Tap to Sign In',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: isAuthenticated
                            ? AppColors.textSecondary
                            : AppColors.actionOrange,
                        fontWeight: isAuthenticated
                            ? FontWeight.normal
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Notification inbox bell with unread count ────────────────
            if (isAuthenticated) const _InboxBell(),

            // ── ESP32 status badge ───────────────────────────────────────
            _ESP32Badge(),
          ],
        );
      },
    );
  }
}

/// Bell opening the notification inbox; the badge shows how many new notifications arrived
/// since it was last opened (1, 2, 3 … 99+).
class _InboxBell extends StatelessWidget {
  const _InboxBell();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: InboxService.instance.unreadCountNotifier,
      builder: (context, unread, _) {
        return IconButton(
          tooltip: unread > 0 ? '$unread new notifications' : 'Notifications',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const InboxScreen()),
          ),
          icon: Badge(
            isLabelVisible: unread > 0,
            backgroundColor: AppColors.sosRed,
            label: Text(
              unread > 99 ? '99+' : '$unread',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            child: Icon(
              unread > 0 ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
              color: AppColors.textPrimary,
              size: 26,
            ),
          ),
        );
      },
    );
  }
}

/// Pill-shaped badge showing real-time ESP32 connection status.
class _ESP32Badge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Esp32ConnectionStatus>(
      valueListenable: Esp32BleService.instance.connectionStateNotifier,
      builder: (context, status, _) {
        final Color bgColor;
        final Color dotColor;
        final String label;

        switch (status) {
          case Esp32ConnectionStatus.connected:
            bgColor = AppColors.successBackground;
            dotColor = AppColors.successForeground;
            label = 'ESP32 Connected';
            break;
          case Esp32ConnectionStatus.connecting:
          case Esp32ConnectionStatus.scanning:
            bgColor = const Color(0xFFFFF8E1);
            dotColor = const Color(0xFFFFA000);
            label = 'ESP32 Connecting';
            break;
          case Esp32ConnectionStatus.permissionDenied:
            bgColor = const Color(0xFFFFEBEE);
            dotColor = AppColors.sosRed;
            label = 'Bluetooth Req';
            break;
          case Esp32ConnectionStatus.bluetoothDisabled:
          case Esp32ConnectionStatus.disconnected:
            bgColor = const Color(0xFFF5F5F5);
            dotColor = AppColors.textSecondary;
            label = 'ESP32 Offline';
            break;
        }

        return GestureDetector(
          onTap: () => Esp32ScanSheet.show(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status dot indicator
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: dotColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// White rounded card displaying real-time GPS location and reverse-geocoded address.
///
/// Cleanly handles 4 distinct states:
/// 1. [LocationStateStatus.loading]: Animated circular indicator with "Fetching current location...".
/// 2. [LocationStateStatus.hasData]: Formatted human-readable address as title and coordinates as subtitle.
/// 3. [LocationStateStatus.permissionDenied]: Clear notification with an "Enable / Retry" or "Settings" action.
/// 4. [LocationStateStatus.serviceDisabled]: "GPS is turned off" alert with an "Open Settings" action.
///
/// Supports manual tap-to-refresh, trailing refresh button, and auto-refreshes on [AppLifecycleState.resumed].
class CurrentLocationCard extends StatefulWidget {
  const CurrentLocationCard({super.key});

  @override
  State<CurrentLocationCard> createState() => _CurrentLocationCardState();
}

class _CurrentLocationCardState extends State<CurrentLocationCard>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  LocationResult _result = LocationService.instance.locationNotifier.value;
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _result = LocationService.instance.locationNotifier.value;
    LocationService.instance.locationNotifier.addListener(_onLocationNotified);

    // If no cached location is available, trigger a query
    if (_result.status == LocationStateStatus.initial || LocationService.instance.lastKnownLocation == null) {
      _fetchLocation(requestPermission: false);
    }
  }

  void _onLocationNotified() {
    if (mounted) {
      setState(() {
        _result = LocationService.instance.locationNotifier.value;
      });
    }
  }

  @override
  void dispose() {
    LocationService.instance.locationNotifier.removeListener(_onLocationNotified);
    WidgetsBinding.instance.removeObserver(this);
    _spinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Automatically re-query location when the user returns from system settings
    if (state == AppLifecycleState.resumed) {
      if (_result.isPermissionDenied || _result.isServiceDisabled) {
        _fetchLocation(requestPermission: false);
      }
    }
  }

  Future<void> _fetchLocation({bool requestPermission = true}) async {
    if (!mounted) return;
    _spinController.repeat();

    try {
      final res = await LocationService.instance.getCurrentLocation(
        requestPermission: requestPermission,
      );
      if (mounted) {
        setState(() {
          _result = res;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = LocationResult.error(e.toString());
        });
      }
    } finally {
      if (mounted) {
        _spinController.stop();
        _spinController.reset();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            HapticFeedback.selectionClick();
            if (_result.isServiceDisabled) {
              LocationService.instance.openLocationSettings();
            } else if (_result.isPermissionDenied) {
              if (_result.isPermanentlyDenied) {
                LocationService.instance.openAppSettings();
              } else {
                _fetchLocation(requestPermission: true);
              }
            } else {
              _fetchLocation(requestPermission: true);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: _buildCardContent(),
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent() {
    switch (_result.status) {
      case LocationStateStatus.initial:
      case LocationStateStatus.loading:
        return _buildLoadingState();

      case LocationStateStatus.serviceDisabled:
        return _buildServiceDisabledState();

      case LocationStateStatus.permissionDenied:
        return _buildPermissionDeniedState();

      case LocationStateStatus.hasData:
        final data = _result.data;
        if (data == null) {
          return _buildErrorState('Location data temporarily unavailable');
        }
        return _buildHasDataState(data);

      case LocationStateStatus.error:
        return _buildErrorState(_result.errorMessage ?? 'Unable to retrieve location');
    }
  }

  /// 1. Loading State: Circular indicator with "Fetching current location..."
  Widget _buildLoadingState() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primarySurface,
          ),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Current Location',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Fetching current location...',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
        RotationTransition(
          turns: _spinController,
          child: const Icon(
            Icons.refresh_rounded,
            color: AppColors.primaryLight,
            size: 20,
          ),
        ),
      ],
    );
  }

  /// 2. Has Data State: Formatted address title & coordinate subtitle
  Widget _buildHasDataState(LocationModel data) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.sosOuterRing,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.my_location_rounded,
            color: AppColors.sosRed,
            size: 22,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.formattedAddress,
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Coordinates: ${data.formattedCoordinates}',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            _fetchLocation(requestPermission: true);
          },
          icon: const Icon(
            Icons.refresh_rounded,
            color: AppColors.textSecondary,
            size: 20,
          ),
          tooltip: 'Refresh Location',
          visualDensity: VisualDensity.compact,
          splashRadius: 18,
        ),
      ],
    );
  }

  /// 3. Permission Denied State: Prompt with "Enable / Retry" or "Settings" action
  Widget _buildPermissionDeniedState() {
    final bool isPermanent = _result.isPermanentlyDenied;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFFEEDD8),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.location_off_rounded,
            color: AppColors.actionOrange,
            size: 22,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Location Permission Denied',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.deepOrange.shade800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                isPermanent
                    ? 'Allow location in App Settings'
                    : 'Tap to grant location permission',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: AppColors.primarySurface,
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          onPressed: () async {
            HapticFeedback.selectionClick();
            if (isPermanent) {
              await LocationService.instance.openAppSettings();
            } else {
              _fetchLocation(requestPermission: true);
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPermanent ? Icons.settings_rounded : Icons.replay_rounded,
                size: 13,
              ),
              const SizedBox(width: 4),
              Text(
                isPermanent ? 'Settings' : 'Enable / Retry',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 4. Service Disabled State: "GPS is turned off" with "Open Settings" action
  Widget _buildServiceDisabledState() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFFEEDD8),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.gps_off_rounded,
            color: AppColors.actionOrange,
            size: 22,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'GPS is turned off',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.amber.shade900,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Enable GPS to detect current location',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFFFEEDD8),
            foregroundColor: AppColors.actionOrange,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          onPressed: () async {
            HapticFeedback.selectionClick();
            await LocationService.instance.openLocationSettings();
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.settings_outlined, size: 13),
              const SizedBox(width: 4),
              Text(
                'Open Settings',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 5. Error Fallback State
  Widget _buildErrorState(String message) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.sosOuterRing,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.error_outline_rounded,
            color: AppColors.sosRed,
            size: 22,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Location Error',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.sosRed,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                message,
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            _fetchLocation(requestPermission: true);
          },
          icon: const Icon(
            Icons.refresh_rounded,
            color: AppColors.textSecondary,
            size: 20,
          ),
          tooltip: 'Retry',
          visualDensity: VisualDensity.compact,
          splashRadius: 18,
        ),
      ],
    );
  }
}

/// Central SOS button.
///
/// Idle: three concentric circles that breathe via [pulseAnimation] and show "SOS".
/// Active (an alert is live): deeper red core with a white border, radar ripples spreading
/// outward, and "LIVE" plus the elapsed time instead of "SOS". Text, icon and motion all change,
/// so the state never depends on colour alone. With the system's reduce-motion setting on, the
/// ripples are replaced by static rings.
class _SOSButton extends StatefulWidget {
  final Animation<double> pulseAnimation;
  final bool isLoading;
  final bool isActive;
  final DateTime? activeSince;
  final VoidCallback onPressed;

  const _SOSButton({
    required this.pulseAnimation,
    required this.isLoading,
    required this.isActive,
    required this.activeSince,
    required this.onPressed,
  });

  @override
  State<_SOSButton> createState() => _SOSButtonState();
}

class _SOSButtonState extends State<_SOSButton> with SingleTickerProviderStateMixin {
  static const double _outerSize = 230;
  static const double _middleSize = 188;
  static const double _coreSize = 146;

  late final AnimationController _ripple;
  Timer? _clockTimer;

  /// Used for the timer only if the service has no start time (should not normally happen).
  DateTime? _fallbackStart;

  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncActiveState();
  }

  @override
  void didUpdateWidget(covariant _SOSButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) _syncActiveState();
  }

  void _syncActiveState() {
    if (widget.isActive) {
      _fallbackStart ??= DateTime.now();
      _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      if (_reduceMotion) {
        _ripple.stop();
      } else if (!_ripple.isAnimating) {
        _ripple.repeat();
      }
    } else {
      _fallbackStart = null;
      _clockTimer?.cancel();
      _clockTimer = null;
      _ripple
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _ripple.dispose();
    super.dispose();
  }

  Duration get _elapsed {
    final start = widget.activeSince ?? _fallbackStart ?? DateTime.now();
    return DateTime.now().difference(start);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = _reduceMotion;
    final String clock = formatElapsedClock(_elapsed);

    final String semanticsLabel;
    if (widget.isActive) {
      final minutes = _elapsed.inMinutes;
      semanticsLabel = 'SOS alert active for '
          '${minutes < 1 ? 'less than a minute' : '$minutes minute${minutes == 1 ? '' : 's'}'}. '
          'Tap for options.';
    } else if (widget.isLoading) {
      semanticsLabel = 'Sending SOS alert.';
    } else {
      semanticsLabel = 'SOS. Tap to send an emergency alert to your guardians.';
    }

    Widget button = SizedBox(
      width: _outerSize,
      height: _outerSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!widget.isActive) ...[
            // Outermost ring — very light pink
            Container(
              width: _outerSize,
              height: _outerSize,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosOuterRing,
              ),
            ),
            // Middle ring — medium pink/red
            Container(
              width: _middleSize,
              height: _middleSize,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosMediumRing,
              ),
            ),
          ] else if (reduceMotion) ...[
            // Static rings instead of moving ripples
            Container(
              width: _outerSize,
              height: _outerSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosRed.withValues(alpha: 0.12),
              ),
            ),
            Container(
              width: _middleSize,
              height: _middleSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosRed.withValues(alpha: 0.22),
              ),
            ),
          ] else
            // Radar ripples spreading outward ("broadcasting")
            AnimatedBuilder(
              animation: _ripple,
              builder: (_, __) => CustomPaint(
                size: const Size.square(_outerSize),
                painter: _SosRipplePainter(
                  progress: _ripple.value,
                  innerRadius: _coreSize / 2,
                  outerRadius: _outerSize / 2,
                ),
              ),
            ),

          // Core button
          widget.isActive ? _buildActiveCore(clock) : _buildIdleCore(),
        ],
      ),
    );

    // The idle look keeps its breathing pulse; the active look moves through its ripples.
    if (!widget.isActive && !reduceMotion) {
      final child = button;
      button = AnimatedBuilder(
        animation: widget.pulseAnimation,
        builder: (_, inner) => Transform.scale(scale: widget.pulseAnimation.value, child: inner),
        child: child,
      );
    }

    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: GestureDetector(onTap: widget.onPressed, child: button),
    );
  }

  Widget _buildIdleCore() {
    return Container(
      width: _coreSize,
      height: _coreSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFFFF5F56), Color(0xFFE8231A)],
          center: Alignment(-0.3, -0.3),
          radius: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.sosRed.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 8),
            spreadRadius: 2,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: widget.isLoading
          ? const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 4,
              ),
            )
          : Text(
              'SOS',
              style: GoogleFonts.poppins(
                fontSize: 42,
                fontWeight: FontWeight.w900,
                color: AppColors.textOnPrimary,
                letterSpacing: 3,
              ),
            ),
    );
  }

  Widget _buildActiveCore(String clock) {
    return Container(
      width: _coreSize,
      height: _coreSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFFE8231A), Color(0xFFC62828)],
          center: Alignment(-0.3, -0.3),
          radius: 1.0,
        ),
        border: Border.all(color: Colors.white, width: 3.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFC62828).withValues(alpha: 0.5),
            blurRadius: 28,
            offset: const Offset(0, 8),
            spreadRadius: 2,
          ),
        ],
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      // Scales down instead of overflowing at large system font sizes.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sensors_rounded, color: Colors.white, size: 28),
            Text(
              'LIVE',
              style: GoogleFonts.poppins(
                fontSize: 26,
                height: 1.1,
                fontWeight: FontWeight.w900,
                color: AppColors.textOnPrimary,
                letterSpacing: 3,
              ),
            ),
            if (widget.isLoading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Sending',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              )
            else
              Text(
                clock,
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.95),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Paints three red ripples that grow from the core's edge to the outer edge and fade out.
class _SosRipplePainter extends CustomPainter {
  final double progress;
  final double innerRadius;
  final double outerRadius;

  _SosRipplePainter({
    required this.progress,
    required this.innerRadius,
    required this.outerRadius,
  });

  static const int _rippleCount = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    // Faint base disc so the button keeps its footprint between ripples.
    canvas.drawCircle(
      center,
      outerRadius,
      Paint()..color = AppColors.sosRed.withValues(alpha: 0.06),
    );

    for (int i = 0; i < _rippleCount; i++) {
      final double t = Curves.easeOut.transform((progress + i / _rippleCount) % 1.0);
      final double radius = innerRadius + (outerRadius - innerRadius) * t;
      final double fade = 1.0 - t;
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = AppColors.sosRed.withValues(alpha: 0.22 * fade),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = AppColors.sosRed.withValues(alpha: 0.45 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SosRipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.innerRadius != innerRadius ||
      oldDelegate.outerRadius != outerRadius;
}

/// Pill beneath the SOS button. Idle: "Tap to send instant alert". While sending: "Sending SOS…".
/// Active: light red with the real number of guardians reached and "Tap for options".
class _TapHintBadge extends StatelessWidget {
  final bool isActive;
  final bool isBusy;
  final SosDispatchStatus? status;

  const _TapHintBadge({
    required this.isActive,
    required this.isBusy,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    if (isActive) {
      final int reached = status?.contactsReached ?? 0;
      final parts = <String>[
        'Alert active',
        if (reached > 0) '$reached guardian${reached == 1 ? '' : 's'} alerted',
        isBusy ? 'Sending…' : 'Tap for options',
      ];
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.sosRed.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.sosRed.withValues(alpha: 0.30)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.sosRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  parts.join(' · '),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFC62828),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFEEEEF2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBusy ? Icons.schedule_send_rounded : Icons.touch_app_rounded,
            size: 15,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 5),
          Text(
            isBusy ? 'Sending SOS…' : 'Tap to send instant alert',
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Button label that stays on one line and scales down rather than wrapping or clipping.
class _OneLineButtonLabel extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _OneLineButtonLabel(this.text, {required this.style});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1, softWrap: false, style: style),
    );
  }
}

/// One line in the active-alert banner: what the last round reached, with "Retry" when some
/// SMS did not go out automatically.
class _SosDeliveryStatusRow extends StatelessWidget {
  final SosDispatchStatus status;
  final bool isRetrying;
  final VoidCallback onRetry;

  const _SosDeliveryStatusRow({
    required this.status,
    required this.isRetrying,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final bool attention = status.smsNeedsAttention;
    final Color tone = attention ? const Color(0xFFD35400) : AppColors.safeGreen;

    final parts = <String>[
      if (status.smsTotal > 0)
        'SMS ${status.smsSent}/${status.smsTotal} sent'
            '${status.smsPending > 0 ? ' (${status.smsPending} sending)' : ''}'
      else
        'No SMS numbers',
      status.cloudSent ? 'In-app alert sent' : 'In-app alert pending',
      if (attention && status.composerOpened) 'Messages opened',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            attention ? Icons.sms_failed_rounded : Icons.mark_chat_read_rounded,
            size: 16,
            color: tone,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parts.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (attention)
            isRetrying
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD35400)),
                    ),
                  )
                : TextButton(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFD35400),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Retry',
                      style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
        ],
      ),
    );
  }
}

/// What the user picked in the active-alert sheet.
enum _ActiveSosAction { resend, incidentRoom, markSafe }

/// Bottom sheet shown when the SOS button is tapped while an alert is live: re-send (with a
/// cooldown), open the Incident Room, or hold to confirm "I'm safe". Tapping outside closes it
/// and does nothing else.
class _ActiveSosActionsSheet extends StatefulWidget {
  final String alertId;

  const _ActiveSosActionsSheet({required this.alertId});

  @override
  State<_ActiveSosActionsSheet> createState() => _ActiveSosActionsSheetState();
}

class _ActiveSosActionsSheetState extends State<_ActiveSosActionsSheet> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Updates the elapsed time and the re-send countdown.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    EmergencyService.instance.activeAlertIdNotifier.addListener(_onAlertChanged);
  }

  /// Closes the sheet if the alert ends meanwhile (e.g. resolved from the Incident Room).
  void _onAlertChanged() {
    if (!mounted) return;
    if (EmergencyService.instance.activeAlertId != widget.alertId) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    EmergencyService.instance.activeAlertIdNotifier.removeListener(_onAlertChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final emergency = EmergencyService.instance;
    final DateTime? startedAt = emergency.activeAlertStartedAtNotifier.value;
    final Duration cooldown = emergency.resendCooldownRemaining;
    final bool busy = emergency.sosInProgressNotifier.value;
    final bool canResend = cooldown == Duration.zero && !busy;

    final String subtitle = startedAt != null
        ? 'Live for ${formatElapsedClock(DateTime.now().difference(startedAt))} · '
            'guardians can see your location'
        : 'Guardians can see your live location';

    final String resendSubtitle;
    if (busy) {
      resendSubtitle = 'An alert is being sent right now…';
    } else if (cooldown > Duration.zero) {
      resendSubtitle = 'Guardians were just alerted. Available again in ${cooldown.inSeconds + 1}s';
    } else {
      resendSubtitle = 'Rings your guardians again and re-sends the SMS with your location';
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: AppColors.sosRed,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sensors_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SOS alert is active',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SheetOptionTile(
              icon: Icons.replay_rounded,
              color: AppColors.sosRed,
              title: 'Re-send alert',
              subtitle: resendSubtitle,
              enabled: canResend,
              onTap: () => Navigator.of(context).pop(_ActiveSosAction.resend),
            ),
            const SizedBox(height: 10),
            _SheetOptionTile(
              icon: Icons.meeting_room_rounded,
              color: AppColors.primary,
              title: 'Open Incident Room',
              subtitle: 'See live updates for this alert',
              onTap: () => Navigator.of(context).pop(_ActiveSosAction.incidentRoom),
            ),
            const SizedBox(height: 18),
            _HoldToConfirmButton(
              label: "Hold to confirm I'm safe",
              semanticsLabel: "I'm safe now. Double tap and hold to confirm.",
              onConfirmed: () => Navigator.of(context).pop(_ActiveSosAction.markSafe),
            ),
            const SizedBox(height: 10),
            Text(
              'Tap outside to close',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetOptionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const _SheetOptionTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onTap();
                }
              : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Green button that must be held for [holdDuration] to confirm. Releasing early rewinds it.
/// Screen-reader users confirm with the long-press action (double tap and hold).
class _HoldToConfirmButton extends StatefulWidget {
  final String label;
  final String semanticsLabel;
  final VoidCallback onConfirmed;

  /// Same hold time as the ESP32 pendant's button, so both feel alike.
  static const Duration holdDuration = Duration(seconds: 2);

  const _HoldToConfirmButton({
    required this.label,
    required this.semanticsLabel,
    required this.onConfirmed,
  });

  @override
  State<_HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<_HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold;
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _hold = AnimationController(vsync: this, duration: _HoldToConfirmButton.holdDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_confirmed) {
          _confirmed = true;
          HapticFeedback.heavyImpact();
          widget.onConfirmed();
        }
      });
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _start() {
    if (_confirmed) return;
    HapticFeedback.selectionClick();
    _hold.forward();
  }

  void _release() {
    if (!mounted || _confirmed) return;
    _hold.animateBack(0, duration: const Duration(milliseconds: 250));
  }

  @override
  Widget build(BuildContext context) {
    const Color green = AppColors.safeGreen;
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      excludeSemantics: true,
      onLongPress: () {
        if (_confirmed) return;
        _confirmed = true;
        widget.onConfirmed();
      },
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) {
            final double v = _hold.value;
            final Color fg = v > 0.5 ? Colors.white : green;
            return ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                constraints: const BoxConstraints(minHeight: 54),
                decoration: BoxDecoration(
                  color: green.withValues(alpha: 0.12),
                  border: Border.all(color: green, width: 1.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: v,
                        child: const ColoredBox(color: green),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_rounded, color: fg, size: 20),
                          const SizedBox(width: 8),
                          Flexible(
                            child: _OneLineButtonLabel(
                              v > 0 && v < 1 ? 'Keep holding…' : widget.label,
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: fg,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Asks for the security PIN when one is set. Without a PIN, shows the yes/no dialog unless
/// [alreadyConfirmed] (the hold-to-confirm gesture already confirmed). True when confirmed.
Future<bool> _confirmMarkSafe(BuildContext context, {bool alreadyConfirmed = false}) async {
  final isPinEnabled = await PinSecurityService.instance.isPinEnabled();
  final isRealConfigured = await PinSecurityService.instance.isRealPinConfigured();
  if (!context.mounted) return false;

  if (isPinEnabled && isRealConfigured) {
    final verified = await PinInputDialog.show(
      context,
      mode: PinDialogMode.verify,
      customTitle: 'Confirm Safety',
      customSubtitle: 'Enter your Security PIN to mark yourself safe and resolve this alert',
    );
    return verified == true;
  }

  if (alreadyConfirmed) return true;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          const Icon(Icons.shield_rounded, color: AppColors.safeGreen, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "I'm Safe Now",
              style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 18),
            ),
          ),
        ],
      ),
      content: Text(
        'Are you sure you are safe? This will resolve the active emergency SOS, stop live GPS tracking, and send an "I\'m safe now" SMS to your emergency contacts.',
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(
            'Yes, I Am Safe',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

void _showMarkedSafeSnackBar(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '✅ Marked safe! Emergency contacts notified and live tracking stopped.',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
      backgroundColor: AppColors.safeGreen,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// Prominent banner displayed on the Safety dashboard when a Ride Safety Check-in
/// session is currently active and broadcasting live GPS coordinates.
class _ActiveRideCard extends StatelessWidget {
  final RideCheckinModel ride;

  const _ActiveRideCard({required this.ride});

  @override
  Widget build(BuildContext context) {
    final isOverdue = ride.isOverdue;
    final cardBg = isOverdue ? const Color(0xFFFFF3E0) : const Color(0xFFE8F1FC);
    final borderColor = isOverdue ? const Color(0xFFFFB74D) : const Color(0xFF90CAF9);
    final badgeColor = isOverdue ? Colors.deepOrange : const Color(0xFF1565C0);

    final durationText = ride.expectedMinutes != null
        ? '${formatMinutes(ride.expectedMinutes!, suffix: 'm')} trip'
        : 'Active trip';

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ActiveRideScreen(rideId: ride.id)),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 1.3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.local_taxi_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isOverdue ? Colors.deepOrange : AppColors.safeGreen,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isOverdue ? 'RIDE OVERDUE' : 'ACTIVE RIDE CHECK-IN',
                        style: GoogleFonts.poppins(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: badgeColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        durationText,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${ride.rideType} • ${ride.plateFormatted}',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Tracking live GPS • Tap to view dashboard',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_ios_rounded, color: badgeColor, size: 16),
          ],
        ),
      ),
    );
  }
}

/// Banner displayed on the Safety dashboard when a contact this user protects
/// has an active Ride Safety Check-in session in progress.
class _IncomingProtectedRideCard extends StatelessWidget {
  final RideCheckinModel ride;

  const _IncomingProtectedRideCard({required this.ride});

  @override
  Widget build(BuildContext context) {
    final isOverdue = ride.isOverdue;
    final cardBg = isOverdue ? const Color(0xFFFFF3E0) : const Color(0xFFF3E8FF);
    final borderColor = isOverdue ? const Color(0xFFFFB74D) : const Color(0xFFC084FC);
    final badgeColor = isOverdue ? Colors.deepOrange : const Color(0xFF7E22CE);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => RideDetailsScreen(rideId: ride.id)),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 1.3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.shield_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isOverdue ? Colors.deepOrange : const Color(0xFF9333EA),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isOverdue ? 'PROTECTED RIDE OVERDUE' : 'PROTECTED CONTACT ON RIDE',
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: badgeColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'LIVE',
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF9333EA),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${ride.userName} • ${ride.rideType}',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Vehicle: ${ride.plateFormatted} • Tap to track live',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Track',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Quick Actions ─────────────────────────────────────────────

/// Immutable data model for a single Quick Action card.
class _QuickActionItem {
  final IconData icon;
  final String label;
  final Color iconColor;
  final Color iconBackground;

  const _QuickActionItem({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.iconBackground,
  });
}

/// 2×2 responsive grid of Quick Action cards.
class _QuickActionsGrid extends StatelessWidget {
  final void Function(String label) onAction;

  const _QuickActionsGrid({required this.onAction});

  /// Static list of the four quick actions shown in the mockup.
  static const List<_QuickActionItem> _items = [
    _QuickActionItem(
      icon: Icons.phone_in_talk_rounded,
      label: 'Fake Call',
      iconColor: AppColors.actionBlue,
      iconBackground: Color(0xFFDDEEFD),
    ),
    _QuickActionItem(
      icon: Icons.campaign_rounded,
      label: 'Loud Siren',
      iconColor: AppColors.actionOrange,
      iconBackground: Color(0xFFFEEDD8),
    ),
    _QuickActionItem(
      icon: Icons.directions_walk_rounded,
      label: 'Safe Journey',
      iconColor: AppColors.actionGreen,
      iconBackground: Color(0xFFDFF5E3),
    ),
    _QuickActionItem(
      icon: Icons.local_taxi_rounded,
      label: 'Ride Check-in',
      iconColor: AppColors.actionBlue,
      iconBackground: Color(0xFFE3F2FD),
    ),
    _QuickActionItem(
      icon: Icons.calculate_rounded,
      label: 'Camouflage',
      iconColor: AppColors.textPrimary,
      iconBackground: Color(0xFFEEEEF2),
    ),
    _QuickActionItem(
      icon: Icons.security_rounded,
      label: 'Silent Panic',
      iconColor: AppColors.sosRed,
      iconBackground: Color(0xFFFFEEEE),
    ),
    _QuickActionItem(
      icon: Icons.radar_rounded,
      label: 'Being Followed',
      iconColor: AppColors.actionOrange,
      iconBackground: Color(0xFFFFF3E0),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
      childAspectRatio: 1.15,
      children: _items
          .map((item) => _QuickActionCard(item: item, onTap: onAction))
          .toList(),
    );
  }
}

/// Individual Quick Action card with icon, background tint, and label.
/// Dynamically updates UI state when 'Loud Siren' is playing.
class _QuickActionCard extends StatelessWidget {
  final _QuickActionItem item;
  final void Function(String) onTap;

  const _QuickActionCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (item.label == 'Loud Siren') {
      return ValueListenableBuilder<bool>(
        valueListenable: SirenService.instance.isPlayingNotifier,
        builder: (context, isSirenPlaying, child) {
          return _buildCard(
            context,
            isSirenActive: isSirenPlaying,
          );
        },
      );
    }
    return _buildCard(context, isSirenActive: false);
  }

  Widget _buildCard(BuildContext context, {required bool isSirenActive}) {
    final cardBg = isSirenActive ? AppColors.sosRed.withValues(alpha: 0.12) : AppColors.surface;
    final iconBg = isSirenActive ? AppColors.sosRed : item.iconBackground;
    final iconColor = isSirenActive ? Colors.white : item.iconColor;
    final labelText = isSirenActive ? 'STOP SIREN 🔇' : item.label;

    return GestureDetector(
      onTap: () => onTap(item.label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: isSirenActive
              ? Border.all(color: AppColors.sosRed, width: 2)
              : null,
          boxShadow: [
            BoxShadow(
              color: isSirenActive
                  ? AppColors.sosRed.withValues(alpha: 0.3)
                  : Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Coloured icon container
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(item.icon, color: iconColor, size: 28),
            ),

            const SizedBox(height: 10),

            // Action label
            Text(
              labelText,
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: isSirenActive ? FontWeight.w800 : FontWeight.w600,
                color: isSirenActive ? AppColors.sosRed : AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bottom Navigation Bar ─────────────────────────────────────

/// Bottom nav bar with 4 tabs: Safety · Map · Contacts · Settings
class _AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _AppBottomNav({
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: onTap,
        // Transparent so the Container's white bg shows through
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textSecondary,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: GoogleFonts.poppins(
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: GoogleFonts.poppins(
          fontSize: 11,
          fontWeight: FontWeight.w400,
        ),
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.shield_outlined),
            activeIcon: Icon(Icons.shield_rounded),
            label: 'Safety',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map_rounded),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: ContactSyncService.instance.incomingRequestsNotifier,
              builder: (context, requests, _) {
                final count = requests.length;
                return Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  backgroundColor: AppColors.sosRed,
                  child: const Icon(Icons.group_outlined),
                );
              },
            ),
            activeIcon: ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: ContactSyncService.instance.incomingRequestsNotifier,
              builder: (context, requests, _) {
                final count = requests.length;
                return Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  backgroundColor: AppColors.sosRed,
                  child: const Icon(Icons.group_rounded),
                );
              },
            ),
            label: 'Contacts',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
