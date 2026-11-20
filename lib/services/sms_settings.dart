import 'package:shared_preferences/shared_preferences.dart';

/// The global "SMS alerts" switch in Settings. When off, the app sends no text messages at all
/// (SOS, escalation, journey, ride); alerts reach guardians through the app only.
class SmsSettings {
  SmsSettings._();

  static const String prefKey = 'pref_sms_alerts';

  /// On by default. Reloads first, so the background engine (safety deadlines) sees a change
  /// made in Settings.
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(prefKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, enabled);
  }
}
