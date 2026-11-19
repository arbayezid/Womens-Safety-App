import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/auth_service.dart';
import 'home_screen.dart';
import '../widgets/ui/app_snack.dart';

/// First screen: logo, sign in with Google, or continue as a guest.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  bool _isSigningIn = false;

  @override
  void initState() {
    super.initState();

    // Set transparent status bar so it blends with the purple background
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    // Start animation after first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fadeController.forward();
      // If already logged in, navigate straight to dashboard
      if (AuthService.instance.isAuthenticated && mounted) {
        _navigateToHome();
      }
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  /// Navigates to the [HomeScreen] replacing the welcome screen.
  void _navigateToHome() {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  /// Triggers Google Sign-In pipeline.
  Future<void> _onGoogleSignIn() async {
    if (_isSigningIn) return;

    setState(() => _isSigningIn = true);

    try {
      final result = await AuthService.instance.signInWithGoogle();
      if (!mounted) return;

      if (result.isSuccess) {
        _navigateToHome();
      } else if (!result.isCancelled && result.errorMessage != null) {
        AppSnack.showBar(context,
          SnackBar(
            content: Text(result.errorMessage!),
            backgroundColor: AppColors.sosRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSigningIn = false);
      }
    }
  }

  /// Continues into the dashboard under Guest Mode.
  Future<void> _onContinueAsGuest() async {
    await AuthService.instance.continueAsGuest();
    if (mounted) {
      _navigateToHome();
    }
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
            child: Column(
                children: [
                  const Spacer(flex: 3),

                  const _ShieldLogoWidget(),

                  const SizedBox(height: 36),

                  Text(
                    'Woman Guard',
                    style: GoogleFonts.poppins(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textOnPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'Alert the people you trust in one tap,\nwith or without the ESP32 device.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppColors.textOnPrimary.withValues(alpha: 0.80),
                      height: 1.65,
                    ),
                  ),

                  const Spacer(flex: 3),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSigningIn ? null : _onGoogleSignIn,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.surface,
                        foregroundColor: AppColors.primary,
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 3,
                      ),
                      child: _isSigningIn
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.primary,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Image.asset(
                                  'assets/images/google_g.png',
                                  width: 20,
                                  height: 20,
                                  semanticLabel: 'Google',
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  'Continue with Google',
                                  style: GoogleFonts.poppins(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  TextButton(
                    onPressed: _isSigningIn ? null : _onContinueAsGuest,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textOnPrimary,
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 16),
                    ),
                    child: Text(
                      'Explore as Guest',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textOnPrimary.withValues(alpha: 0.9),
                        decoration: TextDecoration.underline,
                        decorationColor:
                            AppColors.textOnPrimary.withValues(alpha: 0.6),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
            ),
          ),
        ),
      ),
    );
  }
}

/// App logo: a white shield with the brand-purple heart inside.
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
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.textOnPrimary.withValues(alpha: 0.12),
            ),
          ),

          const Icon(
            Icons.shield_rounded,
            size: 72,
            color: AppColors.textOnPrimary,
          ),

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
