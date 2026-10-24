import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';
import '../models/activity_model.dart';
import 'activity_service.dart';
import 'auth_service.dart';
import 'contact_service.dart';
import 'emergency_service.dart';
import 'live_tracking_service.dart';

/// Singleton service monitoring device battery level to dispatch an automated
/// single-shot SMS alert to trusted contacts when battery drops to critical levels (<= 10%).
///
/// **Hysteresis Protection:**
/// Prevents repetitive SMS alert spam by requiring the battery to be recharged
/// above 20% before a new critical battery alert can ever be triggered again.
class BatteryAlertService {
  BatteryAlertService._internal();

  /// Central singleton instance
  static final BatteryAlertService instance = BatteryAlertService._internal();

  final Battery _battery = Battery();
  final Telephony _telephony = Telephony.instance;

  static const String prefKeyCriticalBatteryAlert = 'pref_critical_battery_alert';
  static const String prefKeyAlertHasDispatched = 'battery_alert_has_dispatched';

  Timer? _periodicTimer;
  StreamSubscription<BatteryState>? _batteryStateSub;
  bool _isInitialized = false;

  /// Pure, testable helper evaluating whether a critical battery alert should trigger.
  static bool shouldTriggerAlert({
    required int batteryLevel,
    required bool isCharging,
    required bool hasDispatched,
    required bool isEnabled,
  }) {
    if (!isEnabled) return false;
    if (isCharging) return false;
    if (hasDispatched) return false;
    return batteryLevel <= 10;
  }

  /// Pure, testable helper evaluating whether hysteresis should reset after recharge.
  static bool shouldResetHysteresis({required int batteryLevel}) {
    return batteryLevel > 20;
  }

  /// Formats the single-segment emergency battery SMS message
  static String formatBatterySmsMessage({
    required String userName,
    required int batteryLevel,
    required String? mapUrl,
  }) {
    final cleanName = userName.trim().isNotEmpty ? userName.trim() : 'Emergency Contact';
    if (mapUrl != null && mapUrl.trim().isNotEmpty) {
      return "$cleanName's phone battery is critical ($batteryLevel%). Last known GPS: $mapUrl";
    }
    return "$cleanName's phone battery is critical ($batteryLevel%). GPS unavailable.";
  }

  /// Initializes battery monitoring listeners and periodic checks.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Listen to device charging state changes
    try {
      _batteryStateSub = _battery.onBatteryStateChanged.listen((state) {
        checkBatteryLevel();
      });
    } catch (e) {
      debugPrint('[BatteryAlertService] Error listening to battery state: $e');
    }

    // Periodic check every 90 seconds while app runs
    _periodicTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      checkBatteryLevel();
    });

    // Run initial check
    checkBatteryLevel();
  }

  /// Checks current battery level against hysteresis thresholds and sends SMS if triggered.
  Future<void> checkBatteryLevel() async {
    // Only monitor for authenticated users
    if (!AuthService.instance.isAuthenticated) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool(prefKeyCriticalBatteryAlert) ?? true;
      final hasDispatched = prefs.getBool(prefKeyAlertHasDispatched) ?? false;

      final int level = await _battery.batteryLevel;
      final BatteryState state = await _battery.batteryState;
      final bool isCharging = state == BatteryState.charging || state == BatteryState.full;

      // Check hysteresis reset (charged > 20%)
      if (shouldResetHysteresis(batteryLevel: level) && hasDispatched) {
        await prefs.setBool(prefKeyAlertHasDispatched, false);
        debugPrint('[BatteryAlertService] 🔋 Battery recharged to $level%. Hysteresis flag reset.');
      }

      // Check critical threshold (<= 10% and not charging)
      if (shouldTriggerAlert(
        batteryLevel: level,
        isCharging: isCharging,
        hasDispatched: hasDispatched,
        isEnabled: isEnabled,
      )) {
        await _dispatchCriticalBatteryAlert(level);
        await prefs.setBool(prefKeyAlertHasDispatched, true);
      }
    } catch (e) {
      debugPrint('[BatteryAlertService] Error checking battery: $e');
    }
  }

  /// Dispatches the critical battery alert SMS and updates active cloud session documents.
  Future<void> _dispatchCriticalBatteryAlert(int batteryLevel) async {
    debugPrint('[BatteryAlertService] ⚠️ Battery critical at $batteryLevel%! Dispatching alert...');

    // 1. Fetch live or last known location
    String? mapUrl;
    try {
      Position? position = await Geolocator.getLastKnownPosition();
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 3),
        ),
      ).timeout(const Duration(seconds: 3));
      mapUrl = EmergencyService.instance.generateGoogleMapsUrl(position.latitude, position.longitude);
    } catch (_) {}

    // 2. Format single-segment SMS
    final userName = AuthService.instance.displayName;
    final message = formatBatterySmsMessage(
      userName: userName,
      batteryLevel: batteryLevel,
      mapUrl: mapUrl,
    );

    // 3. Dispatch SMS to all emergency contacts with a phone number
    final phoneNumbers = await ContactService.instance.getEmergencyPhoneNumbers();
    int sentCount = 0;
    if (phoneNumbers.isNotEmpty) {
      for (final phone in phoneNumbers) {
        try {
          await _telephony.sendSms(
            to: phone,
            message: message,
            isMultipart: true,
          );
          sentCount++;
          debugPrint('[BatteryAlertService] ✅ Critical battery SMS sent to $phone');
        } catch (smsErr) {
          debugPrint('[BatteryAlertService] ❌ Failed to send battery SMS to $phone: $smsErr');
        }
      }
    }

    // 4. Update active SOS or Journey session document in Firestore if active
    final activeDocId = LiveTrackingService.instance.activeDocumentId;
    final activeType = LiveTrackingService.instance.activeSessionType;
    if (activeDocId != null && activeType != null) {
      try {
        final collectionName = activeType == 'sos' ? 'sos_alerts' : 'journeys';
        await FirebaseFirestore.instance.collection(collectionName).doc(activeDocId).update({
          'batteryLevel': batteryLevel,
          'batteryStatus': 'critical',
          'lastUpdatedAt': FieldValue.serverTimestamp(),
        }).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    // 5. Log activity
    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.location,
        title: 'Critical Battery Alert',
        subtitle: 'Battery reached $batteryLevel%. Dispatched SMS to $sentCount contact(s).',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Sets whether critical battery alerts are enabled.
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyCriticalBatteryAlert, enabled);
  }

  /// Checks if critical battery alert is enabled.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKeyCriticalBatteryAlert) ?? true;
  }

  /// Disposes timers and listeners.
  void dispose() {
    _periodicTimer?.cancel();
    _batteryStateSub?.cancel();
    _isInitialized = false;
  }
}
