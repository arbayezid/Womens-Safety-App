import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/journey_model.dart';
import 'package:smart_safety/screens/followed_mode_screen.dart';
import 'package:smart_safety/services/journey_guardian_alerts.dart';
import 'package:smart_safety/services/journey_service.dart';
import 'package:smart_safety/services/safety_deadline_service.dart';

/// Followed Mode behaviour: silent 5-minute check-ins, an SOS taking the session over,
/// never ending on a timer while the user answers, and guardians shown as watching.
void main() {
  final now = DateTime(2026, 11, 20, 21, 0);

  Map<String, dynamic> doc({
    String status = 'active',
    String mode = 'followed',
    DateTime? startedAt,
    DateTime? updatedAt,
    String? linkedSosAlertId,
    bool duress = false,
    Map<String, dynamic>? watchers,
  }) =>
      {
        'ownerId': 'owner',
        'ownerName': 'Ayesha',
        'status': status,
        'mode': mode,
        'destination': {'label': 'Followed Mode (No fixed destination)'},
        'startedAt': Timestamp.fromDate(startedAt ?? now.subtract(const Duration(minutes: 1))),
        'expectedArrivalAt': Timestamp.fromDate(now.add(const Duration(hours: 2))),
        'lastUpdatedAt': Timestamp.fromDate(updatedAt ?? now.subtract(const Duration(minutes: 1))),
        if (linkedSosAlertId != null) 'linkedSosAlertId': linkedSosAlertId,
        if (duress) 'linkedSosDuress': true,
        if (watchers != null) 'watchers': watchers,
      };

  JourneyGuardianEvent? eventFor(Map<String, dynamic> data) =>
      journeyGuardianEvent(journeyId: 'j1', data: data, myUid: 'guardian', now: now);

  group('check-ins', () {
    test('Followed Mode checks in every 5 minutes', () {
      expect(followedCheckInterval, const Duration(minutes: 5));
      expect(
        JourneyService.evaluateFollowedCheck(
          now: now,
          lastCheckOrStart: now.subtract(const Duration(minutes: 5)),
          isCooldownActive: false,
        ),
        isTrue,
      );
    });

    test('the check-in trigger is the Followed Mode one', () {
      expect(JourneyService.followedCheckTrigger.type, JourneySafetyTriggerType.followedCheck);
      expect(JourneyService.followedCheckTrigger.reason, contains('5 minutes'));
    });
  });

  group('never ends on a timer while the user answers', () {
    test('Followed Mode with recent check-ins is not stale, even after 8 hours', () {
      expect(
        JourneyService.isStaleJourney(
          followed: true,
          startedAt: now.subtract(const Duration(hours: 8)),
          lastSafetyCheckAt: now.subtract(const Duration(minutes: 3)),
          now: now,
        ),
        isFalse,
      );
    });

    test('Followed Mode with no check-in for over 6 hours is stale', () {
      expect(
        JourneyService.isStaleJourney(
          followed: true,
          startedAt: now.subtract(const Duration(hours: 7)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a Safe Journey still goes stale 6 hours after it started', () {
      expect(
        JourneyService.isStaleJourney(
          followed: false,
          startedAt: now.subtract(const Duration(hours: 7)),
          lastSafetyCheckAt: now.subtract(const Duration(minutes: 3)),
          now: now,
        ),
        isTrue,
      );
    });

    test('guardians keep seeing a long Followed Mode session that is still updating', () {
      expect(
        isJourneyLiveForGuardian(
          data: doc(startedAt: now.subtract(const Duration(hours: 8))),
          myUid: 'guardian',
          now: now,
        ),
        isTrue,
      );
      expect(
        isJourneyLiveForGuardian(
          data: doc(
            startedAt: now.subtract(const Duration(hours: 8)),
            updatedAt: now.subtract(const Duration(hours: 7)),
          ),
          myUid: 'guardian',
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('guardian notifications', () {
    test('start is an urgent heads-up', () {
      expect(eventFor(doc())!.title, 'Ayesha thinks they are being followed');
    });

    test('an alert taken over by an SOS is not announced twice', () {
      expect(eventFor(doc(status: 'alert', linkedSosAlertId: 'sos1')), isNull);
    });

    test('a missed check-in without an SOS is named as such', () {
      expect(eventFor(doc(status: 'alert'))!.title, 'Ayesha missed a Followed Mode check-in');
    });

    test('ending says they are safe, not that they arrived', () {
      final e = eventFor(doc(status: 'arrived'))!;
      expect(e.title, 'Ayesha is safe');
      expect(e.body, 'Followed Mode has ended.');
    });
  });

  group('journey model', () {
    test('watchers are listed earliest first, with a fallback name', () {
      final j = JourneyModel.fromMap(
        doc(watchers: {
          'g2': {'name': 'Karim', 'at': Timestamp.fromDate(now.subtract(const Duration(minutes: 1)))},
          'g1': {'name': 'Rahim', 'at': Timestamp.fromDate(now.subtract(const Duration(minutes: 4)))},
          'g3': {'name': '', 'at': Timestamp.fromDate(now)},
        }),
        'j1',
      );
      expect(j.watcherNames, ['Rahim', 'Karim', 'A guardian']);
    });

    test('a duress SOS is kept through copyWith', () {
      final j = JourneyModel.fromMap(doc(status: 'alert', linkedSosAlertId: 'sos1', duress: true), 'j1');
      expect(j.linkedSosDuress, isTrue);
      expect(j.copyWith(batteryLevel: 40).linkedSosDuress, isTrue);
      expect(JourneyModel.fromMap(doc(), 'j2').linkedSosDuress, isFalse);
    });
  });

  group('who is watching', () {
    test('wording for none, one, two and more guardians', () {
      expect(followedWatchersHeadline([]), 'Guardians alerted. Waiting for one to open your location');
      expect(followedWatchersHeadline(['Rahim']), 'Rahim is watching your location');
      expect(followedWatchersHeadline(['Rahim', 'Karim']), 'Rahim and Karim are watching your location');
      expect(
        followedWatchersHeadline(['Rahim', 'Karim', 'Nadia']),
        'Rahim and 2 others are watching your location',
      );
    });
  });
}
