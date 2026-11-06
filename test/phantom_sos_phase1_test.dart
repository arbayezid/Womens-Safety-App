import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/emergency_service.dart';
import 'package:smart_safety/services/esp32_ble_service.dart';
import 'package:smart_safety/services/journey_service.dart';
import 'package:smart_safety/services/safety_deadline_service.dart';

/// Stands in for SosCloudDispatcher + Firestore: counts alert documents and re-rings.
class _FakeDispatcher {
  final List<String> docs = [];
  final Map<String, int> ringSeq = {};
  String? live;
  bool failReRing = false;

  Future<String?> liveAlertId(SosOrigin origin) async => live;

  Future<void> reRing(String alertId) async {
    if (failReRing) throw Exception('permission-denied');
    ringSeq[alertId] = (ringSeq[alertId] ?? 0) + 1;
  }

  /// The SOS pipeline: creates a document only when there is no live alert.
  Future<EmergencyResult> pipeline(String? existingAlertId, {Duration work = Duration.zero}) async {
    await Future<void>.delayed(work);
    if (existingAlertId == null) {
      final id = 'alert_${docs.length + 1}';
      docs.add(id);
      ringSeq[id] = 0;
      live = id;
    }
    return EmergencyResult(isSuccess: true, message: existingAlertId ?? 'created');
  }
}

List<int> _bytes(String s) => utf8.encode(s);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Row 9: ESP32 packet parser ignores noise', () {
    late SosPacketFilter filter;
    final t0 = DateTime(2026, 11, 6, 22);

    setUp(() {
      filter = SosPacketFilter()..onConnected(t0);
    });

    test('BAT:91, 1, 0x01, HELP and READY never trigger', () {
      final now = t0.add(const Duration(seconds: 10));
      for (final packet in [_bytes('BAT:91'), _bytes('1'), [0x01], _bytes('HELP'), _bytes('READY')]) {
        expect(filter.accept(packet, now), isFalse, reason: 'packet $packet');
      }
      expect(filter.accept(const [], now), isFalse);
    });

    test('text that merely contains SOS does not trigger', () {
      final now = t0.add(const Duration(seconds: 10));
      expect(filter.accept(_bytes('SOS_TEST'), now), isFalse);
      expect(filter.accept(_bytes('NO SOS'), now), isFalse);
      expect(filter.accept(_bytes('SOS:'), now), isFalse);
      expect(filter.accept(_bytes('SOS:12a'), now), isFalse);
    });

    test('exact SOS and SOS:<n> trigger once settled', () {
      expect(filter.accept(_bytes('SOS'), t0.add(const Duration(seconds: 10))), isTrue);
      final other = SosPacketFilter()..onConnected(t0);
      expect(other.accept(_bytes(' sos:7 '), t0.add(const Duration(seconds: 10))), isTrue);
    });

    test('packets in the first 3 s after connecting are ignored', () {
      expect(filter.accept(_bytes('SOS'), t0.add(const Duration(seconds: 2))), isFalse);
      expect(filter.accept(_bytes('SOS'), t0.add(const Duration(seconds: 3))), isTrue);
    });

    test('nothing triggers while disconnected', () {
      final idle = SosPacketFilter();
      expect(idle.accept(_bytes('SOS'), t0), isFalse);
      filter.onDisconnected();
      expect(filter.accept(_bytes('SOS'), t0.add(const Duration(minutes: 5))), isFalse);
    });

    test('30 s cooldown between hardware triggers', () {
      final first = t0.add(const Duration(seconds: 10));
      expect(filter.accept(_bytes('SOS'), first), isTrue);
      expect(filter.accept(_bytes('SOS'), first.add(const Duration(seconds: 29))), isFalse);
      expect(filter.accept(_bytes('SOS'), first.add(const Duration(seconds: 31))), isTrue);
    });

    test('a repeated sequence number is ignored, a new one is accepted', () {
      final first = t0.add(const Duration(seconds: 10));
      expect(filter.accept(_bytes('SOS:5'), first), isTrue);
      expect(filter.accept(_bytes('SOS:5'), first.add(const Duration(minutes: 2))), isFalse);
      expect(filter.accept(_bytes('SOS:6'), first.add(const Duration(minutes: 2))), isTrue);
    });

    test('the sequence is reset on reconnect', () {
      expect(filter.accept(_bytes('SOS:5'), t0.add(const Duration(seconds: 10))), isTrue);
      final reconnect = t0.add(const Duration(minutes: 5));
      filter.onConnected(reconnect);
      expect(filter.accept(_bytes('SOS:5'), reconnect.add(const Duration(seconds: 5))), isTrue);
    });

    test('packets longer than 32 bytes are ignored', () {
      final long = _bytes('SOS'.padRight(33));
      expect(long.length, greaterThan(32));
      expect(filter.accept(long, t0.add(const Duration(seconds: 10))), isFalse);
    });
  });

  group('Row 10: pairing filter and test button', () {
    test('only a device exposing the safety service may be paired', () {
      expect(Esp32BleService.exposesSafetyService(const []), isFalse);
      expect(
        Esp32BleService.exposesSafetyService(const [
          '0000180f-0000-1000-8000-00805f9b34fb', // battery only (earbuds, watch)
          '0000fe2c-0000-1000-8000-00805f9b34fb',
        ]),
        isFalse,
      );
      expect(
        Esp32BleService.exposesSafetyService([Esp32BleService.serviceUuid.toUpperCase()]),
        isTrue,
      );
      // ESP32_SOS firmware: Nordic UART Service + Battery Service
      expect(
        Esp32BleService.exposesSafetyService(const [
          '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
          '0000180f-0000-1000-8000-00805f9b34fb',
        ]),
        isTrue,
      );
    });

    test('the test button is a parser dry run and creates no alert', () {
      expect(Esp32BleService.instance.runHardwareTestDryRun(), isTrue);
      expect(EmergencyService.instance.activeAlertId, isNull);
    });
  });

  group('Rows 1-2: one SOS gate', () {
    late _FakeDispatcher fake;
    late SosGate gate;

    setUp(() {
      fake = _FakeDispatcher();
      gate = SosGate(liveAlertId: fake.liveAlertId, reRing: fake.reRing);
    });

    test('row 1: one manual press creates exactly one document', () async {
      final result = await gate.run(SosOrigin.manual, fake.pipeline);
      expect(result.isSuccess, isTrue);
      expect(fake.docs, ['alert_1']);
      expect(fake.ringSeq['alert_1'], 0);
    });

    test('row 2: five presses in 3 s still create one document', () async {
      final presses = <Future<EmergencyResult>>[];
      for (var i = 0; i < 5; i++) {
        presses.add(gate.run(
          SosOrigin.manual,
          (id) => fake.pipeline(id, work: const Duration(milliseconds: 200)),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future.wait(presses);
      expect(fake.docs, hasLength(1));
      expect(fake.ringSeq['alert_1']!, lessThanOrEqualTo(4));
    });

    test('row 2: presses after the first finished re-ring the live alert, no new document', () async {
      await gate.run(SosOrigin.manual, fake.pipeline);
      final reSent = <String?>[];
      for (var i = 0; i < 4; i++) {
        await gate.run(SosOrigin.manual, (id) {
          reSent.add(id);
          return fake.pipeline(id);
        });
      }
      expect(fake.docs, hasLength(1));
      expect(fake.ringSeq['alert_1'], 4);
      expect(reSent, everyElement('alert_1'), reason: 'each press re-sends the SMS round');
    });

    test('an automatic trigger on a live alert does nothing', () async {
      await gate.run(SosOrigin.manual, fake.pipeline);
      var pipelineCalls = 0;
      final result = await gate.run(SosOrigin.automatic, (id) {
        pipelineCalls++;
        return fake.pipeline(id);
      });
      expect(result.message, 'SOS already active');
      expect(pipelineCalls, 0);
      expect(fake.docs, hasLength(1));
      expect(fake.ringSeq['alert_1'], 0);
    });

    test('an automatic trigger with no live alert creates one document', () async {
      await gate.run(SosOrigin.automatic, fake.pipeline);
      expect(fake.docs, ['alert_1']);
    });

    test('a failed re-ring still re-sends the SMS round', () async {
      await gate.run(SosOrigin.manual, fake.pipeline);
      fake.failReRing = true;
      String? reSentFor;
      await gate.run(SosOrigin.manual, (id) {
        reSentFor = id;
        return fake.pipeline(id);
      });
      expect(reSentFor, 'alert_1');
      expect(fake.docs, hasLength(1));
    });

    test('after the alert ends, the next press creates a new document', () async {
      await gate.run(SosOrigin.manual, fake.pipeline);
      fake.live = null; // sender tapped "I'm safe" or the alert expired
      await gate.run(SosOrigin.manual, fake.pipeline);
      expect(fake.docs, ['alert_1', 'alert_2']);
    });

    test('the in-flight lock is released after an error', () async {
      final failing = Completer<EmergencyResult>();
      final first = gate.run(SosOrigin.manual, (_) => failing.future);
      failing.completeError(Exception('boom'));
      await expectLater(first, throwsException);
      await gate.run(SosOrigin.manual, fake.pipeline);
      expect(fake.docs, ['alert_1']);
    });
  });

  group('Rows 13-14: stale sessions and late alarms', () {
    final now = DateTime(2026, 11, 6, 8);

    test('a journey or ride older than 6 h is stale', () {
      expect(JourneyService.isStaleSession(now.subtract(const Duration(hours: 7)), now), isTrue);
      expect(JourneyService.isStaleSession(now.subtract(const Duration(hours: 5)), now), isFalse);
    });

    test('a deadline due more than 30 min ago is late', () {
      int ms(Duration ago) => now.subtract(ago).millisecondsSinceEpoch;
      expect(
        SafetyDeadlineService.isLateDeadline({'state': 'armed', 'fireAt': ms(const Duration(hours: 1))}, now),
        isTrue,
      );
      expect(
        SafetyDeadlineService.isLateDeadline({'state': 'armed', 'fireAt': ms(const Duration(minutes: 10))}, now),
        isFalse,
      );
      // While prompting, the due time is escalateAt, not the original fireAt.
      expect(
        SafetyDeadlineService.isLateDeadline({
          'state': 'prompting',
          'fireAt': ms(const Duration(hours: 3)),
          'escalateAt': ms(const Duration(seconds: 5)),
        }, now),
        isFalse,
      );
      expect(
        SafetyDeadlineService.isLateDeadline({
          'state': 'prompting',
          'fireAt': ms(const Duration(hours: 3)),
          'escalateAt': ms(const Duration(hours: 1)),
        }, now),
        isTrue,
      );
      expect(SafetyDeadlineService.isLateDeadline(const {'state': 'armed'}, now), isFalse);
    });
  });
}
