import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';
import '../models/activity_model.dart';
import 'activity_service.dart';
import 'contact_service.dart';
import 'emergency_service.dart';
import 'notification_service.dart';

/// Configuration timing and thresholds for Smart SOS Escalation.
class EscalationConfig {
  final int stage1Seconds; // Default 180s (3 minutes)
  final int stage2Seconds; // Default 480s (8 minutes)

  const EscalationConfig({
    this.stage1Seconds = 180,
    this.stage2Seconds = 480,
  });
}

/// Stage state of the SOS escalation engine.
enum EscalationStage {
  stage0Initial,
  stage1BackupAlerted,
  stage2EmergencyServicesPrompted,
  resolved,
}

/// Central Singleton Service managing the Smart SOS Escalation Engine.
///
/// If primary emergency contacts do not acknowledge an SOS alert:
/// - Stage 0 (t=0 min): Alert regular contacts only.
/// - Stage 1 (t=3 min): If no guardian has acknowledged (`acknowledgedBy` empty),
///   alerts backup contacts via SMS and in-app cloud alert, and sends an SMS update
///   to regular contacts.
/// - Stage 2 (t=8 min): If still unacknowledged, sends a final SMS round and prompts
///   the sender with a high-priority notification to call 999.
/// - Stops immediately when any guardian acknowledges or the alert is resolved.
class SosEscalationService {
  SosEscalationService._internal();

  /// Central singleton instance
  static final SosEscalationService instance = SosEscalationService._internal();

  Telephony? _telephonyInstance;
  Telephony get _telephony => _telephonyInstance ??= Telephony.instance;

  EscalationConfig _config = const EscalationConfig();
  EscalationConfig get config => _config;

  /// Custom override for config (useful for testing)
  void setConfig(EscalationConfig newConfig) {
    _config = newConfig;
  }

  static const String prefKeyEscalationEnabled = 'pref_smart_escalation_enabled';
  static const String prefKeyStage1Delay = 'pref_escalation_stage1_minutes';
  static const String prefKeyStage2Delay = 'pref_escalation_stage2_minutes';

  Timer? _stage1Timer;
  Timer? _stage2Timer;
  StreamSubscription<DocumentSnapshot>? _alertSub;

  String? _activeAlertId;
  String? _senderName;
  String? _mapsUrl;

  final ValueNotifier<EscalationStage> currentStageNotifier =
      ValueNotifier<EscalationStage>(EscalationStage.stage0Initial);

  /// Synchronously returns whether an escalation sequence is actively running
  bool get isEscalating => _activeAlertId != null;

  /// Queries whether Smart Escalation is enabled in settings (default true)
  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKeyEscalationEnabled) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Sets whether Smart Escalation is enabled
  Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKeyEscalationEnabled, enabled);
    } catch (_) {}
  }

  /// Starts the multi-stage escalation engine for an active SOS alert
  Future<void> startEscalation({
    required String alertId,
    required String senderName,
    String? mapsUrl,
  }) async {
    stopEscalation();

    final enabled = await isEnabled();
    if (!enabled) {
      debugPrint('[SosEscalation] Smart SOS Escalation disabled in settings. Skipping.');
      return;
    }

    _activeAlertId = alertId;
    _senderName = senderName;
    _mapsUrl = mapsUrl;
    currentStageNotifier.value = EscalationStage.stage0Initial;

    debugPrint('[SosEscalation] ⏳ Escalation engine started for SOS alert: $alertId');

    // Load custom stage delays if configured in preferences
    int stage1Sec = _config.stage1Seconds;
    int stage2Sec = _config.stage2Seconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom1 = prefs.getInt(prefKeyStage1Delay);
      if (custom1 != null && custom1 > 0) stage1Sec = custom1 * 60;
      final custom2 = prefs.getInt(prefKeyStage2Delay);
      if (custom2 != null && custom2 > 0) stage2Sec = custom2 * 60;
    } catch (_) {}

    // 1. Listen reactively to the Firestore sos_alerts doc
    _attachDocListener(alertId);

    // 2. Schedule Stage 1 escalation (default 3 min)
    _stage1Timer = Timer(Duration(seconds: stage1Sec), () async {
      await _executeStage1(alertId);
    });

    // 3. Schedule Stage 2 escalation (default 8 min)
    _stage2Timer = Timer(Duration(seconds: stage2Sec), () async {
      await _executeStage2(alertId);
    });
  }

  /// Listens to the alert document in Firestore.
  /// If any guardian acknowledges (`acknowledgedBy` not empty) or the alert resolves, stops immediately.
  void _attachDocListener(String alertId) {
    if (Firebase.apps.isEmpty) return;

    try {
      _alertSub = FirebaseFirestore.instance
          .collection('sos_alerts')
          .doc(alertId)
          .snapshots()
          .listen((snap) {
        if (!snap.exists) return;
        final data = snap.data();
        if (data == null) return;

        // Check if resolved
        if (data['status'] == 'resolved') {
          debugPrint('[SosEscalation] Alert $alertId was resolved. Stopping escalation.');
          stopEscalation();
          return;
        }

        // Check if acknowledged by any guardian
        final acknowledgedBy = data['acknowledgedBy'] as List<dynamic>?;
        if (acknowledgedBy != null && acknowledgedBy.isNotEmpty) {
          debugPrint('[SosEscalation] ✅ Guardian acknowledged alert ($acknowledgedBy). Escalation halted.');
          stopEscalation();
        }
      }, onError: (e) {
        debugPrint('[SosEscalation] Document listener warning: $e');
      });
    } catch (e) {
      debugPrint('[SosEscalation] Attach listener error: $e');
    }
  }

  /// Stage 1 Escalation: No response after 3 minutes
  Future<void> _executeStage1(String alertId) async {
    if (_activeAlertId != alertId) return;

    debugPrint('[SosEscalation] ⚠️ STAGE 1 ESCALATION: 3 minutes elapsed with no guardian response.');
    currentStageNotifier.value = EscalationStage.stage1BackupAlerted;

    final contacts = await ContactService.instance.getContacts();
    final backupContacts = contacts.where((c) => c.isBackup).toList();
    final regularContacts = contacts.where((c) => !c.isBackup).toList();

    final name = _senderName ?? 'User';
    final locationUrl = _mapsUrl ?? 'Location tracking active in app';

    // 1. Alert Backup Contacts via SMS
    for (final backup in backupContacts) {
      if (backup.hasPhone) {
        final formattedPhone = EmergencyService.instance.formatRecipientPhone(backup.phone);
        if (formattedPhone.isNotEmpty) {
          final msg =
              'EMERGENCY ESCALATION: $name triggered SOS. Primary contacts have not responded after 3 minutes. You are alerted as backup. Location: $locationUrl';
          try {
            await _telephony.sendSms(to: formattedPhone, message: msg, isMultipart: false);
            debugPrint('[SosEscalation] ✉️ Sent Stage 1 backup SMS to $formattedPhone');
          } catch (e) {
            debugPrint('[SosEscalation] Failed sending backup SMS to $formattedPhone: $e');
          }
        }
      }
    }

    // 2. Resend update SMS to regular contacts
    for (final reg in regularContacts) {
      if (reg.hasPhone) {
        final formattedPhone = EmergencyService.instance.formatRecipientPhone(reg.phone);
        if (formattedPhone.isNotEmpty) {
          final updateMsg =
              'UPDATE: No one has responded to $name\'s emergency SOS yet. Current location: $locationUrl';
          try {
            await _telephony.sendSms(to: formattedPhone, message: updateMsg, isMultipart: false);
          } catch (e) {
            debugPrint('[SosEscalation] Failed sending update SMS to $formattedPhone: $e');
          }
        }
      }
    }

    // 3. Update Firestore sos_alerts document with backup recipients and escalation log
    if (Firebase.apps.isNotEmpty) {
      try {
        final backupUids = backupContacts
            .map((c) => c.contactUid)
            .where((uid) => uid != null && uid.isNotEmpty && !uid.startsWith('offline_'))
            .cast<String>()
            .toList();
        final backupEmails = backupContacts
            .map((c) => c.email.trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toList();

        final updates = <String, dynamic>{
          'escalationLevel': 1,
          'lastUpdatedAt': FieldValue.serverTimestamp(),
          'escalationLog': FieldValue.arrayUnion([
            {
              'level': 1,
              'timestamp': Timestamp.now(),
              'reason': 'No guardian response within 3 minutes',
              'backupContactsAlertedCount': backupContacts.length,
            }
          ]),
        };

        if (backupUids.isNotEmpty) {
          updates['recipientUids'] = FieldValue.arrayUnion(backupUids);
        }
        if (backupEmails.isNotEmpty) {
          updates['recipientEmails'] = FieldValue.arrayUnion(backupEmails);
        }

        await FirebaseFirestore.instance
            .collection('sos_alerts')
            .doc(alertId)
            .update(updates);
      } catch (e) {
        debugPrint('[SosEscalation] Error updating Firestore for Stage 1: $e');
      }
    }

    // 4. Log activity
    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.sos,
        title: 'SOS Escalated (Stage 1)',
        subtitle: 'No guardian response in 3 min. Notified backup contacts.',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Stage 2 Escalation: No response after 8 minutes
  Future<void> _executeStage2(String alertId) async {
    if (_activeAlertId != alertId) return;

    debugPrint('[SosEscalation] 🚨 STAGE 2 ESCALATION: 8 minutes elapsed with no guardian response.');
    currentStageNotifier.value = EscalationStage.stage2EmergencyServicesPrompted;

    final contacts = await ContactService.instance.getContacts();
    final name = _senderName ?? 'User';
    final locationUrl = _mapsUrl ?? 'Location tracking active in app';

    // 1. Final SMS round to all contacts (regular + backup)
    for (final contact in contacts) {
      if (contact.hasPhone) {
        final formattedPhone = EmergencyService.instance.formatRecipientPhone(contact.phone);
        if (formattedPhone.isNotEmpty) {
          final urgentMsg =
              'URGENT UPDATE: 8 minutes with no guardian response. $name needs emergency assistance immediately! Location: $locationUrl';
          try {
            await _telephony.sendSms(to: formattedPhone, message: urgentMsg, isMultipart: false);
          } catch (e) {
            debugPrint('[SosEscalation] Failed sending Stage 2 SMS to $formattedPhone: $e');
          }
        }
      }
    }

    // 2. High-priority local notification on the sender's device prompting to call 999
    NotificationService.instance.showStatusNotification(
      id: 9991,
      title: '🚨 No Guardian Has Responded',
      body: '8 minutes have passed without a response. Tap here to call 999 Emergency Services.',
    );

    // 3. Update Firestore document
    if (Firebase.apps.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('sos_alerts').doc(alertId).update({
          'escalationLevel': 2,
          'lastUpdatedAt': FieldValue.serverTimestamp(),
          'escalationLog': FieldValue.arrayUnion([
            {
              'level': 2,
              'timestamp': Timestamp.now(),
              'reason': 'No guardian response within 8 minutes. Emergency services prompted.',
            }
          ]),
        });
      } catch (e) {
        debugPrint('[SosEscalation] Error updating Firestore for Stage 2: $e');
      }
    }

    // 4. Log activity
    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.sos,
        title: 'Emergency Services Prompted (Stage 2)',
        subtitle: 'No guardian response in 8 min. Prompted 999 emergency call.',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Cancels all ongoing timers and listeners for escalation
  void stopEscalation() {
    _stage1Timer?.cancel();
    _stage1Timer = null;
    _stage2Timer?.cancel();
    _stage2Timer = null;
    _alertSub?.cancel();
    _alertSub = null;
    _activeAlertId = null;
    _senderName = null;
    _mapsUrl = null;
    currentStageNotifier.value = EscalationStage.resolved;
  }
}
