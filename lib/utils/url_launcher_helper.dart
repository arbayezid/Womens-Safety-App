import 'package:url_launcher/url_launcher.dart';

/// Reusable utility helper for launching native device intents (Phone Dialer, SMS).
class UrlLauncherHelper {
  UrlLauncherHelper._();

  /// Cleans and sanitizes raw phone numbers by stripping whitespace, dashes,
  /// parentheses, and other non-numeric symbols, while preserving an international '+' prefix.
  static String sanitizePhoneNumber(String rawPhone) {
    final trimmed = rawPhone.trim();
    if (trimmed.isEmpty) return '';

    final hasLeadingPlus = trimmed.startsWith('+');
    final digitsOnly = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    return hasLeadingPlus ? '+$digitsOnly' : digitsOnly;
  }

  /// Launches the native Phone Dialer with [rawPhoneNumber].
  ///
  /// Uses [LaunchMode.externalApplication] so the platform dialer handles the intent.
  /// Returns `true` if launched successfully, `false` otherwise.
  static Future<bool> makePhoneCall(String rawPhoneNumber) async {
    final sanitizedPhone = sanitizePhoneNumber(rawPhoneNumber);
    if (sanitizedPhone.isEmpty) return false;

    final Uri uri = Uri(scheme: 'tel', path: sanitizedPhone);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Launches the native SMS messaging app with [rawPhoneNumber] as recipient.
  ///
  /// Optionally includes a pre-filled [body] message if supplied.
  /// Uses [LaunchMode.externalApplication] to pass control to the user's messaging client.
  /// Returns `true` if launched successfully, `false` otherwise.
  static Future<bool> openSMSApp(String rawPhoneNumber, {String? body}) async {
    final sanitizedPhone = sanitizePhoneNumber(rawPhoneNumber);
    if (sanitizedPhone.isEmpty) return false;

    final Uri uri = Uri(
      scheme: 'sms',
      path: sanitizedPhone,
      queryParameters: body != null && body.isNotEmpty ? {'body': body} : null,
    );

    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Generates the Google Maps turn-by-turn navigation URL for given coordinates.
  static String getMapNavigationUrl(double latitude, double longitude) {
    return 'https://www.google.com/maps/dir/?api=1&destination=$latitude,$longitude&travelmode=driving';
  }

  /// Launches external Google Maps turn-by-turn navigation to [latitude], [longitude].
  ///
  /// Uses [LaunchMode.externalApplication] so the device navigation app handles the route.
  /// Returns `true` if launched successfully, `false` otherwise.
  static Future<bool> openMapNavigation(double latitude, double longitude) async {
    final String urlStr = getMapNavigationUrl(latitude, longitude);
    final Uri uri = Uri.parse(urlStr);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Launches an external web or map search URL.
  static Future<bool> launchMapsUrl(String urlStr) async {
    final Uri uri = Uri.parse(urlStr);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}
