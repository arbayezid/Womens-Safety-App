import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/widgets/signal_lost_banner.dart';

void main() {
  final now = DateTime(2026, 11, 21, 12, 0);
  Timestamp ago(int minutes) => Timestamp.fromDate(now.subtract(Duration(minutes: minutes)));

  group('sosSignalSilence', () {
    test('null while the sender is still reporting', () {
      final data = {'status': 'active', 'liveUpdatedAt': ago(2), 'triggeredAt': ago(30)};
      expect(sosSignalSilence(data, now: now), isNull);
    });

    test('reports silence once the last update is older than the threshold', () {
      final data = {'status': 'active', 'liveUpdatedAt': ago(6), 'triggeredAt': ago(30)};
      expect(sosSignalSilence(data, now: now), const Duration(minutes: 6));
    });

    test('falls back to the trigger time when tracking never wrote', () {
      expect(sosSignalSilence({'status': 'active', 'triggeredAt': ago(5)}, now: now),
          const Duration(minutes: 5));
      expect(sosSignalSilence({'status': 'active', 'triggeredAt': ago(1)}, now: now), isNull);
    });

    test('never shown for a resolved alert', () {
      final data = {'status': 'resolved', 'liveUpdatedAt': ago(60)};
      expect(sosSignalSilence(data, now: now), isNull);
    });

    test('null when no time is known yet (pending server timestamp)', () {
      expect(sosSignalSilence({'status': 'active'}, now: now), isNull);
      expect(sosSignalSilence(null, now: now), isNull);
    });
  });
}
