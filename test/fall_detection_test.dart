import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/motion_detection_service.dart';

void main() {
  group('FallDetectionEngine Pure State Machine Tests', () {
    late FallDetectionEngine engine;
    const g = 9.81;

    setUp(() {
      engine = FallDetectionEngine(
        config: const FallDetectionConfig(
          gravity: g,
          freeFallThresholdG: 0.5, // < 4.905 m/s^2
          freeFallDurationMs: 80,
          impactThresholdG: 2.5, // > 24.525 m/s^2
          impactWindowMs: 1000,
          stillnessVarianceThresholdG: 0.3, // between 6.867 and 12.753 m/s^2
          stillnessDurationMs: 2000,
          stillnessWindowMs: 5000,
          cooldownSeconds: 60,
        ),
      );
    });

    test('calculateMagnitude returns Euclidean norm accurately', () {
      final mag = FallDetectionEngine.calculateMagnitude(3.0, 4.0, 0.0);
      expect(mag, closeTo(5.0, 0.001));

      final gravityMag = FallDetectionEngine.calculateMagnitude(0.0, 0.0, 9.81);
      expect(gravityMag, closeTo(9.81, 0.001));
    });

    test('Normal walking does not trigger fall detection', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);

      // Walking: rhythmic acceleration varying around 1g (7 m/s^2 to 14 m/s^2)
      for (int i = 0; i < 100; i++) {
        final t = now.add(Duration(milliseconds: i * 50));
        final mag = g + (i % 2 == 0 ? 3.0 : -2.5);
        final detected = engine.processSample(timestamp: t, magnitude: mag);
        expect(detected, isFalse);
        expect(engine.currentStage, FallDetectionStage.monitoring);
      }
    });

    test('Hard drop onto a surface with immediate bounce/movement does not trigger fall detection', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);

      // Free-fall for 100ms
      engine.processSample(timestamp: now, magnitude: 2.0);
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 50)), magnitude: 2.0);
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 100)), magnitude: 2.0);
      expect(engine.currentStage, FallDetectionStage.freeFall);

      // Impact spike 3.0g
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 150)), magnitude: 30.0);
      expect(engine.currentStage, FallDetectionStage.impactDetected);

      // Picked up immediately (chaotic movement, no stillness)
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 300)), magnitude: 18.0);
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 600)), magnitude: 4.0);
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 900)), magnitude: 20.0);

      expect(engine.currentStage, isNot(FallDetectionStage.monitoring)); // still within stillness window
      // Past 5s stillness window without continuous stillness -> resets to monitoring
      final lateSample = engine.processSample(
        timestamp: now.add(const Duration(milliseconds: 5500)),
        magnitude: g,
      );
      expect(lateSample, isFalse);
      expect(engine.currentStage, FallDetectionStage.monitoring);
    });

    test('Complete 3-stage fall pattern triggers confirmed fall detection', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);

      // Stage 1: Free fall for 150ms (< 0.5g)
      expect(engine.processSample(timestamp: now, magnitude: 2.0), isFalse);
      expect(engine.processSample(timestamp: now.add(const Duration(milliseconds: 50)), magnitude: 2.0), isFalse);
      expect(engine.processSample(timestamp: now.add(const Duration(milliseconds: 100)), magnitude: 2.0), isFalse);
      expect(engine.processSample(timestamp: now.add(const Duration(milliseconds: 150)), magnitude: 2.0), isFalse);
      expect(engine.currentStage, FallDetectionStage.freeFall);

      // Stage 2: Impact spike 200ms later (3.2g > 2.5g)
      expect(
        engine.processSample(timestamp: now.add(const Duration(milliseconds: 350)), magnitude: 32.0),
        isFalse,
      );
      expect(engine.currentStage, FallDetectionStage.impactDetected);

      // Stage 3: Post-impact stillness for >= 2000ms (|a| within 1g +- 0.3g)
      DateTime postImpact = now.add(const Duration(milliseconds: 400));
      bool fallConfirmed = false;

      // Feed stillness samples every 100ms for 2200ms
      for (int i = 0; i <= 22; i++) {
        final t = postImpact.add(Duration(milliseconds: i * 100));
        final detected = engine.processSample(timestamp: t, magnitude: g + 0.5); // 10.31 m/s^2, within stillness
        if (detected) {
          fallConfirmed = true;
          break;
        }
      }

      expect(fallConfirmed, isTrue);
      expect(engine.currentStage, FallDetectionStage.monitoring);
      expect(engine.lastFallDetectedTime, isNotNull);
    });

    test('Cooldown period suppresses detection for 60 seconds after a fall', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);

      // Complete fall
      engine.processSample(timestamp: now, magnitude: 2.0);
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 100)), magnitude: 2.0);
      engine.processSample(timestamp: now.add(const Duration(milliseconds: 200)), magnitude: 30.0);

      for (int i = 0; i <= 22; i++) {
        final t = now.add(Duration(milliseconds: 300 + i * 100));
        if (engine.processSample(timestamp: t, magnitude: g)) break;
      }
      expect(engine.lastFallDetectedTime, isNotNull);

      // Attempt immediate second fall 10 seconds later
      final secondFallStart = now.add(const Duration(seconds: 10));
      final detected = engine.processSample(timestamp: secondFallStart, magnitude: 1.0);
      expect(detected, isFalse);
      expect(engine.currentStage, FallDetectionStage.monitoring);

      // After 65 seconds (62.7s after detection at t=2.3s), new fall can be detected
      final thirdFallStart = now.add(const Duration(seconds: 65));
      engine.processSample(timestamp: thirdFallStart, magnitude: 1.0);
      engine.processSample(timestamp: thirdFallStart.add(const Duration(milliseconds: 100)), magnitude: 1.0);
      expect(engine.currentStage, FallDetectionStage.freeFall);
    });
  });
}
