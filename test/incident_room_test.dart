import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/incident_event_model.dart';
import 'package:smart_safety/models/safe_zone_model.dart';
import 'package:smart_safety/services/incident_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 3: IncidentEvent Model Tests', () {
    test('IncidentEvent deserializes properly from Map and assigns correct icon/color', () {
      final now = DateTime.now();
      final event = IncidentEvent.fromMap({
        'type': 'sos_triggered',
        'title': 'Emergency SOS Triggered',
        'description': 'Triggered via Shake SOS',
        'actorName': 'Test Victim',
        'actorUid': 'victim_uid_123',
        'timestamp': Timestamp.fromDate(now),
      }, id: 'event_doc_1', alertId: 'alert_123');

      expect(event.id, 'event_doc_1');
      expect(event.alertId, 'alert_123');
      expect(event.type, 'sos_triggered');
      expect(event.title, 'Emergency SOS Triggered');
      expect(event.actorName, 'Test Victim');
      expect(event.icon, Icons.emergency_rounded);
      expect(event.color, isA<Color>());
    });

    test('IncidentEvent assigns appropriate color and icon for each milestone type', () {
      final now = DateTime.now();
      final types = [
        'sos_triggered',
        'sms_dispatched',
        'guardian_viewed',
        'guardian_responding',
        'escalation_stage_1',
        'escalation_stage_2',
        'sos_resolved',
      ];

      for (final type in types) {
        final evt = IncidentEvent(
          id: 'test_$type',
          alertId: 'alert_1',
          type: type,
          title: 'Title $type',
          description: 'Desc $type',
          timestamp: now,
        );

        expect(evt.icon, isNotNull);
        expect(evt.color, isNotNull);
      }
    });

    test('IncidentEvent converts cleanly to Firestore Map', () {
      final now = DateTime.now();
      final event = IncidentEvent(
        id: 'event_1',
        alertId: 'alert_1',
        type: 'guardian_responding',
        title: 'Guardian Responding',
        description: 'Guardian confirmed response',
        actorName: 'Trusted Guardian',
        actorUid: 'guardian_uid_456',
        timestamp: now,
        metadata: {'notes': 'Coming now'},
      );

      final map = event.toMap();
      expect(map['type'], 'guardian_responding');
      expect(map['title'], 'Guardian Responding');
      expect(map['actorName'], 'Trusted Guardian');
      expect(map['actorUid'], 'guardian_uid_456');
      expect(map['timestamp'], isA<Timestamp>());
      expect(map['metadata'], {'notes': 'Coming now'});
    });
  });

  group('Phase 3: Nearest Safe Zones Tests', () {
    test('getNearestSafeZones sorts zones by proximity to user coordinates and limits count', () {
      // Banani, Dhaka: 23.7937, 90.4066
      final nearest = IncidentService.instance.getNearestSafeZones(23.7937, 90.4066, count: 3);

      expect(nearest.length, 3);
      // Verify ascending distance order
      final d0 = nearest[0].calculateDistanceKm(23.7937, 90.4066);
      final d1 = nearest[1].calculateDistanceKm(23.7937, 90.4066);
      final d2 = nearest[2].calculateDistanceKm(23.7937, 90.4066);

      expect(d0 <= d1, isTrue);
      expect(d1 <= d2, isTrue);
    });

    test('getNearestSafeZones with custom zone list correctly computes distances', () {
      const customZones = [
        SafeZone(
          id: 'z_far',
          name: 'Far Zone',
          type: SafeZoneType.police,
          latitude: 23.9000,
          longitude: 90.5000,
          icon: Icons.shield,
          iconColor: Colors.blue,
          bgColor: Colors.white,
        ),
        SafeZone(
          id: 'z_near',
          name: 'Near Zone',
          type: SafeZoneType.hospital,
          latitude: 23.7940,
          longitude: 90.4070,
          icon: Icons.local_hospital,
          iconColor: Colors.red,
          bgColor: Colors.white,
        ),
      ];

      final nearest = IncidentService.instance.getNearestSafeZones(
        23.7937,
        90.4066,
        count: 1,
        zones: customZones,
      );

      expect(nearest.length, 1);
      expect(nearest.first.id, 'z_near');
    });
  });

  group('Phase 3: Resilient Incident Timeline Synthesis Tests', () {
    test('synthesizeTimeline synthesizes missing triggeredAt event when subcollection is empty', () {
      final triggerTime = DateTime.now().subtract(const Duration(minutes: 10));
      final alertData = {
        'source': 'Shake SOS',
        'senderName': 'Jane Doe',
        'senderId': 'jane_123',
        'isDuress': false,
        'triggeredAt': Timestamp.fromDate(triggerTime),
        'status': 'active',
      };

      final timeline = IncidentService.instance.synthesizeTimeline(
        alertId: 'alert_abc',
        alertData: alertData,
        subcollectionEvents: [],
      );

      expect(timeline.length, 1);
      expect(timeline.first.type, 'sos_triggered');
      expect(timeline.first.title, 'Emergency SOS Triggered');
      expect(timeline.first.actorName, 'Jane Doe');
      expect(timeline.first.description.contains('Shake SOS'), isTrue);
    });

    test('synthesizeTimeline synthesizes silent duress warning in trigger description', () {
      final triggerTime = DateTime.now().subtract(const Duration(minutes: 5));
      final alertData = {
        'source': 'Manual SOS',
        'senderName': 'Jane Doe',
        'senderId': 'jane_123',
        'isDuress': true,
        'triggeredAt': Timestamp.fromDate(triggerTime),
        'status': 'active',
      };

      final timeline = IncidentService.instance.synthesizeTimeline(
        alertId: 'alert_abc',
        alertData: alertData,
        subcollectionEvents: [],
      );

      expect(timeline.first.description.contains('Silent Duress Flagged'), isTrue);
    });

    test('synthesizeTimeline merges subcollection events with escalationLog, acknowledgments and resolution', () {
      final t0 = DateTime(2026, 10, 24, 10, 0, 0);
      final t1 = DateTime(2026, 10, 24, 10, 3, 0);
      final t2 = DateTime(2026, 10, 24, 10, 5, 0);
      final t3 = DateTime(2026, 10, 24, 10, 10, 0);

      final alertData = {
        'source': 'SOS Button',
        'senderName': 'Victim',
        'senderId': 'vic_1',
        'triggeredAt': Timestamp.fromDate(t0),
        'status': 'resolved',
        'resolvedAt': Timestamp.fromDate(t3),
        'acknowledgedBy': ['guardian_99'],
        'acknowledgedAt': {
          'guardian_99': Timestamp.fromDate(t2),
        },
        'escalationLog': [
          {
            'level': 1,
            'timestamp': Timestamp.fromDate(t1),
            'reason': 'No guardian response in 3m',
          }
        ],
      };

      final timeline = IncidentService.instance.synthesizeTimeline(
        alertId: 'alert_full',
        alertData: alertData,
        subcollectionEvents: [],
      );

      expect(timeline.length, 4);
      expect(timeline[0].type, 'sos_triggered');
      expect(timeline[1].type, 'escalation_stage_1');
      expect(timeline[2].type, 'guardian_responding');
      expect(timeline[3].type, 'sos_resolved');

      // Verify strict chronological order
      for (int i = 0; i < timeline.length - 1; i++) {
        expect(
          timeline[i].timestamp.isBefore(timeline[i + 1].timestamp) ||
              timeline[i].timestamp.isAtSameMomentAs(timeline[i + 1].timestamp),
          isTrue,
        );
      }
    });

    test('synthesizeTimeline preserves subcollection events and avoids duplicates', () {
      final t0 = DateTime(2026, 10, 24, 12, 0, 0);

      final existingEvent = IncidentEvent(
        id: 'real_evt_1',
        alertId: 'alert_dupe',
        type: 'sos_triggered',
        title: 'Original Trigger Event',
        description: 'From subcollection',
        timestamp: t0,
      );

      final alertData = {
        'source': 'SOS Button',
        'triggeredAt': Timestamp.fromDate(t0),
        'status': 'active',
      };

      final timeline = IncidentService.instance.synthesizeTimeline(
        alertId: 'alert_dupe',
        alertData: alertData,
        subcollectionEvents: [existingEvent],
      );

      expect(timeline.length, 1);
      expect(timeline.first.id, 'real_evt_1');
      expect(timeline.first.title, 'Original Trigger Event');
    });
  });
}
