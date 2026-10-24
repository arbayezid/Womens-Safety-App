import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../core/app_colors.dart';

/// Represents a single discrete milestone or activity event in the Emergency Incident Room timeline.
class IncidentEvent {
  final String id;
  final String alertId;
  final String type;
  final String title;
  final String description;
  final String? actorName;
  final String? actorUid;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  const IncidentEvent({
    required this.id,
    required this.alertId,
    required this.type,
    required this.title,
    required this.description,
    this.actorName,
    this.actorUid,
    required this.timestamp,
    this.metadata,
  });

  /// Factory constructor to deserialize an [IncidentEvent] from Firestore doc data.
  factory IncidentEvent.fromMap(Map<String, dynamic> map, {required String id, required String alertId}) {
    DateTime parsedTime = DateTime.now();
    final rawTs = map['timestamp'];
    if (rawTs is Timestamp) {
      parsedTime = rawTs.toDate();
    } else if (rawTs is String) {
      parsedTime = DateTime.tryParse(rawTs) ?? DateTime.now();
    } else if (rawTs is int) {
      parsedTime = DateTime.fromMillisecondsSinceEpoch(rawTs);
    }

    return IncidentEvent(
      id: id,
      alertId: alertId,
      type: (map['type'] ?? 'general').toString(),
      title: (map['title'] ?? 'Timeline Event').toString(),
      description: (map['description'] ?? '').toString(),
      actorName: map['actorName']?.toString(),
      actorUid: map['actorUid']?.toString(),
      timestamp: parsedTime,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }

  /// Converts this [IncidentEvent] to a map for Firestore serialization.
  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'title': title,
      'description': description,
      'actorName': actorName,
      'actorUid': actorUid,
      'timestamp': Timestamp.fromDate(timestamp),
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// Icon visual representation corresponding to this event type.
  IconData get icon {
    switch (type) {
      case 'sos_triggered':
        return Icons.emergency_rounded;
      case 'sms_dispatched':
        return Icons.sms_rounded;
      case 'guardian_viewed':
        return Icons.visibility_rounded;
      case 'guardian_responding':
        return Icons.handshake_rounded;
      case 'escalation_stage_1':
        return Icons.escalator_warning_rounded;
      case 'escalation_stage_2':
        return Icons.notifications_active_rounded;
      case 'sos_resolved':
        return Icons.check_circle_rounded;
      default:
        return Icons.circle_notifications_rounded;
    }
  }

  /// Accent color for the event node on the timeline.
  Color get color {
    switch (type) {
      case 'sos_triggered':
      case 'escalation_stage_2':
        return AppColors.sosRed;
      case 'escalation_stage_1':
        return AppColors.actionOrange;
      case 'guardian_responding':
      case 'sos_resolved':
        return AppColors.safeGreen;
      case 'guardian_viewed':
      case 'sms_dispatched':
      default:
        return AppColors.primary;
    }
  }
}
