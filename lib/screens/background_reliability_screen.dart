import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/app_colors.dart';
import '../services/safety_deadline_service.dart';

/// Phone settings that safety timers and guardian alerts need to work while Woman Guard is
/// closed: notifications, exact alarms, battery-optimisation exemption, full-screen alerts and the
/// manufacturer's auto-start setting.
class BackgroundReliabilityScreen extends StatefulWidget {
  const BackgroundReliabilityScreen({super.key});

  @override
  State<BackgroundReliabilityScreen> createState() => _BackgroundReliabilityScreenState();
}

class _BackgroundReliabilityScreenState extends State<BackgroundReliabilityScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _guardianChannel = MethodChannel('com.smartsafety.smart_safety/guardian');
  static const MethodChannel _deviceChannel = MethodChannel('com.smartsafety.smart_safety/device');

  bool _loading = true;
  bool _notifications = false;
  bool _exactAlarms = false;
  bool _battery = false;
  bool _fullScreen = false;
  String _manufacturer = '';

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a system settings page
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    bool notifications = false, exact = true, battery = false, fullScreen = true;
    String manufacturer = '';
    try {
      notifications = await Permission.notification.isGranted;
      if (_isAndroid) {
        exact = await SafetyDeadlineService.instance.canScheduleExactAlarms();
        battery = await Permission.ignoreBatteryOptimizations.isGranted;
        fullScreen = await _guardianChannel.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
        manufacturer = (await _deviceChannel.invokeMethod<String>('getManufacturer') ?? '').toLowerCase();
      } else {
        battery = true;
      }
    } catch (e) {
      debugPrint('[Reliability] Status check notice: $e');
    }
    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _exactAlarms = exact;
      _battery = battery;
      _fullScreen = fullScreen;
      _manufacturer = manufacturer;
      _loading = false;
    });
  }

  Future<void> _fixNotifications() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) await openAppSettings();
    await _refresh();
  }

  Future<void> _fixExactAlarms() async {
    final opened = await SafetyDeadlineService.instance.openExactAlarmSettings();
    if (!opened) await openAppSettings();
  }

  Future<void> _fixBattery() async {
    await Permission.ignoreBatteryOptimizations.request();
    await _refresh();
  }

  Future<void> _fixFullScreen() async {
    try {
      await _guardianChannel.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {}
  }

  Future<void> _openAutoStart() async {
    try {
      final opened = await _deviceChannel.invokeMethod<bool>('openAutoStartSettings') ?? false;
      if (!opened) await openAppSettings();
    } catch (_) {
      await openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allGood = _notifications && _exactAlarms && _battery && _fullScreen;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Background Alerts Setup',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 17)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _InfoCard(allGood: allGood),
                const SizedBox(height: 16),
                _StatusTile(
                  icon: Icons.notifications_active_rounded,
                  title: 'Notifications',
                  description: 'Needed to show safety checks and incoming SOS alerts.',
                  ok: _notifications,
                  onFix: _fixNotifications,
                ),
                if (_isAndroid) ...[
                  _StatusTile(
                    icon: Icons.alarm_on_rounded,
                    title: 'Alarms & reminders',
                    description:
                        'Lets your Safe Journey, Followed Mode and ride timers fire on time even when the app is closed.',
                    ok: _exactAlarms,
                    onFix: _fixExactAlarms,
                  ),
                  _StatusTile(
                    icon: Icons.battery_charging_full_rounded,
                    title: 'Battery optimisation off',
                    description:
                        'Stops Android from pausing Woman Guard, so an expired timer can send your SOS and you receive alerts from people you protect.',
                    ok: _battery,
                    onFix: _fixBattery,
                  ),
                  _StatusTile(
                    icon: Icons.fullscreen_rounded,
                    title: 'Full-screen alerts',
                    description: 'Shows an SOS alert over the lock screen, like an incoming call.',
                    ok: _fullScreen,
                    onFix: _fixFullScreen,
                  ),
                  const SizedBox(height: 8),
                  _AutoStartGuide(manufacturer: _manufacturer, onOpen: _openAutoStart),
                ],
              ],
            ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final bool allGood;
  const _InfoCard({required this.allGood});

  @override
  Widget build(BuildContext context) {
    final color = allGood ? AppColors.actionGreen : AppColors.actionOrange;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(allGood ? Icons.verified_user_rounded : Icons.info_rounded, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              allGood
                  ? 'All set. Safety timers and guardian alerts can work while Woman Guard is closed or your phone is locked.'
                  : 'Some phone settings can stop Woman Guard from working while it is closed. If a safety timer runs out, '
                      'the app must still be able to send your SOS, and guardians must still receive alerts. Fix the items below.',
              style: GoogleFonts.poppins(fontSize: 12.5, height: 1.45, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool ok;
  final VoidCallback onFix;

  const _StatusTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.ok,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(icon, color: ok ? AppColors.actionGreen : AppColors.sosRed),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(description,
                    style: GoogleFonts.poppins(fontSize: 11.5, height: 1.4, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ok
              ? const Icon(Icons.check_circle_rounded, color: AppColors.actionGreen)
              : TextButton(
                  onPressed: onFix,
                  child: Text('Fix', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: AppColors.primary)),
                ),
        ],
      ),
    );
  }
}

class _AutoStartGuide extends StatelessWidget {
  final String manufacturer;
  final VoidCallback onOpen;
  const _AutoStartGuide({required this.manufacturer, required this.onOpen});

  static const Map<String, List<String>> _guides = {
    'Xiaomi / Redmi / POCO': [
      'Settings > Apps > Manage apps > Woman Guard > turn ON "Autostart".',
      'In the same screen: Battery saver > "No restrictions".',
      'Open Recent apps, long-press Woman Guard and tap the lock icon.',
    ],
    'Oppo / Realme / OnePlus': [
      'Settings > Apps > App management > Woman Guard.',
      'Battery usage: turn ON "Allow auto launch" and "Allow background activity".',
      'Open Recent apps and lock Woman Guard.',
    ],
    'Vivo / iQOO': [
      'Settings > Battery > Background power consumption management > Woman Guard > "Allow".',
      'i Manager > App manager > Autostart manager > turn ON Woman Guard.',
      'Open Recent apps and lock Woman Guard.',
    ],
    'Samsung': [
      'Settings > Battery (Device care) > Background usage limits.',
      'Make sure Woman Guard is NOT in "Sleeping apps" or "Deep sleeping apps"; add it to "Never sleeping apps".',
      'Settings > Apps > Woman Guard > Battery > "Unrestricted".',
    ],
    'Huawei / Honor': [
      'Settings > Battery > App launch > Woman Guard > "Manage manually".',
      'Turn ON Auto-launch, Secondary launch and Run in background.',
    ],
    'Other phones': [
      'Settings > Apps > Woman Guard > Battery > "Unrestricted" (or "Not optimised").',
    ],
  };

  String get _detectedBrand {
    final m = manufacturer;
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) return 'Xiaomi / Redmi / POCO';
    if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) return 'Oppo / Realme / OnePlus';
    if (m.contains('vivo') || m.contains('iqoo')) return 'Vivo / iQOO';
    if (m.contains('samsung')) return 'Samsung';
    if (m.contains('huawei') || m.contains('honor')) return 'Huawei / Honor';
    return 'Other phones';
  }

  @override
  Widget build(BuildContext context) {
    final detected = _detectedBrand;
    final ordered = [detected, ..._guides.keys.where((k) => k != detected)];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.rocket_launch_rounded, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Auto-start (phone brand settings)',
                    style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Many phones stop apps that are closed from Recent apps. Allow Woman Guard to start and run in the background:',
            style: GoogleFonts.poppins(fontSize: 11.5, height: 1.4, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          for (final brand in ordered)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: brand == detected,
                title: Text(
                  brand == detected && brand != 'Other phones' ? '$brand (your phone)' : brand,
                  style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                children: [
                  for (final (i, step) in _guides[brand]!.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${i + 1}. ', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
                          Expanded(child: Text(step, style: GoogleFonts.poppins(fontSize: 12, height: 1.4))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text('Open auto-start settings', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
