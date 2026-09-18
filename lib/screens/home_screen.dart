import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/emergency_service.dart';
import '../services/location_service.dart';
import '../services/siren_service.dart';
import '../services/auth_service.dart';
import '../services/activity_service.dart';
import '../utils/auth_guard.dart';
import 'map_screen.dart';
import 'contacts_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';

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
  }

  @override
  void dispose() {
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

      setState(() {
        _isSOSLoading = false;
      });

      if (result.isSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ SOS Alert Dispatched! Location sent to ${result.contactsSentCount} contact(s).',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
            backgroundColor: AppColors.successForeground,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
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
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSOSLoading = false;
      });

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
    }
  }

  /// Handles Quick Action cards (e.g. Loud Siren trigger).
  Future<void> _onQuickAction(String label) async {
    HapticFeedback.selectionClick();

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

    // Log the quick action event
    ActivityService.instance.logQuickAction(label);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label tapped',
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
          ),

          // Tab 1 — Map
          const MapScreen(),

          // Tab 2 — Contacts
          const ContactsScreen(),

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

  const _SafetyDashboard({
    required this.pulseAnimation,
    required this.isSOSLoading,
    required this.onSOSPressed,
    required this.onQuickAction,
    required this.onAvatarTap,
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

/// Custom header row: tappable avatar · greeting · ESP32 badge
///
/// [onAvatarTap] is forwarded from the shell to open [ProfileScreen].
class _TopAppBar extends StatelessWidget {
  final VoidCallback onAvatarTap;
  const _TopAppBar({required this.onAvatarTap});

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
              onTap: onAvatarTap,
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

            // ── Greeting + guardian mode subtitle ───────────────────────
            Expanded(
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

            // ── ESP32 status badge ───────────────────────────────────────
            _ESP32Badge(),
          ],
        );
      },
    );
  }
}

/// Pill-shaped badge showing ESP32 connection status.
class _ESP32Badge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.successBackground,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Green dot indicator
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.successForeground,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'ESP32 Connected',
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.successForeground,
            ),
          ),
        ],
      ),
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
  LocationResult _result = const LocationResult(status: LocationStateStatus.loading);
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    // Initial location query
    _fetchLocation();
  }

  @override
  void dispose() {
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

    setState(() {
      _result = LocationResult.loading();
    });
    _spinController.repeat();

    try {
      final res = await LocationService.instance.getCurrentLocation(
        requestPermission: requestPermission,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _result = LocationResult.error(e.toString());
      });
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
        return _buildHasDataState(_result.data!);

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
      icon: Icons.mic_rounded,
      label: 'Record Audio',
      iconColor: AppColors.actionPurple,
      iconBackground: Color(0xFFF0E6F9),
    ),
    _QuickActionItem(
      icon: Icons.route_rounded,
      label: 'Safe Route',
      iconColor: AppColors.actionGreen,
      iconBackground: Color(0xFFDFF5E3),
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
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.shield_outlined),
            activeIcon: Icon(Icons.shield_rounded),
            label: 'Safety',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map_rounded),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.group_outlined),
            activeIcon: Icon(Icons.group_rounded),
            label: 'Contacts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
