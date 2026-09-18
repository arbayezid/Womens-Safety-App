import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/app_colors.dart';
import '../models/user_profile_model.dart';
import '../services/auth_service.dart';
import 'profile_screen.dart';

/// Settings screen — app preferences, security, notifications,
/// device setup, alert history and logout.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _voiceActivation = true;
  bool _locationSharing = true;
  bool _notifications = true;
  bool _shakeToSOS = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────────────────
              _buildHeader(),

              // ── Profile mini card ────────────────────────────────────
              _buildProfileMiniCard(context),

              const SizedBox(height: 20),

              // ── Section: Device ─────────────────────────────────────
              _buildSection(
                title: 'Device',
                items: [
                  _buildNavItem(
                    icon: Icons.bluetooth_rounded,
                    iconColor: AppColors.actionBlue,
                    iconBg: const Color(0xFFDDEEFD),
                    label: 'Device Setup',
                    subtitle: 'ESP32 Connected',
                    trailing: const _StatusDot(color: AppColors.successForeground),
                    onTap: () => _showSnack('Device Setup'),
                  ),
                  _buildNavItem(
                    icon: Icons.history_rounded,
                    iconColor: AppColors.actionPurple,
                    iconBg: const Color(0xFFF0E6F9),
                    label: 'Alert History',
                    subtitle: '3 alerts this week',
                    onTap: () => _showSnack('Alert History'),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Section: Safety ─────────────────────────────────────
              _buildSection(
                title: 'Safety Features',
                items: [
                  _buildToggleItem(
                    icon: Icons.mic_rounded,
                    iconColor: AppColors.actionOrange,
                    iconBg: const Color(0xFFFEEDD8),
                    label: 'Voice Activation',
                    subtitle: 'Say "Help" to trigger SOS',
                    value: _voiceActivation,
                    onChanged: (v) => setState(() => _voiceActivation = v),
                  ),
                  _buildToggleItem(
                    icon: Icons.vibration_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: const Color(0xFFFFE5E5),
                    label: 'Shake to SOS',
                    subtitle: 'Shake phone 3× to alert',
                    value: _shakeToSOS,
                    onChanged: (v) => setState(() => _shakeToSOS = v),
                  ),
                  _buildToggleItem(
                    icon: Icons.location_on_rounded,
                    iconColor: AppColors.actionGreen,
                    iconBg: const Color(0xFFDFF5E3),
                    label: 'Live Location Sharing',
                    subtitle: 'Share with emergency contacts',
                    value: _locationSharing,
                    onChanged: (v) => setState(() => _locationSharing = v),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Section: Notifications ──────────────────────────────
              _buildSection(
                title: 'Notifications',
                items: [
                  _buildToggleItem(
                    icon: Icons.notifications_rounded,
                    iconColor: AppColors.primary,
                    iconBg: AppColors.primarySurface,
                    label: 'Push Notifications',
                    subtitle: 'Alerts and system messages',
                    value: _notifications,
                    onChanged: (v) => setState(() => _notifications = v),
                  ),
                  _buildNavItem(
                    icon: Icons.do_not_disturb_on_rounded,
                    iconColor: AppColors.textSecondary,
                    iconBg: const Color(0xFFEEEEF2),
                    label: 'Do Not Disturb',
                    subtitle: 'Schedule quiet hours',
                    onTap: () => _showSnack('Do Not Disturb'),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Section: App ────────────────────────────────────────
              _buildSection(
                title: 'App',
                items: [
                  _buildNavItem(
                    icon: Icons.lock_rounded,
                    iconColor: AppColors.actionBlue,
                    iconBg: const Color(0xFFDDEEFD),
                    label: 'Privacy & Security',
                    subtitle: 'PIN lock, biometrics',
                    onTap: () => _showSnack('Privacy'),
                  ),
                  _buildNavItem(
                    icon: Icons.info_outline_rounded,
                    iconColor: AppColors.textSecondary,
                    iconBg: const Color(0xFFEEEEF2),
                    label: 'About App',
                    subtitle: 'Woman Guard v1.0.0',
                    onTap: () => _showSnack('About'),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // ── Logout / Login button ───────────────────────────────
              _buildLogoutButton(),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Text('Settings',
              style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const Spacer(),
          const Icon(Icons.settings_rounded, color: AppColors.primary, size: 24),
        ],
      ),
    );
  }

  Widget _buildProfileMiniCard(BuildContext context) {
    return ValueListenableBuilder<UserProfile>(
      valueListenable: AuthService.instance.profileNotifier,
      builder: (context, profile, _) {
        final photoUrl = AuthService.instance.photoUrl;
        final displayName = profile.name.isNotEmpty && profile.name != 'Guest'
            ? profile.name
            : AuthService.instance.displayName;
        final initials = profile.initials;
        final isAuth = AuthService.instance.isAuthenticated;
        final subtitle = profile.phone.isNotEmpty
            ? profile.phone
            : (profile.email.isNotEmpty
                ? profile.email
                : (isAuth ? 'Google Account: Active' : 'Explore Mode • Tap to sign in'));

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.primaryLight],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 6))
                ],
              ),
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      shape: BoxShape.circle,
                      image: photoUrl != null
                          ? DecorationImage(
                              image: NetworkImage(photoUrl),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: photoUrl == null
                        ? Text(initials,
                            style: GoogleFonts.poppins(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(displayName,
                            style: GoogleFonts.poppins(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                        Text(subtitle,
                            style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.85))),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ProfileScreen()),
                      );
                    },
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20)),
                      child: Text('Edit',
                          style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> items,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3))
              ],
            ),
            child: Column(
              children: [
                for (int i = 0; i < items.length; i++) ...[
                  items[i],
                  if (i < items.length - 1)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(height: 1, color: AppColors.background),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String label,
    required String subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: iconBg, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  Text(subtitle,
                      style: GoogleFonts.poppins(
                          fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
            if (trailing != null) ...[
              trailing,
              const SizedBox(width: 8),
            ],
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleItem({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: iconBg, borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                if (subtitle.isNotEmpty)
                  Text(subtitle,
                      style: GoogleFonts.poppins(
                          fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
            activeTrackColor: AppColors.primarySurface,
            inactiveThumbColor: AppColors.textSecondary,
            inactiveTrackColor: const Color(0xFFEEEEF2),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton() {
    return ValueListenableBuilder<User?>(
      valueListenable: AuthService.instance.userNotifier,
      builder: (context, user, _) {
        final isAuthenticated = AuthService.instance.isAuthenticated;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: () => isAuthenticated ? _confirmLogout() : _signInWithGoogle(),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 3))
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: isAuthenticated
                            ? const Color(0xFFFFE5E5)
                            : AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(12)),
                    alignment: Alignment.center,
                    child: Icon(
                        isAuthenticated
                            ? Icons.logout_rounded
                            : Icons.login_rounded,
                        color: isAuthenticated
                            ? AppColors.sosRed
                            : AppColors.primary,
                        size: 20),
                  ),
                  const SizedBox(width: 14),
                  Text(
                      isAuthenticated
                          ? 'Log Out'
                          : 'Sign In with Google',
                      style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isAuthenticated
                              ? AppColors.sosRed
                              : AppColors.primary)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _signInWithGoogle() async {
    final res = await AuthService.instance.signInWithGoogle();
    if (!mounted) return;
    if (res.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Successfully signed in with Google!'),
          backgroundColor: AppColors.successForeground,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (!res.isCancelled && res.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.errorMessage!),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showSnack(String label) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$label tapped',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 1),
    ));
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Log Out',
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        content: Text('Are you sure you want to log out? You will be switched to Guest Mode.',
            style: GoogleFonts.poppins(
                fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await AuthService.instance.signOut();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Logged out. Switched to Guest Mode.'),
                  backgroundColor: AppColors.textPrimary,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sosRed,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: Text('Log Out',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Small colored status dot widget.
class _StatusDot extends StatelessWidget {
  final Color color;
  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ],
    );
  }
}
