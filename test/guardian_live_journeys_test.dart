import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/journey_model.dart';
import 'package:smart_safety/services/journey_guardian_alerts.dart';
import 'package:smart_safety/services/notification_service.dart';

/// The guardian's home screen lists protected contacts' journeys that are still underway, so
/// they can be tracked after the "started a Safe Journey" notification was dismissed.
void main() {
  final now = DateTime(2026, 11, 8, 0, 46);

  Map<String, dynamic> journey({
    String status = 'active',
    String ownerId = 'owner',
    Duration startedAgo = const Duration(minutes: 1),
    Duration updatedAgo = const Duration(minutes: 1),
    String? mode,
  }) =>
      {
        'ownerId': ownerId,
        'ownerName': 'Abdur Rahman Bayezid',
        'ownerPhone': '+8801700000000',
        'status': status,
        'guardianUids': ['guardian'],
        'destination': {'label': 'Delta Medical College & Hospital', 'latitude': 23.79, 'longitude': 90.35},
        'startLocation': {'latitude': 23.77, 'longitude': 90.34},
        'startedAt': Timestamp.fromDate(now.subtract(startedAgo)),
        'expectedArrivalAt': Timestamp.fromDate(now.add(const Duration(minutes: 26))),
        'lastUpdatedAt': Timestamp.fromDate(now.subtract(updatedAgo)),
        if (mode != null) 'mode': mode,
      };

  bool live(Map<String, dynamic> data, {String me = 'guardian'}) =>
      isJourneyLiveForGuardian(data: data, myUid: me, now: now);

  group('isJourneyLiveForGuardian', () {
    test('an active journey of a protected contact is live', () {
      expect(live(journey()), isTrue);
    });

    test('the traveller does not see their own journey as incoming', () {
      expect(live(journey(), me: 'owner'), isFalse);
    });

    test('a recent safety-check alert stays visible', () {
      expect(live(journey(status: 'alert', updatedAgo: const Duration(hours: 2))), isTrue);
      expect(live(journey(status: 'alert', updatedAgo: const Duration(hours: 4))), isFalse);
    });

    test('ended journeys are not live', () {
      expect(live(journey(status: 'arrived')), isFalse);
      expect(live(journey(status: 'cancelled')), isFalse);
    });

    test('an abandoned session older than the start window is not live', () {
      expect(live(journey(startedAgo: const Duration(hours: 7))), isFalse);
    });

    test('a document without an owner is ignored', () {
      expect(live(journey()..remove('ownerId')), isFalse);
    });
  });

  group('activeGuardianJourneys', () {
    test('keeps only live journeys, most urgent first, then newest', () {
      final list = NotificationService.activeGuardianJourneys(
        {
          'older': journey(startedAgo: const Duration(minutes: 30)),
          'newer': journey(startedAgo: const Duration(minutes: 5)),
          'followed': journey(mode: 'followed', startedAgo: const Duration(minutes: 40)),
          'alert': journey(status: 'alert', startedAgo: const Duration(minutes: 50)),
          'done': journey(status: 'arrived'),
          'mine': journey(ownerId: 'guardian'),
        },
        myUid: 'guardian',
        now: now,
      );
      expect(list.map((j) => j.id), ['alert', 'followed', 'newer', 'older']);
      expect(list.first.status, JourneyStatus.alert);
      expect(list.last.destinationLabel, 'Delta Medical College & Hospital');
      expect(list.last.ownerPhone, '+8801700000000');
    });

    test('nothing to show when no protected contact is travelling', () {
      expect(NotificationService.activeGuardianJourneys({}, myUid: 'guardian', now: now), isEmpty);
    });
  });
}
