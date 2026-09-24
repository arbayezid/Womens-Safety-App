import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/contact_model.dart';
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
  final bool isPermissionDenied;
  final bool hasNoRecipients;

  EmergencyResult({
    required this.isSuccess,
    required this.message,
    this.position,
    this.googleMapsUrl,
    this.contactsSentCount = 0,
    this.failedContacts = const [],
    this.isPermissionDenied = false,
    this.hasNoRecipients = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return 'EmergencyResult(isSuccess: $isSuccess, message: $message, mapsUrl: $googleMapsUrl, sentCount: $contactsSentCount, permissionDenied: $isPermissionDenied, noRecipients: $hasNoRecipients)';
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
/// Handles location extraction with 5s timeout fallback, dynamic contact retrieval
/// from [ContactService] and Firestore recovery, E.164 / local Bangladesh phone formatting,
/// offline direct background SMS dispatch, and real-time Cloud SOS broadcasting.
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

  /// Formats phone numbers for Bangladesh and international standards.
  /// Converts Bangladesh local numbers (e.g. 01980626023) to E.164 (+8801980626023),
  /// cleans unwanted punctuation, and handles +880 prefixes.
  String formatRecipientPhone(String rawPhone) {
    if (rawPhone.trim().isEmpty) return '';
    String cleaned = rawPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('+')) {
      cleaned = '+${cleaned.substring(1).replaceAll('+', '')}';
    } else {
      cleaned = cleaned.replaceAll('+', '');
    }

    // Convert local Bangladesh 11-digit numbers (01XXXXXXXXX) to international E.164 (+8801XXXXXXXXX)
    if (cleaned.startsWith('01') && cleaned.length == 11) {
      return '+88$cleaned';
    }
    // Handle without plus: 8801XXXXXXXXX (13 digits)
    if (cleaned.startsWith('8801') && cleaned.length == 13) {
      return '+$cleaned';
    }
    // Handle 008801XXXXXXXXX
    if (cleaned.startsWith('008801')) {
      return '+${cleaned.substring(2)}';
    }

    return cleaned;
  }

  /// Triggers full SOS emergency pipeline:
  /// 1. Dynamically fetches contacts from [ContactService] or recovers from Firestore
  /// 2. Loosens validation: dispatches to all contacts with valid non-empty phone numbers
  /// 3. Fetches live GPS with strict 5s timeout; falls back to last known position
  /// 4. Dispatches direct background SMS and Cloud SOS concurrently
  ///
  /// [source] indicates where the trigger originated (e.g. "SOS Button", "ESP32 Hardware", "Shake", "Voice").
  Future<EmergencyResult> triggerEmergency({
    required String source,
    BuildContext? context,
    String? customMessage,
  }) async {
    debugPrint('[EmergencyService] 🚨 Triggering Emergency SOS via source: $source');

    // Step 1: Dynamically fetch active recipients from in-memory override or ContactService
    List<String> recipients = _emergencyContacts.where((c) => c.trim().isNotEmpty).toList();
    List<ContactModel> localContacts = await ContactService.instance.getContacts();

    // If local cache is empty, attempt recovery from Firestore users/{uid}/contacts
    if (localContacts.isEmpty) {
      try {
        if (Firebase.apps.isNotEmpty) {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            debugPrint('[EmergencyService] 🔍 Local contacts empty, attempting Firestore recovery...');
            final snap = await FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .collection('contacts')
                .get(const GetOptions(source: Source.serverAndCache))
                .timeout(const Duration(seconds: 3));

            for (final doc in snap.docs) {
              final data = doc.data();
              final c = ContactModel.fromMap({
                ...data,
                'id': doc.id,
                'contactUid': data['contactUid'] ?? data['contact_uid'] ?? doc.id,
              });
              await ContactService.instance.addContact(c);
            }
            localContacts = await ContactService.instance.getContacts();
          }
        }
      } catch (e) {
        debugPrint('[EmergencyService] Firestore contact recovery notice: $e');
      }
    }

    if (recipients.isEmpty) {
      // Loosen and validate contact selection:
      // Condition check: contact.phone.trim().isNotEmpty
      // Dispatches to all contacts that have a valid phone number, regardless of whether
      // their app sync status is Synced App User or Sync Pending.
      final validContacts = localContacts
          .where((c) => c.phone.trim().isNotEmpty)
          .toList();

      recipients = validContacts
          .map((c) => formatRecipientPhone(c.phone))
          .where((p) => p.isNotEmpty)
          .toSet()
          .toList();
    }

    // Step 2: Validate recipients presence
    if (recipients.isEmpty) {
      if (localContacts.isEmpty) {
        debugPrint('[EmergencyService] ⚠️ No emergency contacts configured.');
        return EmergencyResult(
          isSuccess: false,
          message: 'No emergency contacts configured. Please add emergency contacts first.',
          hasNoRecipients: true,
        );
      } else {
        debugPrint('[EmergencyService] ℹ️ ${localContacts.length} contact(s) configured, but none have a phone number for SMS. Proceeding with Cloud SOS...');
      }
    }

    debugPrint('[EmergencyService] 📋 Prepared ${recipients.length} SMS recipient(s): $recipients');

    // Step 3: Extract real-time GPS Location with strict 5-second timeout fallback
    Position? position;
    String? mapUrl;

    try {
      position = await _getCurrentLocation();
      if (position != null) {
        mapUrl = generateGoogleMapsUrl(position.latitude, position.longitude);
        debugPrint('[EmergencyService] 📍 Acquired Live Location: ${position.latitude}, ${position.longitude}');
        debugPrint('[EmergencyService] 🗺️ Maps URL: $mapUrl');
      }
    } catch (e) {
      debugPrint('[EmergencyService] ⏱️ Live GPS acquisition warning or timed out: $e');
    }

    // If live location failed or timed out, immediately attempt fallback to last known position
    if (position == null) {
      try {
        debugPrint('[EmergencyService] 🔄 Falling back to last known position...');
        position = await Geolocator.getLastKnownPosition()
            .timeout(const Duration(seconds: 2), onTimeout: () => null);
        if (position != null) {
          mapUrl = generateGoogleMapsUrl(position.latitude, position.longitude);
          debugPrint('[EmergencyService] 📍 Fallback to Last Known Location: ${position.latitude}, ${position.longitude}');
        }
      } catch (lastErr) {
        debugPrint('[EmergencyService] ❌ Fallback Location also failed: $lastErr');
      }
    }

    if (mapUrl == null) {
      debugPrint('[EmergencyService] ⚠️ GPS unavailable; proceeding with emergency message so SMS dispatch is not blocked.');
    }

    // Step 4: CONCURRENT DUAL DISPATCH (Cloud SOS + Offline Direct SMS)
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
      debugPrint('[EmergencyService] ❌ Cloud SOS dispatch error: $err');
      return null;
    });

    final smsFuture = recipients.isNotEmpty
        ? _dispatchOfflineSms(
            recipients: recipients,
            mapUrl: mapUrl,
            customMessage: customMessage,
          ).catchError((err) {
            debugPrint('[EmergencyService] ❌ SMS dispatch future error: $err');
            final bool isPermissionDenied = err.toString().contains('permission_denied') ||
                err.toString().contains('SEND_SMS');
            return _SmsDispatchResult(
              sentCount: 0,
              failedList: recipients,
              hasRecipients: true,
              permissionGranted: !isPermissionDenied,
            );
          })
        : Future.value(const _SmsDispatchResult(
            sentCount: 0,
            failedList: [],
            hasRecipients: false,
            permissionGranted: true,
          ));

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
      if (recipients.isEmpty) {
        resultSummary = '🚨 Cloud SOS alert broadcast to guardian(s)! Add a mobile number to contact to also send SMS.';
      } else if (!smsResult.permissionGranted) {
        resultSummary = '🚨 In-App alert sent to guardians! (SMS skipped: allow SMS in phone Settings).';
      } else {
        resultSummary = '🚨 Emergency cloud alert broadcast to all mutual guardians.';
      }
    } else if (!smsResult.permissionGranted) {
      resultSummary = 'SMS permission was denied. Please allow SMS permission in device settings.';
    } else if (localContacts.isNotEmpty && recipients.isEmpty) {
      resultSummary = 'Your emergency contact has no mobile phone number configured. Please add a phone number for SMS.';
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
      isPermissionDenied: !smsResult.permissionGranted,
      hasNoRecipients: localContacts.isEmpty && recipients.isEmpty,
    );
  }

  /// Dispatches offline background SMS messages to valid recipient phone numbers.
  Future<_SmsDispatchResult> _dispatchOfflineSms({
    required List<String> recipients,
    required String? mapUrl,
    required String? customMessage,
  }) async {
    final List<String> validRecipients = recipients
        .map((r) => r.trim())
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
          debugPrint('[EmergencyService] ❌ Failed to send SMS to $contact with primary format: $smsErr');

          // Automatic retry with alternate format:
          // +8801XXXXXXXXX -> 01XXXXXXXXX or 01XXXXXXXXX -> +8801XXXXXXXXX
          bool retrySuccess = false;
          String? fallbackNumber;
          if (contact.startsWith('+8801') && contact.length == 14) {
            fallbackNumber = contact.replaceFirst('+88', ''); // '01XXXXXXXXX'
          } else if (contact.startsWith('01') && contact.length == 11) {
            fallbackNumber = '+88$contact'; // '+8801XXXXXXXXX'
          }

          if (fallbackNumber != null && fallbackNumber != contact) {
            try {
              debugPrint('[EmergencyService] 🔄 Retrying SMS with alternate number format: $fallbackNumber');
              await _telephony.sendSms(
                to: fallbackNumber,
                message: smsBody,
                isMultipart: true,
              );
              sentCount++;
              retrySuccess = true;
              debugPrint('[EmergencyService] ✅ SMS successfully sent on retry to: $fallbackNumber');
            } catch (retryErr) {
              debugPrint('[EmergencyService] ❌ Retry SMS also failed for $fallbackNumber: $retryErr');
            }
          }

          if (!retrySuccess) {
            failedList.add(contact);
          }
        }
      }

      return _SmsDispatchResult(
        sentCount: sentCount,
        failedList: failedList,
        hasRecipients: true,
        permissionGranted: true,
      );
    } catch (e) {
      debugPrint('[EmergencyService] ❌ Offline SMS dispatch general error: $e');
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

  /// Checks & requests real-time location service status and permissions with 5s timeout.
  Future<Position?> _getCurrentLocation() async {
    // 1. Check if location services are enabled on device
    bool serviceEnabled = false;
    try {
      serviceEnabled = await Geolocator.isLocationServiceEnabled()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (e) {
      debugPrint('[EmergencyService] LocationServiceEnabled check notice: $e');
    }

    if (!serviceEnabled) {
      debugPrint('[EmergencyService] ⚠️ GPS location services are disabled on device.');
      return null;
    }

    // 2. Check location permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('[EmergencyService] ⚠️ Location permission was denied by user.');
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('[EmergencyService] ⚠️ Location permissions are permanently denied.');
      return null;
    }

    // 3. Extract high accuracy location with strict 5-second timeout
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 5),
      ),
    ).timeout(const Duration(seconds: 5));
  }

  /// Checks and requests SMS permission via [permission_handler] / [telephony].
  Future<bool> _checkAndRequestSmsPermission() async {
    if (kIsWeb) return false;

    try {
      final status = await Permission.sms.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        debugPrint('[EmergencyService] ⚠️ SMS permission is permanently denied.');
        return false;
      }
      final result = await Permission.sms.request();
      if (result.isGranted) return true;
    } catch (e) {
      debugPrint('[EmergencyService] Permission.sms check notice: $e');
    }

    try {
      bool? isSmsGranted = await _telephony.requestSmsPermissions;
      if (isSmsGranted == true) return true;
    } catch (e) {
      debugPrint('[EmergencyService] Telephony permission request notice: $e');
    }

    return false;
  }
}
