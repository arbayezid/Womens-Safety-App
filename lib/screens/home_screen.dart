import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
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

  /// Placeholder: fires when the SOS button is tapped.
  void _onSOSPressed() {
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🚨 SOS Alert Triggered!',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.sosRed,
        behavior: SnackBarBehavior.floating,
        shape: const StadiumBorder(),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// Placeholder: fires when a Quick Action card is tapped.
  void _onQuickAction(String label) {
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
  final VoidCallback onSOSPressed;
  final void Function(String) onQuickAction;
  final VoidCallback onAvatarTap;

  const _SafetyDashboard({
    required this.pulseAnimation,
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
            const _LocationCard(),

            const SizedBox(height: 28),

            // ── 3. SOS Button (pulsating rings) ───────────────────
            Center(
              child: _SOSButton(
                pulseAnimation: pulseAnimation,
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ── Tappable avatar circle (opens Profile) ──────────────────
        GestureDetector(
          onTap: onAvatarTap,
          child: Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primarySurface,
            ),
            alignment: Alignment.center,
            child: Text(
              'R',
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
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
                'Hi, Alexa! 👋',
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                'Guardian Mode: ON',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),

        // ── ESP32 status badge ───────────────────────────────────────
        _ESP32Badge(),
      ],
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

/// White rounded card showing the user's current location.
class _LocationCard extends StatelessWidget {
  const _LocationCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
      child: Row(
        children: [
          // Location icon inside a soft red circle
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

          // Location label + address
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                'Road 11, Banani, Dhaka',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Central SOS button composed of three concentric circles
/// that breathe via [pulseAnimation].
class _SOSButton extends StatelessWidget {
  final Animation<double> pulseAnimation;
  final VoidCallback onPressed;

  const _SOSButton({
    required this.pulseAnimation,
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
              child: Text(
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
class _QuickActionCard extends StatelessWidget {
  final _QuickActionItem item;
  final void Function(String) onTap;

  const _QuickActionCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onTap(item.label),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
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
                color: item.iconBackground,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(item.icon, color: item.iconColor, size: 28),
            ),

            const SizedBox(height: 10),

            // Action label
            Text(
              item.label,
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
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
