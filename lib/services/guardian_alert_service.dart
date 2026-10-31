import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';
import 'background_service.dart';
import 'pin_security_service.dart';

/// Controls the native guardian alert listener (Android GuardianAlertService), which receives SOS
/// alerts while the app is in the background, swiped away or the screen is locked, and plays the
/// siren on the alarm stream. Runs only while a user is signed in (guests never receive alerts).
class GuardianAlertService {
  GuardianAlertService._internal();
  static final GuardianAlertService instance = GuardianAlertService._internal();

  static const MethodChannel _channel = MethodChannel('com.smartsafety.smart_safety/guardian');
  static const MethodChannel _deviceChannel = MethodChannel('com.smartsafety.smart_safety/device');
  static const String _prefReliabilitySetupShown = 'pref_guardian_reliability_setup_shown';

  StreamSubscription<User?>? _authSubscription;
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _setupScheduled = false;

  bool get _isSupported => !kIsWeb && Platform.isAndroid;

  /// Starts/stops the native listener together with the Firebase session.
  void initialize(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    if (!_isSupported || Firebase.apps.isEmpty || _authSubscription != null) return;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        _invoke('start');
        _scheduleReliabilitySetup();
      } else {
        _invoke('stop');
      }
    });
  }

  Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!_isSupported) return null;
    try {
      final result = await _channel.invokeMethod(method, args);
      debugPrint('[GuardianAlert] $method -> $result');
      return result;
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[GuardianAlert] $method failed: $e');
      return null;
    }
  }

  /// Claims an alert for this device. Returns true only for the first caller, so the native
  /// service and the in-app listener never both ring for the same alert.
  /// Without the native layer (tests, iOS) every alert is considered unclaimed.
  Future<bool> claimAlert(String alertId) async {
    if (!_isSupported || alertId.isEmpty) return true;
    try {
      return await _channel.invokeMethod<bool>('claimAlert', {'alertId': alertId}) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Whether the native listener is running (it then owns alerting while the app is not visible).
  Future<bool> isServiceRunning() async => (await _invoke('isRunning')) == true;

  /// Silences a siren started by the native service.
  Future<void> stopNativeSiren() async {
    await _invoke('stopSiren');
  }

  void _scheduleReliabilitySetup() {
    if (_setupScheduled) return;
    _setupScheduled = true;
    // Let the startup permission prompts and the app-lock PIN dialog appear first.
    Future.delayed(const Duration(seconds: 8), _showReliabilitySetupOnce);
  }

  /// One-time guidance so background alerts keep working: battery optimization exemption,
  /// Samsung "Sleeping apps" removal, and the Android 14+ full-screen alert permission.
  Future<void> _showReliabilitySetupOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefReliabilitySetupShown) ?? false) return;
      if (PinSecurityService.instance.isCamouflageActiveNotifier.value) return;
      if (_navigatorKey?.currentContext == null || FirebaseAuth.instance.currentUser == null) return;
      await prefs.setBool(_prefReliabilitySetupShown, true);

      final context = _navigatorKey?.currentContext;
      if (context == null || !context.mounted) return;
      await BackgroundServiceManager.instance.promptBatteryOptimizationOnce(context);

      final manufacturer =
          (await _deviceChannel.invokeMethod<String>('getManufacturer') ?? '').toLowerCase();
      if (manufacturer == 'samsung' && context.mounted) {
        await _showSamsungSleepingAppsGuide(context);
      }

      final canUseFullScreen = await _invoke('canUseFullScreenIntent') != false;
      if (!canUseFullScreen && context.mounted) {
        await _showFullScreenIntentPrompt(context);
      }
    } catch (e) {
      debugPrint('[GuardianAlert] Reliability setup error: $e');
    }
  }

  Future<void> _showSamsungSleepingAppsGuide(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Keep emergency alerts on',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: Text(
          'Samsung phones can put apps to sleep, which stops emergency alerts from your contacts.\n\n'
          '1. Open Settings › Battery › Background usage limits.\n'
          '2. Open "Sleeping apps" and "Deep sleeping apps" and remove Woman Guard.\n'
          '3. Optionally add Woman Guard to "Never sleeping apps".',
          style: GoogleFonts.poppins(fontSize: 13, height: 1.5, color: AppColors.textPrimary),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Got it', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<void> _showFullScreenIntentPrompt(BuildContext context) async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Show alerts on the lock screen',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: Text(
          'Allow full-screen notifications so an SOS alert from your contacts opens over the lock screen.',
          style: GoogleFonts.poppins(fontSize: 13, height: 1.5, color: AppColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Later', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Allow', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (proceed == true) {
      await _invoke('openFullScreenIntentSettings');
    }
  }
}
