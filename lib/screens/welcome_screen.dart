import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import 'home_screen.dart';

/// The first screen users see when they open Smart Safety.
///
/// Features:
/// - Solid primary purple background
/// - Animated shield + heart logo widget
/// - App name and subtitle
/// - "Get Started" pill button that navigates to [HomeScreen]
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  // Fade-in + slide-up animation controller for a polished entrance
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();

    // Set transparent status bar so it blends with the purple background
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    // Initialize fade + slide-up animation
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    ));

    // Start animation after first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fadeController.forward();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  /// Navigates to the [HomeScreen] replacing the welcome screen.
  void _onGetStarted() {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: SlideTransition(
              position: _slideAnimation,
              child: Column(
                children: [
                  // ── Spacer: push logo to vertical center ─────────────
                  const Spacer(flex: 3),

                  // ── Shield + Heart Logo ──────────────────────────────
                  const _ShieldLogoWidget(),

                  const SizedBox(height: 36),

                  // ── App Title ────────────────────────────────────────
                  Text(
                    'Smart Safety',
                    style: GoogleFonts.poppins(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textOnPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Subtitle ─────────────────────────────────────────
                  Text(
                    'Your personal guardian in your pocket.\nConnect device and stay safe.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppColors.textOnPrimary.withValues(alpha: 0.80),
                      height: 1.65,
                    ),
                  ),

                  const Spacer(flex: 3),

                  // ── Get Started Button ────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _onGetStarted,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.surface,
                        foregroundColor: AppColors.primary,
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 17),
                        elevation: 0,
                      ),
                      child: Text(
                        'Get Started',
                        style: GoogleFonts.poppins(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom stacked widget: white shield icon with the
/// brand purple heart layered inside — matching the mockup logo.
class _ShieldLogoWidget extends StatelessWidget {
  const _ShieldLogoWidget();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      height: 110,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft glow halo behind the shield
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.textOnPrimary.withValues(alpha: 0.12),
            ),
          ),

          // Shield icon — large, white
          const Icon(
            Icons.shield_rounded,
            size: 72,
            color: AppColors.textOnPrimary,
          ),

          // Heart icon positioned over the lower half of the shield
          const Positioned(
            bottom: 22,
            child: Icon(
              Icons.favorite_rounded,
              size: 28,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
