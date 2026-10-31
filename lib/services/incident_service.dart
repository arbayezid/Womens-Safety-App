import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../models/incident_event_model.dart';
import '../models/safe_zone_model.dart';
import 'safe_zone_repository.dart';

/// Central singleton service providing incident timeline logging, subcollection event streaming,
/// resilient offline milestone synthesis, and geographic safe zone queries for the Emergency Incident Room.
class IncidentService {
  IncidentService._internal();

  /// Central singleton instance
  static final IncidentService instance = IncidentService._internal();

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  /// Logs a new discrete timeline event into `sos_alerts/{alertId}/events`.
  Future<void> logEvent({
    required String alertId,
    required String type,
    required String title,
    required String description,
    String? actorName,
    String? actorUid,
    Map<String, dynamic>? metadata,
  }) async {
    if (alertId.isEmpty) return;

    try {
      if (Firebase.apps.isNotEmpty) {
        await _firestore
            .collection('sos_alerts')
            .doc(alertId)
            .collection('events')
            .add({
          'type': type,
          'title': title,
          'description': description,
          'actorName': actorName,
          'actorUid': actorUid,
          'timestamp': FieldValue.serverTimestamp(),
          if (metadata != null) 'metadata': metadata,
        }).timeout(const Duration(seconds: 3));
        debugPrint('[IncidentService] 📝 Logged incident event "$type" for alert $alertId');
      }
    } catch (e) {
      debugPrint('[IncidentService] Notice logging incident event: $e');
    }
  }

  /// Streams real-time timeline events for the specified [alertId] from Firestore.
  Stream<List<IncidentEvent>> streamEvents(String alertId) {
    if (alertId.isEmpty || Firebase.apps.isEmpty) {
      return Stream.value([]);
    }

    return _firestore
        .collection('sos_alerts')
        .doc(alertId)
        .collection('events')
        .snapshots()
        .map((snapshot) {
      final events = snapshot.docs.map((doc) {
        return IncidentEvent.fromMap(doc.data(), id: doc.id, alertId: alertId);
      }).toList();

      events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return events;
    });
  }

  /// Synthesizes and merges subcollection events with milestone fields recorded on
  /// the main alert document (e.g. `triggeredAt`, `escalationLog`, `acknowledgedAt`, `resolvedAt`).
  ///
  /// Guarantees that even if subcollection writes were skipped or offline, the timeline
  /// always accurately displays the complete progression of the emergency.
  List<IncidentEvent> synthesizeTimeline({
    required String alertId,
    required Map<String, dynamic> alertData,
    List<IncidentEvent> subcollectionEvents = const [],
  }) {
    final Map<String, IncidentEvent> unifiedMap = {};

    // 1. Add subcollection events first
    for (final evt in subcollectionEvents) {
      final key = '${evt.type}_${evt.actorUid ?? ''}_${evt.timestamp.millisecondsSinceEpoch ~/ 1000}';
      unifiedMap[key] = evt;
    }

    // 2. Synthesize Trigger Event if not already present
    final hasTriggerEvent = unifiedMap.values.any((e) => e.type == 'sos_triggered');
    if (!hasTriggerEvent) {
      final rawTriggerTime = alertData['triggeredAt'] ?? alertData['timestamp'];
      DateTime triggerTime = DateTime.now();
      if (rawTriggerTime is Timestamp) {
        triggerTime = rawTriggerTime.toDate();
      } else if (rawTriggerTime is String) {
        triggerTime = DateTime.tryParse(rawTriggerTime) ?? DateTime.now();
      }

      final source = alertData['source']?.toString() ?? 'SOS Button';
      final senderName = alertData['senderName'] ?? alertData['sender_name'] ?? 'User';
      final isDuress = (alertData['isDuress'] as bool?) ?? false;

      unifiedMap['synthetic_sos_triggered'] = IncidentEvent(
        id: 'synthetic_triggered',
        alertId: alertId,
        type: 'sos_triggered',
        title: 'Emergency SOS Triggered',
        description: isDuress
            ? 'Emergency SOS triggered via $source (Silent Duress Flagged)'
            : 'Emergency SOS triggered via $source',
        actorName: senderName.toString(),
        actorUid: alertData['senderId']?.toString() ?? alertData['sender_uid']?.toString(),
        timestamp: triggerTime,
      );
    }

    // 3. Synthesize Escalation Logs from alert document
    final escalationLog = alertData['escalationLog'];
    if (escalationLog is List) {
      for (int i = 0; i < escalationLog.length; i++) {
        final entry = escalationLog[i];
        if (entry is Map) {
          final level = entry['level'] as num? ?? 1;
          final type = 'escalation_stage_$level';
          final hasThisEscalation = unifiedMap.values.any((e) => e.type == type);
          if (!hasThisEscalation) {
            DateTime ts = DateTime.now();
            final rawTs = entry['timestamp'];
            if (rawTs is Timestamp) {
              ts = rawTs.toDate();
            }

            unifiedMap['synthetic_$type'] = IncidentEvent(
              id: 'synthetic_$type',
              alertId: alertId,
              type: type,
              title: level == 1
                  ? 'Escalated to Stage 1 (Backup Contacts)'
                  : 'Escalated to Stage 2 (Emergency 999 Services)',
              description: entry['reason']?.toString() ?? 'Escalated due to unacknowledged emergency.',
              timestamp: ts,
            );
          }
        }
      }
    }

    // 4. Synthesize Guardian Acknowledgments ("I'm Responding")
    final acknowledgedBy = (alertData['acknowledgedBy'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final acknowledgedAtMap = alertData['acknowledgedAt'] as Map?;

    for (final uid in acknowledgedBy) {
      final hasAckEvent = unifiedMap.values.any((e) => e.type == 'guardian_responding' && e.actorUid == uid);
      if (!hasAckEvent) {
        DateTime ackTime = DateTime.now();
        if (acknowledgedAtMap != null && acknowledgedAtMap[uid] is Timestamp) {
          ackTime = (acknowledgedAtMap[uid] as Timestamp).toDate();
        }

        unifiedMap['synthetic_guardian_responding_$uid'] = IncidentEvent(
          id: 'synthetic_ack_$uid',
          alertId: alertId,
          type: 'guardian_responding',
          title: 'Guardian Responding',
          description: 'Guardian acknowledged the alert and confirmed response.',
          actorUid: uid,
          timestamp: ackTime,
        );
      }
    }

    // 5. Synthesize Resolved Event if alert status is resolved
    final status = (alertData['status'] ?? '').toString().toLowerCase();
    if (status == 'resolved') {
      final hasResolvedEvent = unifiedMap.values.any((e) => e.type == 'sos_resolved');
      if (!hasResolvedEvent) {
        DateTime resTime = DateTime.now();
        final rawResTime = alertData['resolvedAt'];
        if (rawResTime is Timestamp) {
          resTime = rawResTime.toDate();
        }

        unifiedMap['synthetic_sos_resolved'] = IncidentEvent(
          id: 'synthetic_resolved',
          alertId: alertId,
          type: 'sos_resolved',
          title: 'Emergency Resolved ("I\'m Safe")',
          description: 'Sender confirmed safety. Live tracking halted.',
          timestamp: resTime,
        );
      }
    }

    // Convert map to list and sort chronologically (oldest first)
    final result = unifiedMap.values.toList();
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  /// Calculates and returns the [count] closest safe zones to [lat, lng],
  /// sorted in ascending order of proximity.
  List<SafeZone> getNearestSafeZones(
    double lat,
    double lng, {
    int count = 3,
    List<SafeZone>? zones,
  }) {
    if (zones != null) {
      final list = List<SafeZone>.from(zones);
      list.sort((a, b) => a.calculateDistanceKm(lat, lng).compareTo(b.calculateDistanceKm(lat, lng)));
      return list.take(count).toList();
    }
    return SafeZoneRepository.instance.getNearestSafeZones(
      curLat: lat,
      curLng: lng,
      count: count,
    );
  }
}
