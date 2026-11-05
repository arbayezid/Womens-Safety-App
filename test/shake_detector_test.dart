import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/shake_sos_service.dart';

void main() {
  final t0 = DateTime(2026, 11, 6, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  // Total acceleration ~2.7g (a hard shake) and ~1g (resting / walking).
  bool hard(ShakeDetector d, int ms) => d.processSample(timestamp: at(ms), x: 26.5, y: 0, z: 0);
  bool calm(ShakeDetector d, int ms) => d.processSample(timestamp: at(ms), x: 0, y: 0, z: 9.81);

  group('ShakeDetector', () {
    test('three distinct hard shakes inside the window trigger', () {
      final d = ShakeDetector();
      expect(hard(d, 0), isFalse);
      expect(hard(d, 300), isFalse);
      expect(hard(d, 600), isTrue);
    });

    test('normal movement never triggers', () {
      final d = ShakeDetector();
      for (var ms = 0; ms < 5000; ms += 20) {
        expect(calm(d, ms), isFalse);
      }
      // Brisk walking peaks (~1.5g) stay under the threshold.
      for (var ms = 0; ms < 5000; ms += 350) {
        expect(d.processSample(timestamp: at(ms), x: 0, y: 0, z: 14.7), isFalse);
      }
    });

    test('peaks of one swing count once', () {
      final d = ShakeDetector();
      for (var ms = 0; ms <= 200; ms += 20) {
        expect(hard(d, ms), isFalse);
      }
      expect(d.pendingShakes, 1);
    });

    test('shakes spread too far apart do not trigger', () {
      final d = ShakeDetector();
      expect(hard(d, 0), isFalse);
      expect(hard(d, 1000), isFalse);
      expect(hard(d, 2000), isFalse); // the first shake has left the 1.5 s window
      expect(hard(d, 2300), isTrue); // 1000, 2000, 2300 are inside it
    });

    test('cooldown blocks a second trigger right after the first', () {
      final d = ShakeDetector();
      hard(d, 0);
      hard(d, 300);
      expect(hard(d, 600), isTrue);
      expect(hard(d, 900), isFalse);
      expect(hard(d, 1200), isFalse);
      expect(hard(d, 1500), isFalse);
      // After the 10 s cooldown it works again.
      hard(d, 11000);
      hard(d, 11300);
      expect(hard(d, 11600), isTrue);
    });
  });
}
