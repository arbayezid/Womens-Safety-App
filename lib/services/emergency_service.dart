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
import 'journey_service.dart';
import 'live_tracking_service.dart';
import 'native_sms_service.dart';
import 'sms_settings.dart';
import 'sos_location_warmer.dart';
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

/// What the last SOS round (first send or a re-send) actually reached, for the home screen's
/// status line. Counts come from the real dispatch results, never from the contact list alone.
class SosDispatchStatus {
  /// SMS confirmed sent / handed to the radio but unconfirmed / attempted.
  final int smsSent;
  final int smsPending;
  final int smsTotal;

  /// Formatted phone numbers whose SMS did not go out automatically.
  final List<String> smsFailed;

  /// The SMS text of this round, so a retry sends exactly the same message.
  final String smsBody;

  /// True once the in-app (cloud) alert document exists for this round.
  final bool cloudSent;

  /// True when the default Messages app was opened for the failed recipients.
  final bool composerOpened;

  /// True when SMS alerts are switched off in Settings (in-app alert only).
  final bool smsOff;

  /// True for a re-send of an alert that was already live.
  final bool isResend;
  final DateTime at;

  final int _reachedWithCloud;
  final int _reachedWithoutCloud;

  const SosDispatchStatus({
    required this.smsSent,
    required this.smsPending,
    required this.smsTotal,
    required this.smsFailed,
    required this.smsBody,
    required this.cloudSent,
    required this.composerOpened,
    this.smsOff = false,
    required this.isResend,
    required this.at,
    required int reachedWithCloud,
    required int reachedWithoutCloud,
  })  : _reachedWithCloud = reachedWithCloud,
        _reachedWithoutCloud = reachedWithoutCloud;

  /// Distinct contacts reached by at least one channel (in-app alert or SMS sent / sending).
  int get contactsReached => cloudSent ? _reachedWithCloud : _reachedWithoutCloud;

  /// True when some SMS recipients still have not been sent the alert.
  bool get smsNeedsAttention => smsFailed.isNotEmpty;

  SosDispatchStatus copyWith({
    int? smsSent,
    int? smsPending,
    List<String>? smsFailed,
    bool? cloudSent,
    bool? composerOpened,
    int? reachedWithoutCloud,
    int? reachedWithCloud,
  }) {
    return SosDispatchStatus(
      smsSent: smsSent ?? this.smsSent,
      smsPending: smsPending ?? this.smsPending,
      smsTotal: smsTotal,
      smsFailed: smsFailed ?? this.smsFailed,
      smsBody: smsBody,
      cloudSent: cloudSent ?? this.cloudSent,
      composerOpened: composerOpened ?? this.composerOpened,
      smsOff: smsOff,
      isResend: isResend,
      at: at,
      reachedWithCloud: reachedWithCloud ?? _reachedWithCloud,
      reachedWithoutCloud: reachedWithoutCloud ?? _reachedWithoutCloud,
    );
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
  ///
  /// [liveAlertIdOverride] replaces [liveAlertId] for this run only (used by an explicit
  /// re-send, which trusts the local alert while offline instead of creating a second one).
  Future<EmergencyResult> run(
    SosOrigin origin,
    Future<EmergencyResult> Function(String? existingAlertId) pipeline, {
    Future<String?> Function(SosOrigin origin)? liveAlertIdOverride,
  }) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _guardedTrigger(origin, pipeline, liveAlertIdOverride ?? liveAlertId);
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<EmergencyResult> _guardedTrigger(
    SosOrigin origin,
    Future<EmergencyResult> Function(String? existingAlertId) pipeline,
    Future<String?> Function(SosOrigin origin) liveAlertId,
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

  /// When the active alert was triggered (null when no alert is active). Persisted with the
  /// alert ID so the home screen's elapsed timer survives an app restart.
  final ValueNotifier<DateTime?> activeAlertStartedAtNotifier = ValueNotifier<DateTime?>(null);

  /// True while an SOS round is being sent, from any source (home button, ESP32 pendant,
  /// shake, voice, journey), until its alert document exists or the round has finished.
  final ValueNotifier<bool> sosInProgressNotifier = ValueNotifier<bool>(false);

  /// Result of the last SOS round for the active alert (null when none, or after a restart).
  final ValueNotifier<SosDispatchStatus?> lastDispatchNotifier =
      ValueNotifier<SosDispatchStatus?>(null);

  /// How long the home screen's "Re-send" option stays disabled after any manual SOS press.
  /// Matches the pendant's hardware cooldown, so guardians are never rung more often than that.
  static const Duration resendCooldown = Duration(seconds: 30);

  DateTime? _lastManualTriggerAt;

  /// Time left before the home screen offers "Re-send" again (zero when available).
  Duration get resendCooldownRemaining {
    final last = _lastManualTriggerAt;
    if (last == null) return Duration.zero;
    final left = resendCooldown - DateTime.now().difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  static const String _prefKeyActiveAlertId = 'active_sos_alert_id';
  static const String _prefKeyActiveAlertStartedAt = 'active_sos_started_at';

  bool _gateRunning = false;

  /// Increments with every SOS round, so a late cloud result only updates its own round.
  int _dispatchRound = 0;

  /// True when the pending cloud document belongs to a duress round, which must stay silent.
  bool _pendingIsSilent = false;

  void _refreshInProgress() {
    sosInProgressNotifier.value =
        _gateRunning || (_pendingCloudAlertId != null && !_pendingIsSilent);
  }

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

  /// Restores active alert ID from SharedPreferences on app launch, but only while Firestore still
  /// says the alert is live. An ended or expired alert is cleared instead, and its tracking and
  /// escalation are not resumed. Offline, the stored ID is kept as before.
  Future<void> restoreActiveAlertId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_prefKeyActiveAlertId);
      if (savedId != null && savedId.isNotEmpty) {
        final live = await _isAlertLiveInCloud(savedId);
        if (live == false) {
          debugPrint('[EmergencyService] Stored SOS alert $savedId is no longer live; not restoring');
          await _clearActiveAlertLocally(savedId);
          return;
        }
        final savedStartMs = prefs.getInt(_prefKeyActiveAlertStartedAt);
        activeAlertStartedAtNotifier.value = savedStartMs != null
            ? DateTime.fromMillisecondsSinceEpoch(savedStartMs)
            : await _fetchTriggeredAt(savedId);
        activeAlertIdNotifier.value = savedId;
        debugPrint('[EmergencyService] 🔄 Restored active SOS alert ID: $savedId');
      }
    } catch (_) {}
  }

  /// True while an alert document is active and not past its `expiresAt`.
  @visibleForTesting
  static bool isAlertDocLive(Map<String, dynamic>? data, DateTime now) {
    if (data == null || data['status'] != 'active') return false;
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
    return expiresAt == null || expiresAt.isAfter(now);
  }

  /// Best-effort read of an alert's `triggeredAt` (for alerts stored before the start time was
  /// saved locally). Null when offline or missing.
  Future<DateTime?> _fetchTriggeredAt(String alertId) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('sos_alerts')
          .doc(alertId)
          .get()
          .timeout(const Duration(seconds: 3));
      return (snap.data()?['triggeredAt'] as Timestamp?)?.toDate();
    } catch (_) {
      return null;
    }
  }

  /// Forgets the active alert's ID, start time and last-round status, in memory and on disk.
  Future<void> _forgetActiveAlertState({String? onlyIfId}) async {
    if (onlyIfId == null || activeAlertId == onlyIfId) {
      activeAlertStartedAtNotifier.value = null;
      lastDispatchNotifier.value = null;
      activeAlertIdNotifier.value = null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (onlyIfId == null || prefs.getString(_prefKeyActiveAlertId) == onlyIfId) {
        await prefs.remove(_prefKeyActiveAlertId);
        await prefs.remove(_prefKeyActiveAlertStartedAt);
      }
    } catch (_) {}
  }

  /// Reads [alertId] from Firestore: true = live, false = ended / expired / missing,
  /// null = could not be checked (offline or Firebase unavailable).
  Future<bool?> _isAlertLiveInCloud(String alertId) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('sos_alerts')
          .doc(alertId)
          .get()
          .timeout(const Duration(seconds: 3));
      return isAlertDocLive(snap.data(), DateTime.now());
    } catch (_) {
      return null;
    }
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

    // 2. Clear local active alert ID, start time and status
    await _forgetActiveAlertState();

    // 3. Stop live tracking, background service, and smart escalation
    SosEscalationService.instance.stopEscalation();
    await LiveTrackingService.instance.stopTrackingSession();
    await BackgroundServiceManager.instance.stopService();

    // 4. Stop siren if playing
    SirenService.instance.stopSiren();

    // 5. No "I'm safe" SMS: only the alert itself is texted. Guardians in the app see the
    // alert resolved through Firestore.

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
    required SosOrigin origin,
    BuildContext? context,
    String? customMessage,
    bool isDuress = false,
    bool playSiren = false,
    String? linkedJourneyId,
  }) {
    return _runGate(
      origin: origin,
      isDuress: isDuress,
      pipeline: (existingAlertId) => _triggerEmergencyImpl(
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

  /// Marks the running journey (Followed Mode or Safe Journey) as alert, linked to SOS [alertId],
  /// whatever sent the SOS: the SOS button, the ESP32 button, shake, a missed check-in or the
  /// duress PIN. Its check-ins then stop, so nothing prompts on screen during a silent alert, and
  /// guardians see the journey as an emergency. Works in the headless engine too (the journey is
  /// read from the saved session). [isDuress] tells guardians not to call.
  Future<void> _linkActiveJourney(String alertId, {String? journeyId, required bool isDuress}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = journeyId ?? prefs.getString(JourneyService.prefKeyActiveJourneyId);
      if (id == null || id.isEmpty) return;
      final ref = FirebaseFirestore.instance.collection('journeys').doc(id);
      final snap = await ref.get().timeout(const Duration(seconds: 6));
      final status = snap.data()?['status']?.toString();
      if (status != 'active' && status != 'alert') return; // ended: nothing to take over
      await ref.update({
        'status': 'alert',
        'linkedSosAlertId': alertId,
        'linkedSosDuress': isDuress,
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 6));
      debugPrint('[EmergencyService] Linked SOS $alertId to journey $id');
    } catch (e) {
      debugPrint('[EmergencyService] Could not link SOS to the journey: $e');
    }
  }

  /// Explicit "Re-send" of the active alert from the home screen: re-rings guardians and
  /// re-sends the SMS round for the same alert document.
  ///
  /// Unlike a plain press, it trusts the local alert while offline (Firestore unreachable), so
  /// an offline re-send goes out as SMS and never creates a second alert document. If Firestore
  /// says the alert has ended, a new alert is created, as with any manual press.
  Future<EmergencyResult> resendActiveAlert({String source = 'SOS Button (re-send)'}) {
    final localId = activeAlertId;
    if (localId == null) {
      return triggerEmergency(source: source, origin: SosOrigin.manual);
    }
    return _runGate(
      origin: SosOrigin.manual,
      isDuress: false,
      liveAlertIdOverride: (_) async {
        final live = await _isAlertLiveInCloud(localId);
        if (live == false) {
          await _clearActiveAlertLocally(localId);
          return null;
        }
        return localId; // live, or offline (unknown): reuse the local alert
      },
      pipeline: (existingAlertId) => _triggerEmergencyImpl(
        source: source,
        origin: SosOrigin.manual,
        existingAlertId: existingAlertId,
      ),
    );
  }

  /// Runs one round through [SosGate] and keeps [sosInProgressNotifier] and the re-send
  /// cooldown up to date. A duress round stays silent: it never shows the "sending" state.
  Future<EmergencyResult> _runGate({
    required SosOrigin origin,
    required bool isDuress,
    required Future<EmergencyResult> Function(String? existingAlertId) pipeline,
    Future<String?> Function(SosOrigin origin)? liveAlertIdOverride,
  }) {
    if (origin == SosOrigin.manual) _lastManualTriggerAt = DateTime.now();
    final future = _gate.run(origin, pipeline, liveAlertIdOverride: liveAlertIdOverride);
    if (!isDuress && !_gateRunning) {
      _gateRunning = true;
      _refreshInProgress();
      unawaited(future.whenComplete(() {
        _gateRunning = false;
        _refreshInProgress();
      }).then((_) {}, onError: (_) {}));
    }
    return future;
  }

  /// Tries the SMS recipients of the last round that were not reached again, sending directly in
  /// the background (the Messages app is never opened). Updates [lastDispatchNotifier] and
  /// returns the new status (null when there was nothing to retry).
  Future<SosDispatchStatus?> retryFailedSms() async {
    final status = lastDispatchNotifier.value;
    if (status == null || status.smsFailed.isEmpty) return status;
    if (!await SmsSettings.isEnabled()) return status;
    final round = _dispatchRound;

    final retry = await _dispatchOfflineSms(recipients: status.smsFailed, smsBody: status.smsBody)
        .catchError((Object _) => _SmsDispatchResult(
              sentCount: 0,
              failedList: status.smsFailed,
              hasRecipients: true,
              permissionGranted: true,
            ));
    final List<String> remaining = !retry.permissionGranted ? status.smsFailed : retry.failedList;
    const bool composerOpened = false;

    final newlyReached = retry.sentCount + retry.pendingCount;
    final updated = status.copyWith(
      smsSent: status.smsSent + retry.sentCount,
      smsPending: status.smsPending + retry.pendingCount,
      smsFailed: remaining,
      composerOpened: composerOpened,
      reachedWithoutCloud: status._reachedWithoutCloud + newlyReached,
      reachedWithCloud: status._reachedWithCloud + newlyReached,
    );
    // Only publish if no newer round replaced this one meanwhile.
    if (round == _dispatchRound && lastDispatchNotifier.value != null) {
      lastDispatchNotifier.value = updated;
    }
    return updated;
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
    final live = await _isAlertLiveInCloud(id);
    if (live == null) {
      // Offline: an automatic trigger trusts local state; a manual press never gets blocked.
      return origin == SosOrigin.automatic ? id : null;
    }
    if (live) return id;
    await _clearActiveAlertLocally(id);
    return null;
  }

  /// Forgets an alert that is no longer live: removes the stored active alert ID and stops
  /// its live tracking and escalation.
  Future<void> _clearActiveAlertLocally(String alertId) async {
    debugPrint('[EmergencyService] Clearing stale local SOS state for $alertId');
    await _forgetActiveAlertState(onlyIfId: alertId);
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
    final DateTime triggerStartedAt = DateTime.now();
    final int round = ++_dispatchRound;

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

    // Per-contact routing record (formatted phone, in-app or not), used only to count how many
    // distinct people the round actually reached for the home screen's status line.
    final List<({String? phone, bool inApp})> routedContacts = [];

    void routeContact(ContactModel contact) {
      // A contact whose connection request is not accepted yet gets nothing, on any channel.
      if (!contact.canReceiveAlerts) return;

      String? formattedPhone;
      bool inApp = false;

      // Channel 1: Offline SMS
      if (contact.phone.trim().isNotEmpty) {
        final formatted = formatRecipientPhone(contact.phone);
        if (formatted.isNotEmpty) {
          formattedPhone = formatted;
          if (!routedSmsRecipients.contains(formatted)) routedSmsRecipients.add(formatted);
        }
      }

      // Channel 2: In-app Cloud SOS, only for guardians who accepted the request
      if (!contact.canReceiveAppAlerts) {
        if (formattedPhone != null) routedContacts.add((phone: formattedPhone, inApp: false));
        return;
      }
      final normEmail = contact.email.trim().toLowerCase();
      if (normEmail.isNotEmpty) {
        inApp = true;
        if (!routedCloudEmails.contains(normEmail)) routedCloudEmails.add(normEmail);
      }

      if (contact.contactUid != null &&
          contact.contactUid!.isNotEmpty &&
          !contact.contactUid!.startsWith('offline_')) {
        inApp = true;
        if (!routedCloudUids.contains(contact.contactUid)) routedCloudUids.add(contact.contactUid!);
      }

      if (formattedPhone != null || inApp) {
        routedContacts.add((phone: formattedPhone, inApp: inApp));
      }
    }

    for (final contact in orderedContacts) {
      // Backup contacts are excluded from the initial SOS dispatch.
      // They are engaged in Stage 1 escalation if the regular contacts do not acknowledge.
      if (contact.isBackup) continue;
      routeContact(contact);
    }

    // Safety fallback: if user ONLY has backup contacts, include them immediately so SOS is never empty
    if (routedSmsRecipients.isEmpty && routedCloudEmails.isEmpty && routedCloudUids.isEmpty) {
      routedContacts.clear();
      for (final contact in orderedContacts) {
        routeContact(contact);
      }
    }

    if (recipients.isEmpty) {
      recipients = routedSmsRecipients;
    }

    // Settings > SMS alerts off: no text messages, guardians are alerted in the app only.
    final bool smsEnabled = await SmsSettings.isEnabled();
    if (!smsEnabled) {
      debugPrint('[EmergencyService] SMS alerts are off in Settings; sending the in-app alert only.');
      recipients = [];
    }

    // Contacts exist, but none has accepted a request yet: nobody may be alerted, so nothing
    // is sent.
    if (localContacts.isNotEmpty &&
        !localContacts.any((c) => c.canReceiveAlerts) &&
        _emergencyContacts.isEmpty) {
      debugPrint('[EmergencyService] ⚠️ No contact has accepted a request yet; nothing sent.');
      return EmergencyResult(
        isSuccess: false,
        message: "None of your contacts has accepted your request yet. Alerts are sent only "
            "to contacts who accept.",
        hasNoRecipients: true,
      );
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

    // Step 3: Get an accurate location for the one SOS SMS without delaying it: usually the warm
    // GPS fix (instant), at most a 1.5 s wait. Capped at 3 s in total so a pending permission
    // dialog can never stall the SMS.
    Position? position;
    String? mapUrl;

    try {
      position = await _getCurrentLocation().timeout(const Duration(seconds: 3));
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
            .timeout(const Duration(seconds: 1), onTimeout: () => null);
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

    // A cached position older than 2 minutes is not a live fix, and a Wi-Fi / cell fix (used
    // only when GPS never got precise) can be 100 m+ off: the SMS then says "Approx. location".
    final bool hasLiveFix = position != null &&
        DateTime.now().difference(position.timestamp).abs() < const Duration(minutes: 2);
    final bool hasPreciseFix = hasLiveFix && _isPrecise(position);
    if (position != null) {
      debugPrint('[EmergencyService] 📍 Fix accuracy: ${position.accuracy.toStringAsFixed(0)} m '
          '(live: $hasLiveFix, precise: $hasPreciseFix)');
    }
    final String smsBody = buildSosSmsMessage(
      userName: AuthService.instance.displayName,
      latitude: position?.latitude,
      longitude: position?.longitude,
      accuracyMeters: hasPreciseFix ? null : position?.accuracy,
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
      _pendingIsSilent = isDuress;
      _refreshInProgress();
      _postDispatchWork = cloudFuture.then((alertId) async {
        if (alertId != null && alertId.isNotEmpty) {
          // Start time first, so the home screen's timer has it when the ID arrives.
          activeAlertStartedAtNotifier.value = triggerStartedAt;
          activeAlertIdNotifier.value = alertId;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_prefKeyActiveAlertId, alertId);
            await prefs.setInt(
                _prefKeyActiveAlertStartedAt, triggerStartedAt.millisecondsSinceEpoch);
          } catch (_) {}

          // An SOS during Followed Mode or a Safe Journey takes the journey over
          unawaited(_linkActiveJourney(alertId, journeyId: linkedJourneyId, isDuress: isDuress));

          // Start throttled live tracking for active SOS
          await LiveTrackingService.instance.startTrackingSession(
            sessionType: 'sos',
            documentId: alertId,
            initialPosition: position,
          );

          // Start foreground background service. A duress alert keeps the calculator disguise
          // (this can run after PinSecurityService has already set it).
          await BackgroundServiceManager.instance.startService(
            title: isDuress ? 'Calculator' : 'SOS active · sharing your location',
            content: isDuress
                ? 'Running background mathematical process'
                : 'Broadcasting live coordinates to your guardians',
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
        _refreshInProgress();
      }));
    }

    // Counts how many distinct contacts an SMS result reached (with or without the in-app alert).
    int reachedBy(_SmsDispatchResult sms, bool withCloud) {
      final Set<String> reachedPhones =
          recipients.where((r) => !sms.failedList.contains(r)).toSet();
      return routedContacts
          .where((c) =>
              (withCloud && c.inApp) ||
              (c.phone != null && sms.permissionGranted && reachedPhones.contains(c.phone)))
          .length;
    }

    // SMS confirmed after this round stopped waiting: show the real outcome. If it lands before
    // this round's status is published, the status is simply built from it.
    _SmsDispatchResult? confirmedSms;
    bool statusPublished = false;
    void applyConfirmedSms(_SmsDispatchResult confirmed) {
      confirmedSms = confirmed;
      if (!statusPublished) return;
      final current = lastDispatchNotifier.value;
      if (round != _dispatchRound || current == null) return;
      lastDispatchNotifier.value = current.copyWith(
        smsSent: confirmed.sentCount,
        smsPending: confirmed.pendingCount,
        smsFailed: confirmed.permissionGranted ? confirmed.failedList : recipients,
        reachedWithCloud: reachedBy(confirmed, true),
        reachedWithoutCloud: reachedBy(confirmed, false),
      );
    }

    // 2. Primary offline channel: Dispatch SMS immediately without waiting for Cloud SOS
    final _SmsDispatchResult smsResult;
    if (recipients.isNotEmpty) {
      smsResult = await _dispatchOfflineSms(
        recipients: recipients,
        smsBody: smsBody,
        confirmWait: _smsConfirmWait,
        onConfirmed: applyConfirmedSms,
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

    // SMS is sent in the background only: the app never switches to the Messages app on its own.
    // Anyone not reached shows up in the alert banner with a Retry button instead.
    const bool composerOpened = false;

    // 3. Evaluate Cloud SOS:
    // If SMS went out (sent or still being confirmed), check if Cloud SOS already finished fast
    // (e.g. 500ms race or local cache); otherwise do not wait further so the UI receives
    // immediate feedback while Cloud SOS queues in background.
    // If no SMS was sent (e.g. email-only contacts or SMS failed), wait up to 3s for Cloud SOS.
    String? cloudAlertId;
    if (smsResult.sentCount + smsResult.pendingCount > 0) {
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

    String resultSummary;
    if ((sentCount > 0 || pendingCount > 0) && cloudSent) {
      resultSummary = 'SOS sent. $smsCountText. Guardians alerted in the app.';
    } else if (sentCount > 0 || pendingCount > 0) {
      resultSummary = '$smsCountText. The app alert will send when you are online.';
    } else if (cloudSent) {
      if (!smsEnabled) {
        resultSummary = 'Guardians alerted in the app. SMS alerts are off in Settings.';
      } else if (recipients.isEmpty) {
        resultSummary = 'Guardians alerted in the app. Add a mobile number to a contact to also send SMS.';
      } else if (!smsResult.permissionGranted) {
        resultSummary = 'Guardians alerted in the app. SMS was skipped; allow SMS in phone Settings.';
      } else if (sentCount == 0 && recipients.isNotEmpty) {
        resultSummary = "Guardians alerted in the app. SMS wasn't sent; tap Retry to try again.";
      } else {
        resultSummary = 'All guardians alerted in the app.';
      }
    } else if (!smsEnabled) {
      resultSummary = 'SMS alerts are off and the in-app alert could not be sent. Check your internet connection.';
    } else if (!smsResult.permissionGranted) {
      resultSummary = 'SMS permission was denied. Please allow SMS permission in device settings.';
    } else if (localContacts.isNotEmpty && recipients.isEmpty) {
      resultSummary = 'Your emergency contact has no mobile phone number configured. Please add a phone number for SMS.';
    } else if (!smsResult.hasRecipients) {
      resultSummary = 'No emergency contacts configured. Please add emergency contacts first.';
    } else {
      resultSummary = 'Failed to dispatch emergency alerts.';
    }

    // Publish what this round really reached, for the home screen's status line.
    if (overallSuccess) {
      // Real SMS results that arrived during the cloud wait above replace the early ones.
      final _SmsDispatchResult sms = confirmedSms ?? smsResult;
      lastDispatchNotifier.value = SosDispatchStatus(
        smsSent: sms.sentCount,
        smsPending: sms.pendingCount,
        smsTotal: recipients.length,
        smsFailed: sms.permissionGranted ? sms.failedList : recipients,
        smsBody: smsBody,
        cloudSent: cloudSent,
        composerOpened: composerOpened,
        smsOff: !smsEnabled,
        isResend: existingAlertId != null,
        at: DateTime.now(),
        reachedWithCloud: reachedBy(sms, true),
        reachedWithoutCloud: reachedBy(sms, false),
      );
      statusPublished = true;
      if (!cloudSent) {
        // The cloud document can land after the 500 ms wait above: count in-app guardians then.
        unawaited(cloudFuture.then((id) {
          final current = lastDispatchNotifier.value;
          if (id != null && round == _dispatchRound && current != null) {
            lastDispatchNotifier.value = current.copyWith(cloudSent: true);
          }
        }).catchError((Object _) {}));
      }
    }

    // Log the SOS emergency event for profile activity tracking
    ActivityService.instance.logSOS(
      source: source,
      contactsSent: sentCount + pendingCount > 0 ? sentCount + pendingCount : (cloudSent ? 1 : 0),
      mapUrl: mapUrl,
      isSuccess: overallSuccess,
    );

    return EmergencyResult(
      isSuccess: overallSuccess,
      message: resultSummary,
      position: position,
      googleMapsUrl: mapUrl,
      // Messages still being confirmed are already with the radio: they count as sent here
      // (the status banner shows "sending" until the network confirms them).
      contactsSentCount: sentCount + pendingCount,
      failedContacts: failedList,
      recipientPhones: recipients,
      isPermissionDenied: !smsResult.permissionGranted,
      hasNoRecipients: localContacts.isEmpty && recipients.isEmpty,
    );
  }

  /// Dispatches offline background SMS messages to valid recipient phone numbers.
  ///
  /// With [confirmWait], waits at most that long for the network confirmations: recipients
  /// still unconfirmed are reported as pending (the messages are already with the radio), and
  /// [onConfirmed] receives the real results when the native sender finishes.
  Future<_SmsDispatchResult> _dispatchOfflineSms({
    required List<String> recipients,
    required String smsBody,
    Duration? confirmWait,
    void Function(_SmsDispatchResult confirmed)? onConfirmed,
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
      _SmsDispatchResult fromNative(List<SmsSendResult> nativeResults) {
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

      final nativeFuture = NativeSmsService.instance.send(validRecipients, smsBody);
      List<SmsSendResult>? nativeResults;
      if (confirmWait != null) {
        bool stillConfirming = false;
        nativeResults = await nativeFuture.timeout(confirmWait, onTimeout: () {
          stillConfirming = true;
          return null;
        });
        if (stillConfirming) {
          debugPrint('[EmergencyService] 📨 SMS handed to the radio; network confirmation still pending');
          unawaited(nativeFuture.then((late) {
            if (late != null) onConfirmed?.call(fromNative(late));
          }).catchError((Object _) {}));
          return _SmsDispatchResult(
            sentCount: 0,
            pendingCount: validRecipients.length,
            failedList: const [],
            hasRecipients: true,
            permissionGranted: true,
          );
        }
      } else {
        nativeResults = await nativeFuture;
      }
      if (nativeResults != null) return fromNative(nativeResults);

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
    required SosOrigin origin,
    BuildContext? context,
    String? customMessage,
  }) =>
      triggerEmergency(
        source: source,
        origin: origin,
        context: context,
        customMessage: customMessage,
      );

  /// Dispatches SMS directly with optional custom text message to active contacts
  Future<EmergencyResult> sendEmergencySMS({
    required SosOrigin origin,
    String? customMessage,
    BuildContext? context,
    String source = 'Direct SOS SMS',
  }) async {
    return triggerEmergency(
      source: source,
      origin: origin,
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
  /// With [accuracyMeters] (a coarse Wi-Fi / cell fix) the link is labelled as approximate.
  String buildSosSmsMessage({
    required String userName,
    double? latitude,
    double? longitude,
    double? accuracyMeters,
    required DateTime time,
    String? customMessage,
  }) {
    final name = userName.trim().isNotEmpty ? userName.trim() : 'A Woman Guard user';
    final intro = (customMessage != null && customMessage.trim().isNotEmpty)
        ? customMessage.trim()
        : 'EMERGENCY! $name needs help.';
    if (latitude == null || longitude == null) {
      return '$intro Live location: Location unavailable  Time: ${formatSmsTime(time)}';
    }
    final link = buildSmsMapsLink(latitude, longitude);
    final label = (accuracyMeters != null && accuracyMeters > _preciseFixMeters)
        ? 'Approx. location (within ${accuracyMeters.round()} m)'
        : 'Live location';
    return '$intro $label: $link  Time: ${formatSmsTime(time)}';
  }

  /// A GPS fix at least this accurate is sent as the live location.
  static const double _preciseFixMeters = 30;

  /// How long the SOS waits for a precise GPS fix (only when no warm fix is ready) before
  /// sending the best one it has. Kept short: the SMS must go out at once.
  static const Duration _preciseFixWait = Duration(milliseconds: 1500);

  /// How long an SOS round waits for the network to confirm its SMS before reporting back.
  /// Messages still unconfirmed by then are already with the radio (Android keeps sending them):
  /// they show as "sending" and the status updates once the real results arrive.
  static const Duration _smsConfirmWait = Duration(milliseconds: 1500);

  bool _isPrecise(Position? p) => p != null && p.accuracy > 0 && p.accuracy <= _preciseFixMeters;

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

    // 3. Instant and accurate: GPS is kept warm while the app is open ([SosLocationWarmer]), so a
    // precise fix is normally ready the moment SOS is pressed. Otherwise a fresh precise
    // last-known fix is used, and only then does it wait briefly ([_preciseFixWait]) for GPS,
    // sending the best fix it has rather than delaying the SMS.
    final Position? warm = SosLocationWarmer.instance.latestFix;
    if (warm != null && _isPrecise(warm) && _ageOf(warm) < const Duration(seconds: 60)) {
      debugPrint('[EmergencyService] Using warm GPS fix (${warm.accuracy.round()} m, ${_ageOf(warm).inSeconds}s old)');
      return warm;
    }
    Position? lastKnown;
    try {
      lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && _isPrecise(lastKnown) && _ageOf(lastKnown) < const Duration(seconds: 30)) {
        debugPrint('[EmergencyService] Using fresh last-known fix (${lastKnown.accuracy.round()} m)');
        return lastKnown;
      }
    } catch (_) {}

    // Best recent fix so far; the stream below can only improve on it.
    Position? best;
    for (final candidate in [warm, lastKnown]) {
      if (candidate == null || _ageOf(candidate) > const Duration(minutes: 2)) continue;
      final current = best;
      if (current == null || candidate.accuracy < current.accuracy) best = candidate;
    }
    // GPS already warm (a fix in the last minute) but not precise: it has been trying for a
    // while, so waiting longer would not help. Send now instead of waiting.
    final bool gpsAlreadyTried = warm != null && _ageOf(warm) < const Duration(seconds: 60);
    StreamSubscription<Position>? sub;
    final completer = Completer<Position?>();
    if (gpsAlreadyTried) completer.complete(null);
    try {
      if (!gpsAlreadyTried) {
        sub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
        ).listen(
          (p) {
            final current = best;
            if (current == null || (p.accuracy > 0 && p.accuracy < current.accuracy)) best = p;
            if (_isPrecise(p) && !completer.isCompleted) completer.complete(p);
          },
          onError: (Object e) {
            debugPrint('[EmergencyService] GPS stream notice: $e');
            if (!completer.isCompleted) completer.complete(null);
          },
        );
      }
      final precise = await completer.future.timeout(_preciseFixWait, onTimeout: () => null);
      if (precise != null) return precise;
    } catch (e) {
      debugPrint('[EmergencyService] Precise GPS notice: $e');
    } finally {
      await sub?.cancel();
    }

    // Indoors the live fix is a Wi-Fi / cell estimate (50-150 m). The phone's last real GPS
    // fix, taken under open sky up to 30 min ago, is used instead when it lies inside that
    // estimate's uncertainty circle: then it cannot be further off than the estimate itself,
    // and is usually within a few metres.
    final coarse = best ?? lastKnown;
    final gps = await SosLocationWarmer.instance.lastGpsFix();
    if (gps != null && _isPrecise(gps) && _ageOf(gps) < const Duration(minutes: 30)) {
      final agrees = coarse == null ||
          Geolocator.distanceBetween(coarse.latitude, coarse.longitude, gps.latitude, gps.longitude) <=
              coarse.accuracy;
      if (agrees) {
        debugPrint('[EmergencyService] Using last GPS fix (${gps.accuracy.round()} m, '
            '${_ageOf(gps).inMinutes} min old) inside the ${coarse?.accuracy.round()} m live estimate');
        return gps;
      }
    }

    final fallback = best;
    if (fallback != null) {
      debugPrint('[EmergencyService] No precise GPS fix${gpsAlreadyTried ? ' (GPS warm)' : ' in ${_preciseFixWait.inSeconds}s'}; '
          'using the best one (${fallback.accuracy.round()} m)');
      return fallback;
    }
    return lastKnown;
  }

  Duration _ageOf(Position p) => DateTime.now().difference(p.timestamp).abs();

  /// Checks and requests SMS permission via [permission_handler] / [telephony].
  Future<bool> _checkAndRequestSmsPermission() async {
    if (kIsWeb) return false;

    await _ensurePhoneStatePermission();

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

  /// Newer Android (16+) refuses SMS from an app without READ_PHONE_STATE: SmsManager throws
  /// "SecurityException: getSmsMmsDisabled" for every SIM. Asks for it if missing; sending is
  /// still attempted when the user declines.
  Future<void> _ensurePhoneStatePermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await Permission.phone.status;
      if (status.isGranted || status.isPermanentlyDenied) return;
      final result = await Permission.phone.request();
      debugPrint('[EmergencyService] Phone permission for SMS: ${result.name}');
    } catch (e) {
      debugPrint('[EmergencyService] Phone permission check notice: $e');
    }
  }
}
