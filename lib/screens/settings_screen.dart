import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';
import '../models/user_profile_model.dart';
import '../models/activity_model.dart';
import '../models/fake_caller.dart';
import '../services/auth_service.dart';
import '../services/activity_service.dart';
import '../services/battery_alert_service.dart';
import '../services/fake_call_settings_service.dart';
import '../services/pin_security_service.dart';
import '../services/motion_detection_service.dart';
import '../services/shake_sos_service.dart';
import '../services/sos_escalation_service.dart';
import '../services/esp32_ble_service.dart';
import '../widgets/esp32_scan_sheet.dart';
import '../widgets/fake_call_caller_sheet.dart';
import '../widgets/pin_input_dialog.dart';
import 'background_reliability_screen.dart';
import 'fake_call_voice_screen.dart';
import 'profile_screen.dart';
import 'sos_history_screen.dart';
import 'ride_history_screen.dart';
import '../core/app_tokens.dart';
import '../core/app_text.dart';
import '../widgets/ui/app_snack.dart';
import '../widgets/ui/ui_tone.dart';

/// Settings screen — app preferences, security, notifications,
/// device setup, alert history and logout.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
  FakeCallVoiceLanguage _fakeCallLanguage = FakeCallVoiceLanguage.bangla;

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
    final shakeEnabled = await ShakeSosService.instance.isShakeEnabled();
    final escalationEnabled = await SosEscalationService.instance.isEnabled();
    final pinEnabled = await PinSecurityService.instance.isPinEnabled();
    final requireOnOpen = await PinSecurityService.instance.isPinRequiredOnOpen();
    final hasReal = await PinSecurityService.instance.isRealPinConfigured();
    final hasDuress = await PinSecurityService.instance.isDuressPinConfigured();
    final fakeCallLanguage = await FakeCallSettingsService.instance.loadLanguage();
    await FakeCallSettingsService.instance.loadCaller();

    if (!mounted) return;
    setState(() {
      _locationSharing = prefs.getBool('pref_location_sharing') ?? true;
      _notifications = prefs.getBool('pref_notifications') ?? true;
      _shakeToSOS = shakeEnabled;
      _criticalBatteryAlert = criticalBattery;
      _sirenOnAutoSos = prefs.getBool('pref_siren_on_auto_sos') ?? false;
      _fallDetection = fallEnabled;
      _smartEscalation = escalationEnabled;
      _pinProtection = pinEnabled;
      _requirePinOnOpen = requireOnOpen;
      _hasRealPin = hasReal;
      _hasDuressPin = hasDuress;
      _fakeCallLanguage = fakeCallLanguage;
    });
  }

  Future<void> _pickFakeCallLanguage() async {
    final picked = await showDialog<FakeCallVoiceLanguage>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Caller Voice Language',
            style: AppText.sectionTitle),
        children: [
          for (final lang in FakeCallVoiceLanguage.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, lang),
              child: Row(
                children: [
                  Icon(
                    lang == _fakeCallLanguage
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: AppColors.actionBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      lang == FakeCallVoiceLanguage.bangla
                          ? 'Bangla (default) — real recorded voices'
                          : 'English — original voice',
                      style: GoogleFonts.poppins(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await FakeCallSettingsService.instance.saveLanguage(picked);
    if (mounted) setState(() => _fakeCallLanguage = picked);
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
                        iconBg: AppColors.tintSky,
                        label: 'Device setup',
                        subtitle: subtitle,
                        trailing: _StatusDot(
                          color: isConn
                              ? AppColors.successForeground
                              : (status == Esp32ConnectionStatus.connecting
                                  ? AppColors.warningForeground
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
                        iconBg: AppColors.tintViolet,
                        label: 'Alert history',
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
                title: 'Safety features',
                items: [
                  _buildToggleItem(
                    icon: Icons.vibration_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: AppColors.tintRedStrong,
                    label: 'Shake to SOS',
                    subtitle: 'Shake phone hard 3× to alert (5s to cancel)',
                    value: _shakeToSOS,
                    onChanged: (v) async {
                      setState(() => _shakeToSOS = v);
                      await ShakeSosService.instance.setEnabled(v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.location_on_rounded,
                    iconColor: AppColors.actionGreen,
                    iconBg: AppColors.successBackground,
                    label: 'Live location sharing',
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
                    iconBg: AppColors.tintRedStrong,
                    label: 'Low battery alert',
                    subtitle: 'Texts your location when battery is 10% or lower',
                    value: _criticalBatteryAlert,
                    onChanged: (v) {
                      setState(() => _criticalBatteryAlert = v);
                      BatteryAlertService.instance.setEnabled(v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.volume_up_rounded,
                    iconColor: AppColors.actionOrange,
                    iconBg: AppColors.tintOrange,
                    label: 'Siren on automatic SOS',
                    subtitle: 'Sound the siren when a check-in timer runs out',
                    value: _sirenOnAutoSos,
                    onChanged: (v) {
                      setState(() => _sirenOnAutoSos = v);
                      _saveSetting('pref_siren_on_auto_sos', v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.personal_injury_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: AppColors.tintRedStrong,
                    label: 'Fall detection',
                    subtitle: 'Checks on you after a hard impact and no movement',
                    value: _fallDetection,
                    onChanged: (v) async {
                      setState(() => _fallDetection = v);
                      await MotionDetectionService.instance.setEnabled(v);
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.trending_up_rounded,
                    iconColor: AppColors.primary,
                    iconBg: AppColors.tintLavender,
                    label: 'Smart escalation',
                    subtitle: 'Backup contacts at 3 min, 999 prompt at 8 min',
                    value: _smartEscalation,
                    onChanged: (v) async {
                      setState(() => _smartEscalation = v);
                      await SosEscalationService.instance.setEnabled(v);
                    },
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Section: Fake Call ──────────────────────────────────
              _buildSection(
                title: 'Fake call',
                items: [
                  ValueListenableBuilder<FakeCaller>(
                    valueListenable: FakeCallSettingsService.instance.callerNotifier,
                    builder: (context, caller, _) => _buildNavItem(
                      icon: Icons.phone_in_talk_rounded,
                      iconColor: AppColors.actionBlue,
                      iconBg: AppColors.tintSky,
                      label: 'Default caller',
                      subtitle: caller.phone.isEmpty ? caller.name : '${caller.name} • ${caller.phone}',
                      onTap: () => FakeCallCallerSheet.show(context, pickOnly: true),
                    ),
                  ),
                  _buildNavItem(
                    icon: Icons.translate_rounded,
                    iconColor: AppColors.actionGreen,
                    iconBg: AppColors.successBackground,
                    label: 'Caller voice language',
                    subtitle: _fakeCallLanguage == FakeCallVoiceLanguage.bangla
                        ? 'Bangla (default)'
                        : 'English',
                    onTap: _pickFakeCallLanguage,
                  ),
                  _buildNavItem(
                    icon: Icons.record_voice_over_rounded,
                    iconColor: AppColors.actionOrange,
                    iconBg: AppColors.tintOrange,
                    label: 'Record my own caller voice',
                    subtitle: 'One clip per caller; overrides the built-in voice',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FakeCallVoiceScreen()),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Section: Security PIN & Camouflage ──────────────────
              _buildSection(
                title: 'Security PIN and camouflage',
                items: [
                  _buildToggleItem(
                    icon: Icons.shield_outlined,
                    iconColor: AppColors.primary,
                    iconBg: AppColors.primarySurface,
                    label: 'PIN protection',
                    subtitle: 'Ask for the PIN to mark safe or stop a Safe Journey',
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
                    iconBg: AppColors.successBackground,
                    label: 'Security PIN',
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
                            content: SnackContent('PIN saved.', tone: UiTone.success),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.warning_amber_rounded,
                    iconColor: AppColors.sosRed,
                    iconBg: AppColors.tintRed,
                    label: 'Duress PIN',
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
                            content: SnackContent('Duress PIN saved.', tone: UiTone.success),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.lock_outline_rounded,
                    iconColor: AppColors.actionPurple,
                    iconBg: AppColors.tintViolet,
                    label: 'Require PIN to open app',
                    subtitle: 'Ask for the PIN when the app opens',
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
                    iconBg: AppColors.neutralTile,
                    label: 'Preview camouflage calculator',
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
                    label: 'Push notifications',
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
                    iconBg: AppColors.tintRed,
                    label: 'SOS history',
                    subtitle: 'Past alerts and who responded',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SosHistoryScreen()),
                      );
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.directions_car_rounded,
                    iconColor: AppColors.actionBlue,
                    iconBg: AppColors.tintBlue,
                    label: 'Ride history',
                    subtitle: 'Past rides, plates and routes',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const RideHistoryScreen()),
                      );
                    },
                  ),
                  _buildNavItem(
                    icon: Icons.verified_user_rounded,
                    iconColor: AppColors.actionGreen,
                    iconBg: AppColors.successBackground,
                    label: 'Background alerts',
                    subtitle: 'Keep timers and guardian alerts working when the app is closed',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const BackgroundReliabilityScreen()),
                      );
                    },
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
                    iconBg: AppColors.tintSky,
                    label: 'Privacy and data',
                    subtitle: 'How your data is used',
                    onTap: _showPrivacyModal,
                  ),
                  _buildNavItem(
                    icon: Icons.info_outline_rounded,
                    iconColor: AppColors.textSecondary,
                    iconBg: AppColors.neutralTile,
                    label: 'About',
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
              style: AppText.pageTitle.copyWith(color: AppColors.textPrimary)),
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
                : (isAuth ? 'Signed in with Google' : 'Guest · Tap to sign in'));

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
                borderRadius: BorderRadius.circular(AppRadius.xl),
                boxShadow: [
                  AppShadow.tinted(AppColors.primary)
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
                            style: AppText.pageTitle.copyWith(color: Colors.white))
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(displayName,
                            style: AppText.sectionTitle.copyWith(color: Colors.white)),
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
                          borderRadius: BorderRadius.circular(AppRadius.xl)),
                      child: Text('Edit',
                          style: AppText.label.copyWith(color: Colors.white)),
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
              borderRadius: BorderRadius.circular(AppRadius.xl),
              boxShadow: const [
                AppShadow.card
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
                  color: iconBg, borderRadius: BorderRadius.circular(AppRadius.md)),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: AppText.cardTitle.copyWith(color: AppColors.textPrimary)),
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
                color: iconBg, borderRadius: BorderRadius.circular(AppRadius.md)),
            alignment: Alignment.center,
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppText.cardTitle.copyWith(color: AppColors.textPrimary)),
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
            inactiveTrackColor: AppColors.neutralTile,
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
                borderRadius: BorderRadius.circular(AppRadius.lg),
                boxShadow: const [
                  AppShadow.card
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: isAuthenticated
                            ? AppColors.tintRedStrong
                            : AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(AppRadius.md)),
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
                      style: AppText.cardTitle.copyWith(color: isAuthenticated
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
          content: SnackContent('Signed in with Google.', tone: UiTone.success),
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
    Esp32ScanSheet.show(context);
  }

  void _showAlertHistoryModal() {
    // Shows the cached list at once, then the account's history from Firestore.
    ActivityService.instance.refreshFromCloud();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ValueListenableBuilder<List<ActivityItem>>(
        valueListenable: ActivityService.instance.activitiesNotifier,
        builder: (context, activities, _) {
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
                      borderRadius: BorderRadius.circular(AppRadius.handle),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.tintViolet,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: const Icon(Icons.history_rounded,
                          color: AppColors.actionPurple, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Text('Safety & Alert History',
                        style: AppText.greeting.copyWith(color: AppColors.textPrimary)),
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
                                      borderRadius: BorderRadius.circular(AppRadius.md),
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
                                      style: AppText.caption.copyWith(color: AppColors.textSecondary)),
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


  void _showPrivacyModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Row(
          children: [
            const Icon(Icons.lock_rounded, color: AppColors.actionBlue),
            const SizedBox(width: 8),
            Expanded(child: Text('Privacy and data',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPrivacyBullet(
              title: 'Your location',
              desc: 'Shared with your guardians during an SOS, Safe Journey, ride check-in or Followed Mode. The home screen also shows where you are.',
            ),
            const SizedBox(height: 10),
            _buildPrivacyBullet(
              title: 'Your account',
              desc: 'Your profile, contacts and alerts are stored in your account on Firebase.',
            ),
            const SizedBox(height: 10),
            _buildPrivacyBullet(
              title: 'Text messages',
              desc: 'Emergency SMS is sent from your own SIM card.',
            ),
            const SizedBox(height: 10),
            _buildPrivacyBullet(
              title: 'Guardians',
              desc: 'A guardian must accept your request before they get your alerts. Alerts go only from you to the guardians you added.',
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Row(
          children: [
            const Icon(Icons.shield_rounded, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('Woman Guard',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700))),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
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
                  borderRadius: BorderRadius.circular(AppRadius.md)),
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
