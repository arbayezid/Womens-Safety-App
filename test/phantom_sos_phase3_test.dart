import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/emergency_service.dart';
import 'package:smart_safety/services/notification_service.dart';
import 'package:smart_safety/services/sos_cloud_dispatcher.dart';

void main() {
  final now = DateTime(2026, 11, 6, 23);

  group('Every alert ends (row 7)', () {
    test('alerts live for 2 hours from creation, re-alert or last location update', () {
      expect(sosAlertLifetime, const Duration(hours: 2));
    });

    test('a stored alert counts as live only while active and not expired', () {
      Timestamp at(Duration d) => Timestamp.fromDate(now.add(d));
      expect(EmergencyService.isAlertDocLive({'status': 'active'}, now), isTrue,
          reason: 'alerts created before expiresAt existed');
      expect(EmergencyService.isAlertDocLive({'status': 'active', 'expiresAt': at(const Duration(minutes: 30))}, now),
          isTrue);
      expect(EmergencyService.isAlertDocLive({'status': 'active', 'expiresAt': at(const Duration(minutes: -1))}, now),
          isFalse);
      expect(EmergencyService.isAlertDocLive({'status': 'resolved'}, now), isFalse);
      expect(EmergencyService.isAlertDocLive(null, now), isFalse, reason: 'deleted document');
    });
  });

  group('Origin shown to guardians', () {
    test('automatic alerts are labelled with their source', () {
      expect(
        NotificationService.automaticAlertLabel('JOURNEY_SOS'),
        'Automatic alert: no response to a safety check (JOURNEY_SOS)',
      );
      expect(NotificationService.automaticAlertLabel(null), 'Automatic alert: no response to a safety check');
    });
  });
}
