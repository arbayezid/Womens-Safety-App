import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/safety_deadline_service.dart';

void main() {
  final start = DateTime(2026, 11, 3, 18, 0);

  group('nextJourneyCheckAt', () {
    test('Safe Journey: 5 min after ETA plus the backstop offset', () {
      final eta = start.add(const Duration(minutes: 30));
      expect(
        nextJourneyCheckAt(followed: false, startedAt: start, expectedArrivalAt: eta),
        eta.add(const Duration(minutes: 5)).add(deadlineBackstopOffset),
      );
    });

    test('Safe Journey: never sooner than 10 min after the last confirmed check', () {
      final eta = start.add(const Duration(minutes: 30));
      final confirmed = eta.add(const Duration(minutes: 6)); // confirmed during the delay check
      expect(
        nextJourneyCheckAt(
            followed: false, startedAt: start, expectedArrivalAt: eta, lastSafetyCheckAt: confirmed),
        confirmed.add(const Duration(minutes: 10)).add(deadlineBackstopOffset),
      );
    });

    test('Safe Journey: an older check-in does not delay the ETA check', () {
      final eta = start.add(const Duration(minutes: 30));
      final confirmed = start.add(const Duration(minutes: 2));
      expect(
        nextJourneyCheckAt(
            followed: false, startedAt: start, expectedArrivalAt: eta, lastSafetyCheckAt: confirmed),
        eta.add(const Duration(minutes: 5)).add(deadlineBackstopOffset),
      );
    });

    test('Followed Mode: every 10 min from start, then from the last check-in', () {
      final eta = start.add(const Duration(hours: 2));
      expect(
        nextJourneyCheckAt(followed: true, startedAt: start, expectedArrivalAt: eta),
        start.add(const Duration(minutes: 10)).add(deadlineBackstopOffset),
      );
      final confirmed = start.add(const Duration(minutes: 11));
      expect(
        nextJourneyCheckAt(
            followed: true, startedAt: start, expectedArrivalAt: eta, lastSafetyCheckAt: confirmed),
        confirmed.add(const Duration(minutes: 10)).add(deadlineBackstopOffset),
      );
    });

    test('backstop fires after the in-app 30 s monitor tick would have detected it', () {
      expect(deadlineBackstopOffset > const Duration(seconds: 30), isTrue);
    });
  });

  group('ride and SOS deadlines', () {
    test('ride overdue = expected minutes + 10 min grace + backstop offset', () {
      expect(
        rideOverdueAt(createdAt: start, expectedMinutes: 25),
        start.add(const Duration(minutes: 35)).add(deadlineBackstopOffset),
      );
    });

    test('SOS stage backstops fire after the in-app stage timers', () {
      expect(sosStageAt(startedAt: start, stageSeconds: 180),
          start.add(const Duration(seconds: 180)).add(sosStageBackstopOffset));
      expect(sosStageAt(startedAt: start, stageSeconds: 480),
          start.add(const Duration(seconds: 480)).add(sosStageBackstopOffset));
    });

    test('deadline ids are distinct per kind and object', () {
      final ids = {
        journeyDeadlineId('x'),
        rideDeadlineId('x'),
        sosStageDeadlineId('x', 1),
        sosStageDeadlineId('x', 2),
      };
      expect(ids.length, 4);
    });
  });

  group('SafetyDeadline serialization', () {
    test('native arguments carry epoch millis and flags', () {
      final d = SafetyDeadline(
        id: 'sos1_a',
        kind: SafetyDeadlineKind.sosStage1,
        refId: 'a',
        uid: 'u',
        fireAt: start,
        direct: true,
      );
      final args = d.toArgs(replace: true);
      expect(args['fireAt'], start.millisecondsSinceEpoch);
      expect(args['direct'], isTrue);
      expect(args['replace'], isTrue);
      expect(args['promptSeconds'], 60);
    });

    test('non-Android hosts: claim always succeeds so in-app escalation is unchanged', () async {
      expect(await SafetyDeadlineService.instance.claim('journey_x'), isTrue);
      expect(await SafetyDeadlineService.instance.claim('journey_x'), isTrue);
    });
  });
}
