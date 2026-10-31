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
import 'sos_history_screen.dart';
import 'incident_room_screen.dart';
import 'followed_mode_screen.dart';
import '../widgets/fake_call_dialog.dart';
import '../models/journey_model.dart';
import '../services/journey_service.dart';
import '../widgets/active_journey_card.dart';
import '../widgets/safety_check_dialog.dart';
import '../widgets/pin_input_dialog.dart';
import '../services/pin_security_service.dart';
import '../services/motion_detection_service.dart';
import 'start_journey_sheet.dart';
import '../models/ride_checkin.dart';
import '../services/ride_checkin_service.dart';
import '../services/esp32_ble_service.dart';
import 'ride_checkin_screen.dart';
import 'active_ride_screen.dart';
import 'ride_history_screen.dart';

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

    // Initialize ESP32 BLE hardware service safely
    Esp32BleService.instance.initialize();

    // Initialize real-time incoming guardian emergency alerts
    NotificationService.instance.startSosAlertStreamListener();
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
          await EmergencyService.instance.triggerEmergency(source: 'SOS Button');

      if (!mounted) return;

      if (result.isSuccess) {
        final bool needsManualSmsFallback =
            result.contactsSentCount == 0 && result.recipientPhones.isNotEmpty;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  needsManualSmsFallback
                      ? Icons.mark_email_read_rounded
                      : Icons.check_circle_rounded,
                  color: Colors.white,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.message.isNotEmpty
                        ? result.message
                        : '✅ SOS Alert Dispatched! Location sent to ${result.contactsSentCount} contact(s).',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
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
            backgroundColor: needsManualSmsFallback
                ? AppColors.primaryViolet
                : AppColors.successForeground,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.all(16),
            duration: Duration(seconds: needsManualSmsFallback ? 6 : 4),
          ),
        );
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

  /// Handles Quick Action cards (e.g. Loud Siren trigger).
  Future<void> _onQuickAction(String label) async {
    HapticFeedback.selectionClick();

    if (label == 'Fake Call') {
      await FakeCallDialog.show(context);
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
                  Text(
                    'Being Followed?',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 18),
                  ),
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

            // ── Active Ride Safety Check-in Card ───────────────────
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

            const SizedBox(height: 16),

            // ── 2. Current Location Card ───────────────────────────
            const CurrentLocationCard(),

            const SizedBox(height: 28),

            // ── 3. SOS Button (pulsating rings) ───────────────────
            Center(
              child: _SOSButton(
                pulseAnimation: pulseAnimation,
                isLoading: isSOSLoading,
                onPressed: onSOSPressed,
              ),
            ),

            const SizedBox(height: 16),

            // ── 4. "Tap to send" hint pill ────────────────────────
            const Center(child: _TapHintBadge()),

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
    final isPinEnabled = await PinSecurityService.instance.isPinEnabled();
    final isRealConfigured = await PinSecurityService.instance.isRealPinConfigured();

    if (isPinEnabled && isRealConfigured) {
      if (!mounted) return;
      final verified = await PinInputDialog.show(
        context,
        mode: PinDialogMode.verify,
        customTitle: 'Confirm Safety',
        customSubtitle: 'Enter your Security PIN to mark yourself safe and resolve this alert',
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
              const Icon(Icons.shield_rounded, color: AppColors.safeGreen, size: 28),
              const SizedBox(width: 10),
              Text(
                "I'm Safe Now",
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 18),
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

      if (confirmed != true || !mounted) return;
    }

    setState(() => _isResolving = true);
    try {
      await EmergencyService.instance.markSafe(alertId: widget.alertId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
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
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _isResolving = false);
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => IncidentRoomScreen(alertId: widget.alertId),
                        ),
                      );
                    },
                    icon: const Icon(Icons.meeting_room_rounded, size: 16, color: AppColors.sosRed),
                    label: Text(
                      'Incident Room',
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
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
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: _isResolving ? null : _handleMarkSafe,
                    icon: _isResolving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                    label: Text(
                      _isResolving ? 'Resolving...' : "I'M SAFE NOW",
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.safeGreen,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
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
                      NotificationService.instance.showActiveSosDialogIfAvailable(context);
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

            // ── SOS History Quick Access Button ──────────────────────
            Tooltip(
              message: 'SOS Alert History',
              child: GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SosHistoryScreen()),
                  );
                },
                child: Container(
                  width: 34,
                  height: 34,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEEEE),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.sosRed.withValues(alpha: 0.25)),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.history_rounded,
                    color: AppColors.sosRed,
                    size: 19,
                  ),
                ),
              ),
            ),

            // ── Ride Check-in History Button ────────────────────────
            Tooltip(
              message: 'Ride Check-in History',
              child: GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RideHistoryScreen()),
                  );
                },
                child: Container(
                  width: 34,
                  height: 34,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.actionBlue.withValues(alpha: 0.25)),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.directions_car_rounded,
                    color: AppColors.actionBlue,
                    size: 18,
                  ),
                ),
              ),
            ),

            // ── ESP32 status badge ───────────────────────────────────────
            _ESP32Badge(),
          ],
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
          onTap: () {
            if (status != Esp32ConnectionStatus.connected) {
              Esp32BleService.instance.connectToDevice();
            }
          },
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

/// Central SOS button composed of three concentric circles
/// that breathe via [pulseAnimation] and shows loading indicator on trigger.
class _SOSButton extends StatelessWidget {
  final Animation<double> pulseAnimation;
  final bool isLoading;
  final VoidCallback onPressed;

  const _SOSButton({
    required this.pulseAnimation,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (_, child) => Transform.scale(
        scale: pulseAnimation.value,
        child: child,
      ),
      child: GestureDetector(
        onTap: onPressed,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outermost ring — very light pink
            Container(
              width: 230,
              height: 230,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosOuterRing,
              ),
            ),

            // Middle ring — medium pink/red
            Container(
              width: 188,
              height: 188,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosMediumRing,
              ),
            ),

            // Core SOS button — radial red gradient
            Container(
              width: 146,
              height: 146,
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
              child: isLoading
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
            ),
          ],
        ),
      ),
    );
  }
}

/// Small pill badge beneath the SOS button: "Tap to send instant alert"
class _TapHintBadge extends StatelessWidget {
  const _TapHintBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFEEEEF2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.touch_app_rounded,
            size: 15,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 5),
          Text(
            'Tap to send instant alert',
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
        ? '${ride.expectedMinutes}m trip'
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
