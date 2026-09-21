import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'activity_service.dart';
import 'contact_service.dart';
import 'sos_cloud_dispatcher.dart';

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

class _SmsDispatchResult {
  final int sentCount;
  final List<String> failedList;
  final bool hasRecipients;
  final bool permissionGranted;

  const _SmsDispatchResult({
    required this.sentCount,
    required this.failedList,
    required this.hasRecipients,
    required this.permissionGranted,
  });
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

    // Step 3 & 4: CONCURRENT DUAL DISPATCH
    // Action A (Cloud SOS) and Action B (Offline SMS) execute in parallel
    // so offline SMS is NEVER delayed or blocked by internet latency!
    final cloudFuture = SosCloudDispatcher.instance.triggerCloudSos(
      position: position,
      source: source,
      customNote: customMessage,
    ).timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        debugPrint('[EmergencyService] ⏱️ Cloud SOS dispatch timed out after 4s (continuing in background)');
        return null;
      },
    ).catchError((err) {
      debugPrint('[EmergencyService] Cloud SOS dispatch error: $err');
      return null;
    });

    final smsFuture = _dispatchOfflineSms(
      recipients: recipients,
      mapUrl: mapUrl,
      customMessage: customMessage,
    ).catchError((err) {
      debugPrint('[EmergencyService] SMS dispatch future error: $err');
      final bool isPermissionDenied = err.toString().contains('permission_denied') ||
          err.toString().contains('SEND_SMS');
      return _SmsDispatchResult(
        sentCount: 0,
        failedList: recipients,
        hasRecipients: recipients.isNotEmpty,
        permissionGranted: !isPermissionDenied,
      );
    });

    final List<dynamic> dualResults = await Future.wait([cloudFuture, smsFuture]);
    final String? cloudAlertId = dualResults[0] as String?;
    final _SmsDispatchResult smsResult = dualResults[1] as _SmsDispatchResult;

    final int sentCount = smsResult.sentCount;
    final List<String> failedList = smsResult.failedList;
    final bool cloudSent = cloudAlertId != null;
    final bool overallSuccess = sentCount > 0 || cloudSent;

    String resultSummary;
    if (sentCount > 0 && cloudSent) {
      resultSummary = 'SOS alert dispatched! SMS sent to $sentCount contact(s) & Cloud alert broadcast.';
    } else if (sentCount > 0) {
      resultSummary = 'Emergency SMS successfully sent to $sentCount contact(s).';
    } else if (cloudSent) {
      if (!smsResult.permissionGranted) {
        resultSummary = '🚨 In-App alert sent to guardians! (SMS skipped: allow SMS in phone Settings).';
      } else {
        resultSummary = '🚨 Emergency cloud alert broadcast to all mutual guardians.';
      }
    } else if (!smsResult.permissionGranted) {
      resultSummary = 'SMS permission was denied. Please allow SMS permission in device settings.';
    } else if (!smsResult.hasRecipients) {
      resultSummary = 'No emergency contacts configured. Please add emergency contacts first.';
    } else {
      resultSummary = 'Failed to dispatch emergency alerts.';
    }

    // Log the SOS emergency event for profile activity tracking
    ActivityService.instance.logSOS(
      source: source,
      contactsSent: sentCount > 0 ? sentCount : (cloudSent ? 1 : 0),
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

  /// Dispatches offline background SMS messages to valid recipient phone numbers.
  Future<_SmsDispatchResult> _dispatchOfflineSms({
    required List<String> recipients,
    required String? mapUrl,
    required String? customMessage,
  }) async {
    final List<String> validRecipients = recipients
        .map((r) => r.replaceAll(RegExp(r'\s+'), ''))
        .where((r) => r.isNotEmpty)
        .toList();

    if (validRecipients.isEmpty) {
      return const _SmsDispatchResult(
        sentCount: 0,
        failedList: [],
        hasRecipients: false,
        permissionGranted: true,
      );
    }

    try {
      final String smsBody = (customMessage != null && customMessage.trim().isNotEmpty)
          ? customMessage.trim()
          : buildEmergencyMessage(mapUrl);

      debugPrint('[EmergencyService] ✉️ Prepared Message: "$smsBody" (${smsBody.length} chars)');

      final bool hasSmsPermission = await _checkAndRequestSmsPermission();
      if (!hasSmsPermission) {
        debugPrint('[EmergencyService] ⚠️ SMS Permission denied.');
        return _SmsDispatchResult(
          sentCount: 0,
          failedList: validRecipients,
          hasRecipients: true,
          permissionGranted: false,
        );
      }

      int sentCount = 0;
      final List<String> failedList = [];

      for (final contact in validRecipients) {
        try {
          await _telephony.sendSms(
            to: contact,
            message: smsBody,
            isMultipart: true,
          );
          sentCount++;
          debugPrint('[EmergencyService] ✅ SMS successfully sent to: $contact');
        } catch (smsErr) {
          debugPrint('[EmergencyService] ❌ Failed to send SMS to $contact: $smsErr');
          failedList.add(contact);
        }
      }

      return _SmsDispatchResult(
        sentCount: sentCount,
        failedList: failedList,
        hasRecipients: true,
        permissionGranted: true,
      );
    } catch (e) {
      debugPrint('[EmergencyService] Offline SMS dispatch error: $e');
      final bool isPermissionDenied = e.toString().contains('permission_denied') ||
          e.toString().contains('SEND_SMS');
      return _SmsDispatchResult(
        sentCount: 0,
        failedList: validRecipients,
        hasRecipients: true,
        permissionGranted: !isPermissionDenied,
      );
    }
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

    try {
      // First check telephony permission request
      bool? isSmsGranted = await _telephony.requestSmsPermissions;
      if (isSmsGranted == true) return true;
    } catch (e) {
      debugPrint('[EmergencyService] Telephony permission request notice: $e');
    }

    try {
      // Fallback to permission_handler
      var status = await Permission.sms.status;
      if (!status.isGranted) {
        status = await Permission.sms.request();
      }
      return status.isGranted;
    } catch (e) {
      debugPrint('[EmergencyService] Permission_handler request notice: $e');
      return false;
    }
  }
}
