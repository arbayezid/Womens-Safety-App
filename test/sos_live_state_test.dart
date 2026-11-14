import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/emergency_service.dart';
import 'package:smart_safety/utils/duration_format.dart';

/// Covers the pieces added for the home screen's LIVE SOS state: the gate override used by
/// "Re-send" (offline re-send reuses the local alert instead of creating a second one), the
/// delivery status counts, and the elapsed-time format.
void main() {
  group('SosGate liveAlertIdOverride (home screen Re-send)', () {
    late List<String> created;
    late List<String> reRung;
    late SosGate gate;

    Future<EmergencyResult> pipeline(String? existing) async {
      if (existing == null) created.add('new_${created.length + 1}');
      return EmergencyResult(isSuccess: true, message: existing ?? 'created');
    }

    setUp(() {
      created = [];
      reRung = [];
      // Default lookup behaves like an offline manual press: Firestore unknown -> null.
      gate = SosGate(
        liveAlertId: (_) async => null,
        reRing: (id) async => reRung.add(id),
      );
    });

    test('plain manual press offline creates a new alert (unchanged behaviour)', () async {
      final result = await gate.run(SosOrigin.manual, pipeline);
      expect(result.message, 'created');
      expect(created, hasLength(1));
    });

    test('re-send with override reuses the local alert: no new document, guardians re-rung',
        () async {
      final result = await gate.run(
        SosOrigin.manual,
        pipeline,
        liveAlertIdOverride: (_) async => 'local_alert',
      );
      expect(result.message, 'local_alert');
      expect(created, isEmpty);
      expect(reRung, ['local_alert']);
    });

    test('override returning null (alert ended) creates a new alert', () async {
      final result = await gate.run(
        SosOrigin.manual,
        pipeline,
        liveAlertIdOverride: (_) async => null,
      );
      expect(result.message, 'created');
      expect(created, hasLength(1));
      expect(reRung, isEmpty);
    });
  });

  group('SosDispatchStatus', () {
    SosDispatchStatus status({bool cloudSent = false, List<String> failed = const []}) =>
        SosDispatchStatus(
          smsSent: 1,
          smsPending: 0,
          smsTotal: 1 + failed.length,
          smsFailed: failed,
          smsBody: 'EMERGENCY',
          cloudSent: cloudSent,
          composerOpened: false,
          isResend: false,
          at: DateTime(2026, 11, 14),
          reachedWithCloud: 3,
          reachedWithoutCloud: 1,
        );

    test('counts in-app guardians only once the cloud alert exists', () {
      expect(status().contactsReached, 1);
      expect(status(cloudSent: true).contactsReached, 3);
      expect(status().copyWith(cloudSent: true).contactsReached, 3);
    });

    test('needs attention only while some SMS recipients were not reached', () {
      expect(status().smsNeedsAttention, isFalse);
      expect(status(failed: ['+8801700000000']).smsNeedsAttention, isTrue);
    });
  });

  group('formatElapsedClock', () {
    test('mm:ss below an hour, h:mm:ss from an hour', () {
      expect(formatElapsedClock(Duration.zero), '00:00');
      expect(formatElapsedClock(const Duration(minutes: 2, seconds: 15)), '02:15');
      expect(formatElapsedClock(const Duration(hours: 1, minutes: 2, seconds: 5)), '1:02:05');
    });

    test('negative durations show 00:00', () {
      expect(formatElapsedClock(const Duration(seconds: -5)), '00:00');
    });
  });
}
