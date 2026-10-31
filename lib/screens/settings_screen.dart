import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';
import '../models/user_profile_model.dart';
import '../models/activity_model.dart';
import '../services/auth_service.dart';
import '../services/activity_service.dart';
import '../services/battery_alert_service.dart';
import '../services/pin_security_service.dart';
import '../services/motion_detection_service.dart';
import '../services/sos_escalation_service.dart';
import '../services/esp32_ble_service.dart';
import '../widgets/pin_input_dialog.dart';
import 'profile_screen.dart';
import 'sos_history_screen.dart';

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
  bool _criticalBatteryAlert = true;
  bool _sirenOnAutoSos = false;
  bool _fallDetection = false;
  bool _smartEscalation = true;
  bool _pinProtection = false;
  bool _requirePinOnOpen = false;
  bool _hasRealPin = false;
  bool _hasDuressPin = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final criticalBattery = await BatteryAlertService.instance.isEnabled();
    final fallEnabled = await MotionDetectionService.instance.isFallDetectionEnabled();
    final escalationEnabled = await SosEscalationService.instance.isEnabled();
    final pinEnabled = await PinSecurityService.instance.isPinEnabled();
    final requireOnOpen = await PinSecurityService.instance.isPinRequiredOnOpen();
    final hasReal = await PinSecurityService.instance.isRealPinConfigured();
    final hasDuress = await PinSecurityService.instance.isDuressPinConfigured();

    if (!mounted) return;
    setState(() {
      _voiceActivation = prefs.getBool('pref_voice_activation') ?? true;
      _locationSharing = prefs.getBool('pref_location_sharing') ?? true;
      _notifications = prefs.getBool('pref_notifications') ?? true;
      _shakeToSOS = prefs.getBool('pref_shake_to_sos') ?? false;
      _criticalBatteryAlert = criticalBattery;
      _sirenOnAutoSos = prefs.getBool('pref_siren_on_auto_sos') ?? false;
      _fallDetection = fallEnabled;
      _smartEscalation = escalationEnabled;
      _pinProtection = pinEnabled;
      _requirePinOnOpen = requireOnOpen;
      _hasRealPin = hasReal;
      _hasDuressPin = hasDuress;
    });
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
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
                  ValueListenableBuilder<Esp32ConnectionStatus>(
                    valueListenable: Esp32BleService.instance.connectionStateNotifier,
                    builder: (context, status, _) {
                      final isConn = status == Esp32ConnectionStatus.connected;
                      final subtitle = isConn
                          ? 'ESP32 Connected • ${Esp32BleService.instance.batteryLevelNotifier.value}% Battery'
                          : (status == Esp32ConnectionStatus.connecting
                              ? 'Connecting to ESP32...'
                              : 'ESP32 Disconnected (Tap to connect)');
                      return _buildNavItem(
                        icon: Icons.bluetooth_rounded,
                        iconColor: AppColors.actionBlue,
                        iconBg: const Color(0xFFDDEEFD),
                        label: 'Device Setup',
                        subtitle: subtitle,
                        trailing: _StatusDot(
                          color: isConn
                              ? AppColors.successForeground
                              : (status == Esp32ConnectionStatus.connecting
                                  ? const Color(0xFFFFA000)
                                  : AppColors.sosRed),
                        ),
                        onTap: _showDeviceSetupModal,
                      );
                    },
                  ),
                  ValueListenableBuilder<List<ActivityItem>>(
                    valueListenable: ActivityService.instance.activitiesNotifier,
                    builder: (context, activities, _) {
                      final count = activities.where((a) => a.type == ActivityType.sos).length;
                      final subtitle = count > 0
                          ? '$count SOS alerts recorded'
                          : '${activities.length} total events logged';
                      return _buildNavItem(
                        icon: Icons.history_rounded,
                        iconColor: AppColors.actionPurple,
                        iconBg: const Color(0xFFF0E6F9),
                        label: 'Alert History',
                        subtitle: subtitle,
                        onTap: _showAlertHistoryModal,
                      );
                    },
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
                    onChanged: (v) {
                      setState(() => _voiceActivation = v);
                      _saveSetting('pref_voice_activation', v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.vibration_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: const Color(0xFFFFE5E5),
                    label: 'Shake to SOS',
                    subtitle: 'Shake phone 3× to alert',
                    value: _shakeToSOS,
                    onChanged: (v) {
                      setState(() => _shakeToSOS = v);
                      _saveSetting('pref_shake_to_sos', v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.location_on_rounded,
                    iconColor: AppColors.actionGreen,
                    iconBg: const Color(0xFFDFF5E3),
                    label: 'Live Location Sharing',
                    subtitle: 'Share with emergency contacts',
                    value: _locationSharing,
                    onChanged: (v) {
                      setState(() => _locationSharing = v);
                      _saveSetting('pref_location_sharing', v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.battery_alert_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: const Color(0xFFFFE5E5),
                    label: 'Critical Battery Alert',
                    subtitle: 'Auto-SMS location when battery ≤ 10%',
                    value: _criticalBatteryAlert,
                    onChanged: (v) {
                      setState(() => _criticalBatteryAlert = v);
                      BatteryAlertService.instance.setEnabled(v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.volume_up_rounded,
                    iconColor: AppColors.actionOrange,
                    iconBg: const Color(0xFFFEEDD8),
                    label: 'Siren on automatic SOS',
                    subtitle: 'Sound loud alarm on dead-man switch expiry',
                    value: _sirenOnAutoSos,
                    onChanged: (v) {
                      setState(() => _sirenOnAutoSos = v);
                      _saveSetting('pref_siren_on_auto_sos', v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.personal_injury_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: const Color(0xFFFFE5E5),
                    label: 'Fall Detection',
                    subtitle: 'Auto-checks safety if impact & stillness detected',
                    value: _fallDetection,
                    onChanged: (v) async {
                      setState(() => _fallDetection = v);
                      await MotionDetectionService.instance.setEnabled(v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.trending_up_rounded,
                    iconColor: AppColors.primaryViolet,
                    iconBg: const Color(0xFFEDE7F6),
                    label: 'Smart SOS Escalation',
                    subtitle: 'Alerts backup contacts at 3m; prompts 999 at 8m if unanswered',
                    value: _smartEscalation,
                    onChanged: (v) async {
                      setState(() => _smartEscalation = v);
                      await SosEscalationService.instance.setEnabled(v);
                    },
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Section: Security PIN & Camouflage ──────────────────
              _buildSection(
                title: 'Security PIN & Camouflage',
                items: [
                  _buildToggleItem(
                    icon: Icons.shield_outlined,
                    iconColor: AppColors.primary,
                    iconBg: AppColors.primarySurface,
                    label: 'PIN Protection',
                    subtitle: 'Protect "I\'m Safe" & Safe Journey cancellation',
                    value: _pinProtection,
                    onChanged: (v) async {
                      if (v && !_hasRealPin) {
                        final set = await PinInputDialog.show(
                          context,
                          mode: PinDialogMode.setupReal,
                        );
                        if (set == true) {
                          await PinSecurityService.instance.setPinEnabled(true);
                          _loadSettings();
                        }
                      } else {
                        await PinSecurityService.instance.setPinEnabled(v);
                        setState(() => _pinProtection = v);
                      }
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.pin_rounded,
                    iconColor: AppColors.actionGreen,
                    iconBg: const Color(0xFFDFF5E3),
                    label: 'Real Security PIN',
                    subtitle: _hasRealPin ? 'Configured • Tap to change' : 'Tap to configure 4-digit PIN',
                    onTap: () async {
                      final set = await PinInputDialog.show(
                        context,
                        mode: PinDialogMode.setupReal,
                      );
                      if (set == true) {
                        await _loadSettings();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('✅ Real PIN configured successfully'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.warning_amber_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: const Color(0xFFFFEEEE),
                    label: 'Duress Emergency PIN',
                    subtitle: _hasDuressPin ? 'Configured • Silent panic & camouflage' : 'Tap to configure silent emergency PIN',
                    onTap: () async {
                      final set = await PinInputDialog.show(
                        context,
                        mode: PinDialogMode.setupDuress,
                      );
                      if (set == true) {
                        await _loadSettings();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('✅ Duress PIN configured successfully'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.lock_outline_rounded,
                    iconColor: AppColors.actionPurple,
                    iconBg: const Color(0xFFF0E6F9),
                    label: 'Require PIN to open app',
                    subtitle: 'Lock application on startup',
                    value: _requirePinOnOpen,
                    onChanged: (v) async {
                      if (v && !_hasRealPin) {
                        final set = await PinInputDialog.show(
                          context,
                          mode: PinDialogMode.setupReal,
                        );
                        if (set == true) {
                          await PinSecurityService.instance.setPinRequiredOnOpen(true);
                          _loadSettings();
                        }
                      } else {
                        await PinSecurityService.instance.setPinRequiredOnOpen(v);
                        setState(() => _requirePinOnOpen = v);
                      }
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.calculate_rounded,
                    iconColor: AppColors.textPrimary,
                    iconBg: const Color(0xFFEEEEF2),
                    label: 'Camouflage Calculator Preview',
                    subtitle: 'Test disguised calculator screen (Exit: Real PIN + =)',
                    onTap: () async {
                      if (!_hasRealPin) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Please set up your Security PIN first to test Camouflage mode.',
                              style: GoogleFonts.poppins(color: Colors.white),
                            ),
                            backgroundColor: AppColors.primary,
                          ),
                        );
                        return;
                      }
                      await PinSecurityService.instance.enterCamouflageManually();
                    },
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
                    onChanged: (v) {
                      setState(() => _notifications = v);
                      _saveSetting('pref_notifications', v);
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.history_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: const Color(0xFFFFEEEE),
                    label: 'SOS Alert History',
                    subtitle: 'View all past emergency alerts and responses',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SosHistoryScreen()),
                      );
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.do_not_disturb_on_rounded,
                    iconColor: AppColors.textSecondary,
                    iconBg: const Color(0xFFEEEEF2),
                    label: 'Do Not Disturb',
                    subtitle: 'Emergency override enabled',
                    onTap: _showDndModal,
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
                    subtitle: 'Local encryption & zero tracking',
                    onTap: _showPrivacyModal,
                  ),
                  _buildNavItem(
                    icon: Icons.info_outline_rounded,
                    iconColor: AppColors.textSecondary,
                    iconBg: const Color(0xFFEEEEF2),
                    label: 'About App',
                    subtitle: 'Woman Guard v1.0.0',
                    onTap: _showAboutModal,
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

  void _showDeviceSetupModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDDEEFD),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.bluetooth_connected_rounded,
                      color: AppColors.actionBlue, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ESP32 Smart Pendant',
                          style: GoogleFonts.poppins(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                      Row(
                        children: [
                          const _StatusDot(color: AppColors.successForeground),
                          const SizedBox(width: 6),
                          Text('Connected via BLE • Active',
                              style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.successForeground)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  _buildDeviceStatRow(
                    icon: Icons.battery_charging_full_rounded,
                    label: 'Battery Level',
                    value: '92% (Normal)',
                    color: AppColors.successForeground,
                  ),
                  const Divider(height: 16),
                  _buildDeviceStatRow(
                    icon: Icons.signal_cellular_alt_rounded,
                    label: 'BLE Signal',
                    value: '-58 dBm (Strong)',
                    color: AppColors.actionBlue,
                  ),
                  const Divider(height: 16),
                  _buildDeviceStatRow(
                    icon: Icons.fingerprint_rounded,
                    label: 'Hardware Trigger',
                    value: 'Double-click Button',
                    color: AppColors.sosRed,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Esp32BleService.instance.handleHardwareSosTrigger(
                    reason: 'Settings Test Button',
                  );
                },
                icon: const Icon(Icons.touch_app_rounded, color: Colors.white),
                label: Text('Test Hardware Trigger',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceStatRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Text(label,
            style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
        const Spacer(),
        Text(value,
            style: GoogleFonts.poppins(
                fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      ],
    );
  }

  void _showAlertHistoryModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => FutureBuilder<List<ActivityItem>>(
        future: ActivityService.instance.getActivities(),
        builder: (context, snapshot) {
          final activities = snapshot.data ?? ActivityService.instance.activitiesNotifier.value;
          return Container(
            height: MediaQuery.of(context).size.height * 0.7,
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0E6F9),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.history_rounded,
                          color: AppColors.actionPurple, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Text('Safety & Alert History',
                        style: GoogleFonts.poppins(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: activities.isEmpty
                      ? Center(
                          child: Text('No alert activity logged yet.',
                              style: GoogleFonts.poppins(
                                  fontSize: 14, color: AppColors.textSecondary)),
                        )
                      : ListView.separated(
                          itemCount: activities.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = activities[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: item.bgColor,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(item.icon, color: item.iconColor, size: 20),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(item.title,
                                            style: GoogleFonts.poppins(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.textPrimary)),
                                        Text(item.subtitle,
                                            style: GoogleFonts.poppins(
                                                fontSize: 11,
                                                color: AppColors.textSecondary)),
                                      ],
                                    ),
                                  ),
                                  Text(item.timeAgo,
                                      style: GoogleFonts.poppins(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.textSecondary)),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showDndModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.do_not_disturb_on_rounded, color: AppColors.sosRed),
            const SizedBox(width: 8),
            Text('Do Not Disturb',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Text(
          'Emergency Override Policy:\n\nEmergency SOS triggers, loud sirens, and offline alerts will bypass Do Not Disturb to protect your personal safety in critical situations.',
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('Understood',
                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _showPrivacyModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.lock_rounded, color: AppColors.actionBlue),
            const SizedBox(width: 8),
            Text('Privacy & Security',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPrivacyBullet(
              title: 'Offline-First SMS Fallback',
              desc: 'SMS alerts are sent directly from your SIM card when offline — no middleman server.',
            ),
            const SizedBox(height: 10),
            _buildPrivacyBullet(
              title: 'On-Demand Location Only',
              desc: 'Live GPS location is accessed only when you trigger SOS or use the Safe Route Map.',
            ),
            const SizedBox(height: 10),
            _buildPrivacyBullet(
              title: 'Secure Mutual Sync',
              desc: 'Guardian connections require two-way email confirmation and are protected by Firestore security rules.',
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('Close',
                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyBullet({required String title, required String desc}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline_rounded,
            color: AppColors.successForeground, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              Text(desc,
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }

  void _showAboutModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.shield_rounded, color: AppColors.primary),
            const SizedBox(width: 8),
            Text('Woman Guard',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Smart Women Safety & Emergency Response',
                style: GoogleFonts.poppins(
                    fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text('Version 1.0.0 • Final Year Project',
                style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            Text('Designed with real-time mutual cloud sync, offline SMS redundancy, BLE hardware pendant integration, and emergency audio sirens.',
                style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, height: 1.4)),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('Close',
                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
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
