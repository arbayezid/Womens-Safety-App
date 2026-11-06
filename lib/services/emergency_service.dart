import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/activity_model.dart';
import '../models/contact_model.dart';
import 'activity_service.dart';
import 'auth_service.dart';
import 'background_service.dart';
import 'contact_service.dart';
import 'live_tracking_service.dart';
import 'native_sms_service.dart';
import 'safety_deadline_service.dart';
import 'siren_service.dart';
import 'sos_cloud_dispatcher.dart';
import 'sos_escalation_service.dart';

/// Data result object returned by [EmergencyService.triggerEmergency].
class EmergencyResult {
  final bool isSuccess;
  final String message;
  final Position? position;
  final String? googleMapsUrl;
  final int contactsSentCount;
  final List<String> failedContacts;
  final List<String> recipientPhones;
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
    this.recipientPhones = const [],
    this.isPermissionDenied = false,
    this.hasNoRecipients = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return 'EmergencyResult(isSuccess: $isSuccess, message: $message, mapsUrl: $googleMapsUrl, sentCount: $contactsSentCount, recipientPhones: $recipientPhones, permissionDenied: $isPermissionDenied, noRecipients: $hasNoRecipients)';
  }
}

/// Whether an SOS came from a deliberate press (button, pendant, duress PIN) or from an
/// automatic check that went unanswered (journey, ride, fall, shake countdown).
enum SosOrigin { manual, automatic }

/// The single door for SOS creation: concurrent triggers share one run, and while an alert is
/// live no second document is created. A manual press on a live alert re-rings it and re-sends
/// the SMS round; an automatic trigger on a live alert does nothing.
@visibleForTesting
class SosGate {
  SosGate({required this.liveAlertId, required this.reRing});

  /// Returns the ID of the sender's live alert, or null when none is live.
  final Future<String?> Function(SosOrigin origin) liveAlertId;

  /// Bumps the ring sequence of a live alert so every guardian rings once more.
  final Future<void> Function(String alertId) reRing;

  Future<EmergencyResult>? _inFlight;

  /// Runs [pipeline] through the gate. [pipeline] receives the live alert ID when the SMS round
  /// is re-sent for an existing alert, or null when a new alert must be created.
  Future<EmergencyResult> run(
    SosOrigin origin,
    Future<EmergencyResult> Function(String? existingAlertId) pipeline,
  ) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _guardedTrigger(origin, pipeline);
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<EmergencyResult> _guardedTrigger(
    SosOrigin origin,
    Future<EmergencyResult> Function(String? existingAlertId) pipeline,
  ) async {
    final existing = await liveAlertId(origin);
    if (existing != null) {
      if (origin == SosOrigin.manual) {
        try {
          // Bounded: an offline write never completes, and must not hold up the SMS round.
          await reRing(existing).timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('[EmergencyService] Re-ring of $existing failed: $e');
        }
        // A manual press also re-sends the SMS round, as before.
        return pipeline(existing);
      }
      debugPrint('[EmergencyService] Automatic SOS skipped: alert $existing is already active');
      return EmergencyResult(isSuccess: true, message: 'SOS already active');
    }
    return pipeline(null);
  }
}

class _SmsDispatchResult {
  final int sentCount;
  final List<String> failedList;
  final bool hasRecipients;
  final bool permissionGranted;

  /// Handed to the radio but not yet confirmed by the network.
  final int pendingCount;

  const _SmsDispatchResult({
    required this.sentCount,
    required this.failedList,
    required this.hasRecipients,
    required this.permissionGranted,
    this.pendingCount = 0,
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

  /// Reactive notifier for the currently active SOS alert ID (null when no alert is active)
  final ValueNotifier<String?> activeAlertIdNotifier = ValueNotifier<String?>(null);

  /// Synchronous getter for current active alert ID
  String? get activeAlertId => activeAlertIdNotifier.value;

  Future<void> _postDispatchWork = Future<void>.value();

  /// The cloud document of the last trigger while it is still being created.
  Future<String?>? _pendingCloudAlertId;

  late final SosGate _gate = SosGate(
    liveAlertId: _liveActiveAlertId,
    reRing: SosCloudDispatcher.instance.reRing,
  );

  /// Completes when the follow-up work of the last SOS (live tracking, background service,
  /// escalation arming) has finished. A background deadline run waits for it before exiting.
  Future<void> get postDispatchWork => _postDispatchWork;

  /// Restores active alert ID from SharedPreferences on app launch
  Future<void> restoreActiveAlertId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('active_sos_alert_id');
      if (savedId != null && savedId.isNotEmpty) {
        activeAlertIdNotifier.value = savedId;
        debugPrint('[EmergencyService] 🔄 Restored active SOS alert ID: $savedId');
      }
    } catch (_) {}
  }

  /// Resolves the currently active SOS alert, stops tracking and siren,
  /// sends "I'm safe now" SMS to contacts with a phone, and logs the event.
  Future<bool> markSafe({String? alertId}) async {
    final targetId = alertId ?? activeAlertId;
    debugPrint('[EmergencyService] 🛡️ Marking safe for SOS alert: $targetId');

    // 1. Resolve alert in Cloud Firestore
    if (targetId != null && targetId.isNotEmpty) {
      await SosCloudDispatcher.instance.resolveSosAlert(targetId);
      // Cancel this alert's escalation backstops (also when escalation timers are not running here)
      unawaited(SafetyDeadlineService.instance.clearSosStages(targetId));
    }

    // 2. Clear local active alert ID
    activeAlertIdNotifier.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('active_sos_alert_id');
    } catch (_) {}

    // 3. Stop live tracking, background service, and smart escalation
    SosEscalationService.instance.stopEscalation();
    await LiveTrackingService.instance.stopTrackingSession();
    await BackgroundServiceManager.instance.stopService();

    // 4. Stop siren if playing
    SirenService.instance.stopSiren();

    // 5. Send one "I'm safe now" SMS to contacts with a phone number
    final phoneNumbers = await ContactService.instance.getEmergencyPhoneNumbers();
    if (phoneNumbers.isNotEmpty) {
      final userName = AuthService.instance.displayName;
      final safeMessage = '$userName is safe now.';
      debugPrint('[EmergencyService] ✉️ Sending "I\'m Safe" SMS to ${phoneNumbers.length} contact(s): $safeMessage');
      for (final phone in phoneNumbers) {
        try {
          await _telephony.sendSms(
            to: phone,
            message: safeMessage,
            isMultipart: false,
          );
        } catch (e) {
          debugPrint('[EmergencyService] Failed to send safe SMS to $phone: $e');
        }
      }
    }

    // 6. Log activity event
    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.sos,
        title: "I'm Safe Confirmed",
        subtitle: "Resolved active SOS emergency alert and informed guardians.",
        timestamp: DateTime.now(),
      ),
    );

    return true;
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
  /// [origin] says whether a person pressed something or an unanswered automatic check fired.
  ///
  /// This is the only entry point that creates an `sos_alerts` document. Concurrent calls share
  /// one run, and while an alert is live no second document is created (see [SosGate]).
  Future<EmergencyResult> triggerEmergency({
    required String source,
    SosOrigin origin = SosOrigin.manual,
    BuildContext? context,
    String? customMessage,
    bool isDuress = false,
    bool playSiren = false,
    String? linkedJourneyId,
  }) {
    return _gate.run(
      origin,
      (existingAlertId) => _triggerEmergencyImpl(
        source: source,
        origin: origin,
        existingAlertId: existingAlertId,
        context: context,
        customMessage: customMessage,
        isDuress: isDuress,
        playSiren: playSiren,
        linkedJourneyId: linkedJourneyId,
      ),
    );
  }

  /// The locally stored alert ID only counts if Firestore still says it is live.
  Future<String?> _liveActiveAlertId(SosOrigin origin) async {
    String? id = activeAlertId;
    if (id == null) {
      // The document of an earlier trigger may still be on its way to Firestore.
      final pending = _pendingCloudAlertId;
      if (pending != null) id = await pending;
    }
    if (id == null) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('sos_alerts')
          .doc(id)
          .get()
          .timeout(const Duration(seconds: 3));
      final d = snap.data();
      final expiresAt = (d?['expiresAt'] as Timestamp?)?.toDate();
      final live = d != null &&
          d['status'] == 'active' &&
          (expiresAt == null || expiresAt.isAfter(DateTime.now()));
      if (live) return id;
    } catch (_) {
      // Offline: an automatic trigger trusts local state; a manual press never gets blocked.
      return origin == SosOrigin.automatic ? id : null;
    }
    await _clearActiveAlertLocally(id);
    return null;
  }

  /// Forgets an alert that is no longer live: removes the stored active alert ID and stops
  /// its live tracking and escalation.
  Future<void> _clearActiveAlertLocally(String alertId) async {
    debugPrint('[EmergencyService] Clearing stale local SOS state for $alertId');
    if (activeAlertId == alertId) activeAlertIdNotifier.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('active_sos_alert_id') == alertId) {
        await prefs.remove('active_sos_alert_id');
      }
    } catch (_) {}
    SosEscalationService.instance.stopEscalation();
    unawaited(SafetyDeadlineService.instance.clearSosStages(alertId));
    final tracking = LiveTrackingService.instance;
    if (tracking.activeSessionType == 'sos' && tracking.activeDocumentId == alertId) {
      await tracking.stopTrackingSession();
      await BackgroundServiceManager.instance.stopService();
    }
  }

  /// The SOS pipeline behind [triggerEmergency]. With [existingAlertId] it re-sends the SMS round
  /// for that live alert and creates no new cloud document.
  Future<EmergencyResult> _triggerEmergencyImpl({
    required String source,
    required SosOrigin origin,
    String? existingAlertId,
    BuildContext? context,
    String? customMessage,
    bool isDuress = false,
    bool playSiren = false,
    String? linkedJourneyId,
  }) async {
    debugPrint('[EmergencyService] 🚨 Triggering Emergency SOS via source: $source (duress: $isDuress, siren: $playSiren)');

    if (playSiren) {
      SirenService.instance.startSiren();
    }

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

    // Step 1.1: Explicit per-contact routing across free channels:
    // - Non-empty phone -> Offline SMS channel (E.164 formatted)
    // - Email (always present) -> In-app Firestore alert document recipient list (normalized lowercase)
    // - Synced App User -> Included in recipient UIDs for in-app alert listener
    // - Phone + Synced App User -> Receives both SMS and in-app alert
    final List<String> routedSmsRecipients = [];
    final List<String> routedCloudEmails = [];
    final List<String> routedCloudUids = [];

    // The Primary contact goes first in every list: the native sender hands SMS to the radio in
    // list order, so the primary is texted first. Everyone else keeps their place and is still
    // alerted exactly as before.
    final List<ContactModel> orderedContacts = ContactService.primaryFirst(localContacts);

    for (final contact in orderedContacts) {
      // Backup contacts are excluded from the initial SOS dispatch.
      // They are engaged in Stage 1 escalation if the regular contacts do not acknowledge.
      if (contact.isBackup) continue;

      // Channel 1: Offline SMS
      if (contact.phone.trim().isNotEmpty) {
        final formatted = formatRecipientPhone(contact.phone);
        if (formatted.isNotEmpty && !routedSmsRecipients.contains(formatted)) {
          routedSmsRecipients.add(formatted);
        }
      }

      // Channel 2: In-app Cloud SOS
      final normEmail = contact.email.trim().toLowerCase();
      if (normEmail.isNotEmpty && !routedCloudEmails.contains(normEmail)) {
        routedCloudEmails.add(normEmail);
      }

      if (contact.contactUid != null &&
          contact.contactUid!.isNotEmpty &&
          !contact.contactUid!.startsWith('offline_') &&
          !routedCloudUids.contains(contact.contactUid)) {
        routedCloudUids.add(contact.contactUid!);
      }
    }

    // Safety fallback: if user ONLY has backup contacts, include them immediately so SOS is never empty
    if (routedSmsRecipients.isEmpty && routedCloudEmails.isEmpty && routedCloudUids.isEmpty) {
      for (final contact in orderedContacts) {
        if (contact.phone.trim().isNotEmpty) {
          final formatted = formatRecipientPhone(contact.phone);
          if (formatted.isNotEmpty && !routedSmsRecipients.contains(formatted)) {
            routedSmsRecipients.add(formatted);
          }
        }
        final normEmail = contact.email.trim().toLowerCase();
        if (normEmail.isNotEmpty && !routedCloudEmails.contains(normEmail)) {
          routedCloudEmails.add(normEmail);
        }
        if (contact.contactUid != null &&
            contact.contactUid!.isNotEmpty &&
            !contact.contactUid!.startsWith('offline_') &&
            !routedCloudUids.contains(contact.contactUid)) {
          routedCloudUids.add(contact.contactUid!);
        }
      }
    }

    if (recipients.isEmpty) {
      recipients = routedSmsRecipients;
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

    // Step 3: Extract real-time GPS Location, capped at 10 seconds in total so the SMS is never
    // blocked on location (a pending permission dialog or a cold GPS can otherwise stall it).
    Position? position;
    String? mapUrl;

    try {
      position = await _getCurrentLocation().timeout(const Duration(seconds: 10));
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

    // A cached position older than 2 minutes is not a live fix: contacts get a follow-up SMS
    // as soon as a fresh fix arrives.
    final bool hasLiveFix = position != null &&
        DateTime.now().difference(position.timestamp).abs() < const Duration(minutes: 2);
    final String smsBody = buildSosSmsMessage(
      userName: AuthService.instance.displayName,
      latitude: position?.latitude,
      longitude: position?.longitude,
      time: DateTime.now(),
      customMessage: customMessage,
    );

    // Step 4: NON-BLOCKING DUAL DISPATCH (Cloud SOS + Offline Direct SMS)
    // 1. Fire Cloud SOS asynchronously so network latency/offline state never blocks SMS.
    // A re-sent round for a live alert reuses that alert's document and creates no new one.
    final Future<String?> cloudFuture = existingAlertId != null
        ? Future<String?>.value(existingAlertId)
        : SosCloudDispatcher.instance.triggerCloudSos(
            position: position,
            source: source,
            origin: origin.name,
            customNote: customMessage,
            recipientEmails: routedCloudEmails,
            recipientUids: routedCloudUids,
            isDuress: isDuress,
          ).catchError((err) {
            debugPrint('[EmergencyService] ❌ Cloud SOS dispatch error: $err');
            return null;
          });

    if (existingAlertId == null) {
      // Hook live tracking and active alert state as soon as Cloud SOS document is created
      _pendingCloudAlertId = cloudFuture;
      _postDispatchWork = cloudFuture.then((alertId) async {
        if (alertId != null && alertId.isNotEmpty) {
          activeAlertIdNotifier.value = alertId;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('active_sos_alert_id', alertId);
          } catch (_) {}

          // Start throttled live tracking for active SOS
          await LiveTrackingService.instance.startTrackingSession(
            sessionType: 'sos',
            documentId: alertId,
            initialPosition: position,
          );

          // Start foreground background service
          await BackgroundServiceManager.instance.startService(
            title: '🚨 Emergency SOS Live Tracking Active',
            content: 'Broadcasting live coordinates to your guardians',
          );

          // Start smart SOS escalation engine
          await SosEscalationService.instance.startEscalation(
            alertId: alertId,
            senderName: AuthService.instance.displayName,
            mapsUrl: mapUrl,
          );
        }
      }).catchError((_) {});
      // Registered after the hook above, so the active alert ID is set before this clears.
      unawaited(cloudFuture.whenComplete(() {
        if (identical(_pendingCloudAlertId, cloudFuture)) _pendingCloudAlertId = null;
      }));
    }

    // 2. Primary offline channel: Dispatch SMS immediately without waiting for Cloud SOS
    final _SmsDispatchResult smsResult;
    if (recipients.isNotEmpty) {
      smsResult = await _dispatchOfflineSms(
        recipients: recipients,
        smsBody: smsBody,
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
      });
    } else {
      smsResult = const _SmsDispatchResult(
        sentCount: 0,
        failedList: [],
        hasRecipients: false,
        permissionGranted: true,
      );
    }

    // SMS fallback: when direct sending is denied or failed, open the default SMS app with the
    // recipients and message pre-filled so the user only taps Send. Never in duress mode, which
    // must stay silent and hidden.
    bool composerOpened = false;
    final List<String> composerRecipients =
        !smsResult.permissionGranted ? recipients : smsResult.failedList;
    if (composerRecipients.isNotEmpty && !isDuress) {
      final outcome = await NativeSmsService.instance.openComposer(composerRecipients, smsBody);
      composerOpened = outcome == 'opened' || outcome == 'notified';
    }

    // Follow-up SMS with live coordinates once GPS gets a fix (never blocks the first SMS)
    final List<String> reachedRecipients =
        recipients.where((r) => !smsResult.failedList.contains(r)).toList();
    if (!hasLiveFix && smsResult.permissionGranted && reachedRecipients.isNotEmpty) {
      unawaited(_sendLocationFollowUp(reachedRecipients));
    }

    // 3. Evaluate Cloud SOS:
    // If SMS was sent, check if Cloud SOS already finished fast (e.g. 500ms race or local cache);
    // otherwise do not wait further so the UI receives immediate feedback while Cloud SOS queues in background.
    // If no SMS was sent (e.g. email-only contacts or SMS failed), wait up to 3s for Cloud SOS.
    String? cloudAlertId;
    if (smsResult.sentCount > 0) {
      try {
        cloudAlertId = await cloudFuture.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => null,
        );
      } catch (_) {}
    } else {
      try {
        cloudAlertId = await cloudFuture.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            debugPrint('[EmergencyService] ⏱️ Cloud SOS timed out (queued in background)');
            return null;
          },
        );
      } catch (_) {}
    }

    final int sentCount = smsResult.sentCount;
    final int pendingCount = smsResult.pendingCount;
    final List<String> failedList = smsResult.failedList;
    final bool cloudSent = cloudAlertId != null;
    final bool overallSuccess = sentCount > 0 || pendingCount > 0 || cloudSent;

    // e.g. "SMS sent to 2 of 3 contacts" (+ how many are still going out)
    String smsCountText = 'SMS sent to $sentCount of ${recipients.length} contact(s)';
    if (pendingCount > 0) smsCountText += ', $pendingCount still sending';
    final String composerNote = composerOpened ? ' Messages app opened for the rest; tap Send.' : '';

    String resultSummary;
    if ((sentCount > 0 || pendingCount > 0) && cloudSent) {
      resultSummary = 'SOS alert dispatched! $smsCountText & Cloud alert broadcast.$composerNote';
    } else if (sentCount > 0 || pendingCount > 0) {
      resultSummary = '$smsCountText. Cloud alert queued.$composerNote';
    } else if (cloudSent) {
      if (recipients.isEmpty) {
        resultSummary = '🚨 Cloud SOS alert broadcast to guardian(s)! Add a mobile number to contact to also send SMS.';
      } else if (!smsResult.permissionGranted) {
        resultSummary = composerOpened
            ? '🚨 In-App alert sent to guardians! SMS permission is off, so Messages was opened; tap Send.'
            : '🚨 In-App alert sent to guardians! (SMS skipped: allow SMS in phone Settings).';
      } else if (sentCount == 0 && recipients.isNotEmpty) {
        resultSummary = composerOpened
            ? '🚨 Alert broadcast to guardians. $smsCountText.$composerNote'
            : '🚨 Alert broadcast to guardians. (SMS not sent automatically; tap below to send via SMS app).';
      } else {
        resultSummary = '🚨 Emergency cloud alert broadcast to all mutual guardians.';
      }
    } else if (!smsResult.permissionGranted) {
      resultSummary = composerOpened
          ? 'SMS permission is off, so Messages was opened with your SOS; tap Send.'
          : 'SMS permission was denied. Please allow SMS permission in device settings.';
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
      recipientPhones: recipients,
      isPermissionDenied: !smsResult.permissionGranted,
      hasNoRecipients: localContacts.isEmpty && recipients.isEmpty,
    );
  }

  /// Dispatches offline background SMS messages to valid recipient phone numbers.
  Future<_SmsDispatchResult> _dispatchOfflineSms({
    required List<String> recipients,
    required String smsBody,
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

      // Primary path: native sender (explicit SIM selection, multipart, confirmed delivery to the network)
      final nativeResults = await NativeSmsService.instance.send(validRecipients, smsBody);
      if (nativeResults != null) {
        final int sent = nativeResults.where((r) => r.isSent).length;
        final int pendingCount = nativeResults.where((r) => r.isPending).length;
        final List<String> failed = nativeResults
            .where((r) => !r.isSent && !r.isPending)
            .map((r) => r.recipient)
            .toList();
        debugPrint('[EmergencyService] 📨 Native SMS: $sent sent, $pendingCount pending, ${failed.length} failed of ${validRecipients.length}');
        return _SmsDispatchResult(
          sentCount: sent,
          pendingCount: pendingCount,
          failedList: failed,
          hasRecipients: true,
          permissionGranted: !nativeResults.any((r) => r.isPermissionDenied),
        );
      }

      // Native sender unavailable (non-Android): telephony plugin
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

  /// Opens the device's native messaging application with pre-filled emergency SMS.
  /// Works reliably across all Android versions, dual-SIM devices, and cellular carriers.
  Future<bool> launchNativeSmsApp({
    String? phoneNumber,
    String? customMessage,
    String? mapUrl,
  }) async {
    try {
      final String phone = phoneNumber != null ? formatRecipientPhone(phoneNumber) : '';
      final String body = customMessage ?? buildEmergencyMessage(mapUrl);
      final Uri uri = Uri(
        scheme: 'sms',
        path: phone,
        queryParameters: <String, String>{'body': body},
      );
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[EmergencyService] Native SMS app launch notice: $e');
    }
    return false;
  }

  /// Builds the SOS SMS text:
  /// `EMERGENCY! [Name] needs help. Live location: https://maps.google.com/?q=LAT,LNG  Time: [time]`
  /// A [customMessage] (fall, journey, duress...) replaces the first sentence; location and time
  /// are always appended so every SOS SMS carries a working map link.
  String buildSosSmsMessage({
    required String userName,
    double? latitude,
    double? longitude,
    required DateTime time,
    String? customMessage,
  }) {
    final name = userName.trim().isNotEmpty ? userName.trim() : 'A Woman Guard user';
    final intro = (customMessage != null && customMessage.trim().isNotEmpty)
        ? customMessage.trim()
        : 'EMERGENCY! $name needs help.';
    final location = (latitude != null && longitude != null)
        ? buildSmsMapsLink(latitude, longitude)
        : 'Location unavailable';
    return '$intro Live location: $location  Time: ${formatSmsTime(time)}';
  }

  /// Follow-up text sent once a live GPS fix is available after the first SOS SMS.
  String buildSosLocationUpdateMessage({
    required String userName,
    required double latitude,
    required double longitude,
    required DateTime time,
  }) {
    final name = userName.trim().isNotEmpty ? userName.trim() : 'A Woman Guard user';
    return 'EMERGENCY UPDATE: $name needs help. Live location: ${buildSmsMapsLink(latitude, longitude)}  Time: ${formatSmsTime(time)}';
  }

  /// Short Google Maps link that opens on any phone (smartphone browser or Maps app).
  String buildSmsMapsLink(double latitude, double longitude) {
    return 'https://maps.google.com/?q=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  }

  /// Formats e.g. `10:42 PM, 30 Oct 2026`.
  String formatSmsTime(DateTime time) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.hour < 12 ? 'AM' : 'PM';
    return '$hour12:$minute $period, ${time.day} ${months[time.month - 1]} ${time.year}';
  }

  /// Waits (in the background) for a live GPS fix and texts it to [recipients].
  Future<void> _sendLocationFollowUp(List<String> recipients) async {
    try {
      final fix = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 90),
        ),
      );
      final message = buildSosLocationUpdateMessage(
        userName: AuthService.instance.displayName,
        latitude: fix.latitude,
        longitude: fix.longitude,
        time: DateTime.now(),
      );
      debugPrint('[EmergencyService] 📍 Live fix acquired; sending follow-up SMS to ${recipients.length} contact(s)');
      final results = await NativeSmsService.instance.send(recipients, message);
      if (results == null) {
        for (final phone in recipients) {
          await _telephony.sendSms(to: phone, message: message, isMultipart: true);
        }
      }
    } catch (e) {
      debugPrint('[EmergencyService] No live GPS fix for follow-up SMS: $e');
    }
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

    // 3. Extract location with Android 12+ Approximate accuracy fallback & strict timeout
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      ).timeout(const Duration(seconds: 5));
    } catch (highErr) {
      debugPrint('[EmergencyService] High-accuracy GPS notice: $highErr. Trying medium accuracy.');
      try {
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 3),
          ),
        ).timeout(const Duration(seconds: 3));
      } catch (_) {
        return await Geolocator.getLastKnownPosition();
      }
    }
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
