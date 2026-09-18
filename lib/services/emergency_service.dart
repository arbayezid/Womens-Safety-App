import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'activity_service.dart';
import 'contact_service.dart';

/// Data result object returned by [EmergencyService.triggerEmergency].
class EmergencyResult {
  final bool isSuccess;
  final String message;
  final Position? position;
  final String? googleMapsUrl;
  final int contactsSentCount;
  final List<String> failedContacts;
  final DateTime timestamp;

  EmergencyResult({
    required this.isSuccess,
    required this.message,
    this.position,
    this.googleMapsUrl,
    this.contactsSentCount = 0,
    this.failedContacts = const [],
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return 'EmergencyResult(isSuccess: $isSuccess, message: $message, mapsUrl: $googleMapsUrl, sentCount: $contactsSentCount)';
  }
}

/// Central Singleton Service for handling One-Tap SOS Emergency triggers.
///
/// Handles location extraction, Google Maps URL formatting, dynamic contact retrieval
/// from [ContactService], background SMS dispatch, and edge-case notifications.
class EmergencyService {
  EmergencyService._internal();

  /// Central singleton instance
  static final EmergencyService instance = EmergencyService._internal();

  final Telephony _telephony = Telephony.instance;

  /// Optional in-memory override for emergency contacts
  List<String> _emergencyContacts = [];

  /// Get active in-memory emergency contacts
  List<String> get emergencyContacts => List.unmodifiable(_emergencyContacts);

  /// Update in-memory emergency contacts list
  void updateContacts(List<String> newContacts) {
    _emergencyContacts = newContacts.where((c) => c.trim().isNotEmpty).toList();
    debugPrint('[EmergencyService] Updated contacts: $_emergencyContacts');
  }

  /// Triggers full SOS emergency pipeline:
  /// 1. Dynamically fetches contacts from [ContactService]
  /// 2. Verifies & requests GPS & SMS permissions
  /// 3. Fetches high-accuracy live GPS location
  /// 4. Builds clickable Google Maps search URL
  /// 5. Dispatches direct background SMS to all emergency contacts
  ///
  /// [source] indicates where the trigger originated (e.g. "SOS Button", "ESP32 Hardware", "Shake", "Voice").
  /// If [context] is provided, UI warning SnackBars will be displayed for edge-cases.
  Future<EmergencyResult> triggerEmergency({
    required String source,
    BuildContext? context,
    String? customMessage,
  }) async {
    debugPrint('[EmergencyService] 🚨 Triggering Emergency SOS via source: $source');

    // Step 1: Dynamically fetch active recipients from ContactService or in-memory override
    List<String> recipients = _emergencyContacts.where((c) => c.trim().isNotEmpty).toList();
    if (recipients.isEmpty) {
      recipients = await ContactService.instance.getEmergencyPhoneNumbers();
    }

    // Step 2: Extract real-time GPS Location
    Position? position;
    String? mapUrl;

    try {
      position = await _getCurrentLocation();
      mapUrl = generateGoogleMapsUrl(position.latitude, position.longitude);
      debugPrint('[EmergencyService] 📍 Acquired Location: ${position.latitude}, ${position.longitude}');
      debugPrint('[EmergencyService] 🗺️ Maps URL: $mapUrl');
    } catch (e) {
      debugPrint('[EmergencyService] ⚠️ Location Extraction Warning: $e');
      // If live location fails, attempt fallback to last known position
      try {
        position = await Geolocator.getLastKnownPosition();
        if (position != null) {
          mapUrl = generateGoogleMapsUrl(position.latitude, position.longitude);
          debugPrint('[EmergencyService] 📍 Fallback to Last Known Location: ${position.latitude}, ${position.longitude}');
        }
      } catch (lastErr) {
        debugPrint('[EmergencyService] ❌ Fallback Location also failed: $lastErr');
      }
    }

    // Edge Case: Contact list is empty
    if (recipients.isEmpty) {
      const String emptyMsg = 'No emergency contacts configured. Please add emergency contacts first.';
      debugPrint('[EmergencyService] ⚠️ $emptyMsg');

      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    emptyMsg,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      }

      return EmergencyResult(
        isSuccess: false,
        message: emptyMsg,
        position: position,
        googleMapsUrl: mapUrl,
      );
    }

    // Build cost-effective emergency SMS text (single-segment GSM-7, under 160 characters)
    final String smsBody = (customMessage != null && customMessage.trim().isNotEmpty)
        ? customMessage.trim()
        : buildEmergencyMessage(mapUrl);

    debugPrint('[EmergencyService] ✉️ Prepared Message: "$smsBody" (${smsBody.length} chars)');

    // Step 3: Ensure SMS permissions
    final bool hasSmsPermission = await _checkAndRequestSmsPermission();
    if (!hasSmsPermission) {
      const String permMsg = 'SMS Permission denied. Unable to auto-send emergency alert messages.';
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(permMsg, style: TextStyle(fontWeight: FontWeight.w600)),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      }

      return EmergencyResult(
        isSuccess: false,
        message: permMsg,
        position: position,
        googleMapsUrl: mapUrl,
      );
    }

    // Step 4: Dispatch SMS to dynamic emergency contacts
    int sentCount = 0;
    List<String> failedList = [];

    for (final contact in recipients) {
      final cleanNumber = contact.replaceAll(RegExp(r'\s+'), '');
      if (cleanNumber.isEmpty) continue;

      try {
        // Send direct background SMS without opening native SMS dialog
        await _telephony.sendSms(
          to: cleanNumber,
          message: smsBody,
          isMultipart: true,
        );
        sentCount++;
        debugPrint('[EmergencyService] ✅ SMS successfully sent to: $cleanNumber');
      } catch (smsError) {
        debugPrint('[EmergencyService] ❌ Failed sending SMS to $cleanNumber: $smsError');
        failedList.add(cleanNumber);
      }
    }

    final bool overallSuccess = sentCount > 0;
    final String resultSummary = overallSuccess
        ? 'Emergency alert dispatched to $sentCount contact(s).'
        : 'Failed to dispatch SMS to contacts.';

    // Log the SOS emergency event for profile activity tracking
    ActivityService.instance.logSOS(
      source: source,
      contactsSent: sentCount,
      mapUrl: mapUrl,
      isSuccess: overallSuccess,
    );

    return EmergencyResult(
      isSuccess: overallSuccess,
      message: resultSummary,
      position: position,
      googleMapsUrl: mapUrl,
      contactsSentCount: sentCount,
      failedContacts: failedList,
    );
  }

  /// Convenience alias for [triggerEmergency]
  Future<EmergencyResult> triggerEmergencySOS({
    required String source,
    BuildContext? context,
    String? customMessage,
  }) =>
      triggerEmergency(
        source: source,
        context: context,
        customMessage: customMessage,
      );

  /// Dispatches SMS directly with optional custom text message to active contacts
  Future<EmergencyResult> sendEmergencySMS({
    String? customMessage,
    BuildContext? context,
    String source = 'Direct SOS SMS',
  }) async {
    return triggerEmergency(
      source: source,
      context: context,
      customMessage: customMessage,
    );
  }

  /// Formats an ultra-concise, single-segment GSM-7 emergency SMS message.
  ///
  /// Standard SMS is limited to 160 characters in 7-bit GSM encoding.
  /// Emojis and verbose text force UCS-2 16-bit encoding (70-char limit),
  /// multiplying carrier SMS costs 2-3x per recipient.
  ///
  /// Output format:
  /// `SOS! I need help. My GPS: https://www.google.com/maps/search/?api=1&query=23.7614038,90.4453419`
  String buildEmergencyMessage(String? mapUrl) {
    if (mapUrl != null && mapUrl.trim().isNotEmpty) {
      return 'SOS! I need help. My GPS: $mapUrl';
    }
    return 'SOS! I need help. GPS unavailable.';
  }

  /// Converts high-accuracy coordinates into a clickable Google Maps URL format
  String generateGoogleMapsUrl(double latitude, double longitude) {
    return 'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
  }

  /// Checks & requests real-time location service status and permissions using [geolocator].
  Future<Position> _getCurrentLocation() async {
    // 1. Check if location services are enabled on device
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('GPS location services are disabled on your device. Please turn on GPS.');
    }

    // 2. Check location permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission was denied by user.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
          'Location permissions are permanently denied. Please enable them in app settings.');
    }

    // 3. Extract high accuracy location with time limit
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
  }

  /// Checks and requests SMS permission via [permission_handler] / [telephony].
  Future<bool> _checkAndRequestSmsPermission() async {
    if (kIsWeb) return false;

    // First check telephony permission request
    bool? isSmsGranted = await _telephony.requestSmsPermissions;
    if (isSmsGranted == true) return true;

    // Fallback to permission_handler
    var status = await Permission.sms.status;
    if (!status.isGranted) {
      status = await Permission.sms.request();
    }
    return status.isGranted;
  }
}
