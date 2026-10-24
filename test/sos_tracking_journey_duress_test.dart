import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/battery_alert_service.dart';
import 'package:smart_safety/services/journey_service.dart';
import 'package:smart_safety/services/live_tracking_service.dart';
import 'package:smart_safety/services/pin_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────────────────────────────────────────────────
  // 1. LIVE TRACKING SERVICE LOGIC TESTS
  // ─────────────────────────────────────────────────────────────
  group('LiveTrackingService Logic Tests', () {
    final baseTime = DateTime(2026, 10, 24, 12, 0, 0);
    const originLat = 23.7925; // Dhaka Banani
    const originLng = 90.4078;

    test('shouldWriteUpdate: allows initial update when lastWriteTime is null', () {
      final shouldWrite = LiveTrackingService.shouldWriteUpdate(
        lastWriteTime: null,
        lastLat: null,
        lastLng: null,
        now: baseTime,
        currentLat: originLat,
        currentLng: originLng,
      );
      expect(shouldWrite, isTrue);
    });

    test('shouldWriteUpdate: suppresses update if elapsed < 30 seconds even with significant movement', () {
      // User moved 100 meters, but only 15 seconds have passed
      final shouldWrite = LiveTrackingService.shouldWriteUpdate(
        lastWriteTime: baseTime,
        lastLat: originLat,
        lastLng: originLng,
        now: baseTime.add(const Duration(seconds: 15)),
        currentLat: originLat + 0.001, // ~111m
        currentLng: originLng + 0.001,
      );
      expect(shouldWrite, isFalse);
    });

    test('shouldWriteUpdate: triggers heartbeat update if elapsed >= 120s even if stationary', () {
      final shouldWrite = LiveTrackingService.shouldWriteUpdate(
        lastWriteTime: baseTime,
        lastLat: originLat,
        lastLng: originLng,
        now: baseTime.add(const Duration(seconds: 121)),
        currentLat: originLat, // exactly 0 meters moved
        currentLng: originLng,
      );
      expect(shouldWrite, isTrue);
    });

    test('shouldWriteUpdate: triggers update when moved >= 25m and elapsed >= 30s', () {
      // 0.00035 degrees latitude is ~38.9 meters (well over 25m)
      final shouldWrite = LiveTrackingService.shouldWriteUpdate(
        lastWriteTime: baseTime,
        lastLat: originLat,
        lastLng: originLng,
        now: baseTime.add(const Duration(seconds: 35)),
        currentLat: originLat + 0.00035,
        currentLng: originLng,
      );
      expect(shouldWrite, isTrue);
    });

    test('shouldWriteUpdate: suppresses update when elapsed >= 30s but moved < 25m and < 120s', () {
      // 0.00005 degrees latitude is ~5.5 meters
      final shouldWrite = LiveTrackingService.shouldWriteUpdate(
        lastWriteTime: baseTime,
        lastLat: originLat,
        lastLng: originLng,
        now: baseTime.add(const Duration(seconds: 45)),
        currentLat: originLat + 0.00005,
        currentLng: originLng,
      );
      expect(shouldWrite, isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 2. BATTERY ALERT SERVICE LOGIC TESTS
  // ─────────────────────────────────────────────────────────────
  group('BatteryAlertService Logic Tests', () {
    test('shouldTriggerAlert: triggers when battery <= 10%, not charging, not dispatched, and enabled', () {
      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 10,
          isCharging: false,
          hasDispatched: false,
          isEnabled: true,
        ),
        isTrue,
      );

      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 5,
          isCharging: false,
          hasDispatched: false,
          isEnabled: true,
        ),
        isTrue,
      );
    });

    test('shouldTriggerAlert: does not trigger if battery > 10%', () {
      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 11,
          isCharging: false,
          hasDispatched: false,
          isEnabled: true,
        ),
        isFalse,
      );

      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 80,
          isCharging: false,
          hasDispatched: false,
          isEnabled: true,
        ),
        isFalse,
      );
    });

    test('shouldTriggerAlert: does not trigger if device is currently charging', () {
      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 7,
          isCharging: true,
          hasDispatched: false,
          isEnabled: true,
        ),
        isFalse,
      );
    });

    test('shouldTriggerAlert: does not trigger if already dispatched for this session', () {
      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 4,
          isCharging: false,
          hasDispatched: true,
          isEnabled: true,
        ),
        isFalse,
      );
    });

    test('shouldTriggerAlert: does not trigger if feature is disabled', () {
      expect(
        BatteryAlertService.shouldTriggerAlert(
          batteryLevel: 8,
          isCharging: false,
          hasDispatched: false,
          isEnabled: false,
        ),
        isFalse,
      );
    });

    test('shouldResetHysteresis: resets when recharged above 20%', () {
      expect(BatteryAlertService.shouldResetHysteresis(batteryLevel: 21), isTrue);
      expect(BatteryAlertService.shouldResetHysteresis(batteryLevel: 50), isTrue);
      expect(BatteryAlertService.shouldResetHysteresis(batteryLevel: 20), isFalse);
      expect(BatteryAlertService.shouldResetHysteresis(batteryLevel: 12), isFalse);
    });

    test('formatBatterySmsMessage: formats concise, cost-effective single-segment SMS', () {
      final msgWithGps = BatteryAlertService.formatBatterySmsMessage(
        userName: 'Ayesha',
        batteryLevel: 9,
        mapUrl: 'https://maps.google.com/?q=23.7925,90.4078',
      );
      expect(msgWithGps, contains("Ayesha's phone battery is critical (9%)"));
      expect(msgWithGps, contains('Last known GPS: https://maps.google.com/?q=23.7925,90.4078'));

      final msgNoGps = BatteryAlertService.formatBatterySmsMessage(
        userName: '',
        batteryLevel: 6,
        mapUrl: null,
      );
      expect(msgNoGps, contains("Emergency Contact's phone battery is critical (6%)"));
      expect(msgNoGps, contains('GPS unavailable'));
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 3. JOURNEY SERVICE MATH & TRIGGER TESTS
  // ─────────────────────────────────────────────────────────────
  group('JourneyService Math & Trigger Tests', () {
    // Banani: 23.7937, 90.4066
    // Gulshan 2: 23.7925, 90.4150
    const bananiLat = 23.7937;
    const bananiLon = 90.4066;
    const gulshan2Lat = 23.7925;
    const gulshan2Lon = 90.4150;

    test('haversineDistance calculates accurate distance between coordinates', () {
      final distIdentical = JourneyService.haversineDistance(
        bananiLat,
        bananiLon,
        bananiLat,
        bananiLon,
      );
      expect(distIdentical, closeTo(0.0, 0.01));

      final distBananiToGulshan2 = JourneyService.haversineDistance(
        bananiLat,
        bananiLon,
        gulshan2Lat,
        gulshan2Lon,
      );
      // Distance between Banani 11 and Gulshan 2 is approximately 860 meters
      expect(distBananiToGulshan2, inInclusiveRange(800.0, 920.0));
    });

    test('crossTrackDistance calculates perpendicular distance to path line segment', () {
      // Point directly on the line between (0, 0) and (0, 1) has cross track distance ~0
      final onTrackDist = JourneyService.crossTrackDistance(
        pointLat: 0.0,
        pointLon: 0.5,
        startLat: 0.0,
        startLon: 0.0,
        destLat: 0.0,
        destLon: 1.0,
      );
      expect(onTrackDist, closeTo(0.0, 1.0));

      // Point offset 0.003 degrees latitude (~333 meters north)
      final offTrackDist = JourneyService.crossTrackDistance(
        pointLat: 0.003,
        pointLon: 0.5,
        startLat: 0.0,
        startLon: 0.0,
        destLat: 0.0,
        destLon: 1.0,
      );
      expect(offTrackDist, inInclusiveRange(320.0, 345.0));
    });

    test('estimateWalkingDurationMinutes estimates walking time at 5 km/h', () {
      // 1000m at 5 km/h = 1/5 hr = 12 minutes
      expect(JourneyService.estimateWalkingDurationMinutes(1000.0), equals(12));
      // 500m = 6 minutes
      expect(JourneyService.estimateWalkingDurationMinutes(500.0), equals(6));
      // 0m returns minimum 1 minute
      expect(JourneyService.estimateWalkingDurationMinutes(0.0), equals(1));
    });

    test('isArrived returns true when within 100m of destination', () {
      expect(
        JourneyService.isArrived(
          currentLat: gulshan2Lat,
          currentLon: gulshan2Lon,
          destLat: gulshan2Lat,
          destLon: gulshan2Lon,
        ),
        isTrue,
      );

      // Point ~50 meters away
      expect(
        JourneyService.isArrived(
          currentLat: gulshan2Lat + 0.00045,
          currentLon: gulshan2Lon,
          destLat: gulshan2Lat,
          destLon: gulshan2Lon,
        ),
        isTrue,
      );

      // Point ~500 meters away
      expect(
        JourneyService.isArrived(
          currentLat: gulshan2Lat + 0.0045,
          currentLon: gulshan2Lon,
          destLat: gulshan2Lat,
          destLon: gulshan2Lon,
        ),
        isFalse,
      );
    });

    test('hasConsecutiveDistanceIncreases detects when user is steadily moving away', () {
      final increasing = [100.0, 120.0, 150.0, 190.0, 240.0];
      expect(JourneyService.hasConsecutiveDistanceIncreases(increasing, 4), isTrue);

      final decreasing = [500.0, 450.0, 400.0, 350.0, 300.0];
      expect(JourneyService.hasConsecutiveDistanceIncreases(decreasing, 4), isFalse);

      final stagnant = [200.0, 201.0, 202.0, 201.0, 200.0];
      expect(JourneyService.hasConsecutiveDistanceIncreases(stagnant, 4), isFalse);
    });

    test('evaluateSafetyTriggers: detects GPS Lost after 5 minutes without fix', () {
      final now = DateTime(2026, 10, 24, 14, 10, 0);
      final trigger = JourneyService.evaluateSafetyTriggers(
        now: now,
        startedAt: now.subtract(const Duration(minutes: 20)),
        expectedArrivalAt: now.add(const Duration(minutes: 10)),
        lastLocationTime: now.subtract(const Duration(minutes: 6)), // 6 min old
        distanceToDest: 500.0,
        crossTrackDist: 50.0,
        distanceMovedInLast10Min: 150.0,
        recentDistancesToDest: [600.0, 550.0, 500.0],
        cooldowns: {},
      );

      expect(trigger, isNotNull);
      expect(trigger!.type, equals(JourneySafetyTriggerType.gpsLost));
      expect(trigger.title, equals('GPS Signal Lost'));
    });

    test('evaluateSafetyTriggers: detects arrival delay past ETA + 5min grace', () {
      final now = DateTime(2026, 10, 24, 14, 30, 0);
      final expectedArrival = now.subtract(const Duration(minutes: 6)); // 6 min past ETA
      final trigger = JourneyService.evaluateSafetyTriggers(
        now: now,
        startedAt: now.subtract(const Duration(minutes: 35)),
        expectedArrivalAt: expectedArrival,
        lastLocationTime: now.subtract(const Duration(seconds: 15)),
        distanceToDest: 400.0,
        crossTrackDist: 40.0,
        distanceMovedInLast10Min: 200.0,
        recentDistancesToDest: [500.0, 450.0, 400.0],
        cooldowns: {},
      );

      expect(trigger, isNotNull);
      expect(trigger!.type, equals(JourneySafetyTriggerType.delay));
      expect(trigger.title, equals('Arrival Delay Detected'));
    });

    test('evaluateSafetyTriggers: detects route deviation when cross-track > 500m', () {
      final now = DateTime(2026, 10, 24, 14, 15, 0);
      final trigger = JourneyService.evaluateSafetyTriggers(
        now: now,
        startedAt: now.subtract(const Duration(minutes: 15)),
        expectedArrivalAt: now.add(const Duration(minutes: 15)),
        lastLocationTime: now.subtract(const Duration(seconds: 20)),
        distanceToDest: 600.0,
        crossTrackDist: 550.0, // > 500m deviation
        distanceMovedInLast10Min: 250.0,
        recentDistancesToDest: [700.0, 650.0, 600.0],
        cooldowns: {},
      );

      expect(trigger, isNotNull);
      expect(trigger!.type, equals(JourneySafetyTriggerType.deviation));
      expect(trigger.title, equals('Route Deviation Detected'));
    });

    test('evaluateSafetyTriggers: detects inactivity when moved < 30m in 10 minutes', () {
      final now = DateTime(2026, 10, 24, 14, 25, 0);
      final trigger = JourneyService.evaluateSafetyTriggers(
        now: now,
        startedAt: now.subtract(const Duration(minutes: 20)),
        expectedArrivalAt: now.add(const Duration(minutes: 10)),
        lastLocationTime: now.subtract(const Duration(seconds: 10)),
        distanceToDest: 500.0,
        crossTrackDist: 30.0,
        distanceMovedInLast10Min: 12.0, // moved only 12m
        recentDistancesToDest: [500.0, 500.0, 500.0],
        cooldowns: {},
      );

      expect(trigger, isNotNull);
      expect(trigger!.type, equals(JourneySafetyTriggerType.inactivity));
      expect(trigger.title, equals('Prolonged Inactivity Detected'));
    });

    test('evaluateSafetyTriggers: suppresses trigger when on cooldown', () {
      final now = DateTime(2026, 10, 24, 14, 15, 0);
      // Deviation fired 3 minutes ago
      final cooldowns = {
        JourneySafetyTriggerType.deviation: now.subtract(const Duration(minutes: 3)),
      };

      final trigger = JourneyService.evaluateSafetyTriggers(
        now: now,
        startedAt: now.subtract(const Duration(minutes: 15)),
        expectedArrivalAt: now.add(const Duration(minutes: 15)),
        lastLocationTime: now.subtract(const Duration(seconds: 20)),
        distanceToDest: 600.0,
        crossTrackDist: 550.0,
        distanceMovedInLast10Min: 250.0,
        recentDistancesToDest: [700.0, 650.0, 600.0],
        cooldowns: cooldowns,
      );

      expect(trigger, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 4. PIN SECURITY & CRYPTO TESTS
  // ─────────────────────────────────────────────────────────────
  group('PinSecurityService Pure Crypto & Logic Tests', () {
    test('generateSalt produces non-empty secure base64 salt', () {
      final salt1 = PinSecurityService.generateSalt();
      final salt2 = PinSecurityService.generateSalt();
      expect(salt1, isNotEmpty);
      expect(salt2, isNotEmpty);
      expect(salt1, isNot(equals(salt2)));
    });

    test('hashPin produces deterministic salted SHA-256 hash', () {
      const pin = '1234';
      const salt = 'random_salt_123';

      final hash1 = PinSecurityService.hashPin(pin, salt);
      final hash2 = PinSecurityService.hashPin(pin, salt);

      expect(hash1, equals(hash2));
      expect(hash1.length, equals(64)); // 256 bits = 64 hex characters
      expect(hash1, isNot(contains(pin))); // Cleartext PIN is never stored
    });

    test('hashPin produces different hashes for different salts or PINs', () {
      final h1 = PinSecurityService.hashPin('1234', 'salt_a');
      final h2 = PinSecurityService.hashPin('1234', 'salt_b');
      final h3 = PinSecurityService.hashPin('5678', 'salt_a');

      expect(h1, isNot(equals(h2)));
      expect(h1, isNot(equals(h3)));
    });

    test('verifyHash verifies correct PIN and rejects incorrect PIN', () {
      const pin = '4321';
      final salt = PinSecurityService.generateSalt();
      final hash = PinSecurityService.hashPin(pin, salt);

      expect(PinSecurityService.verifyHash(enteredPin: '4321', salt: salt, storedHash: hash), isTrue);
      expect(PinSecurityService.verifyHash(enteredPin: '9999', salt: salt, storedHash: hash), isFalse);
      expect(PinSecurityService.verifyHash(enteredPin: '', salt: salt, storedHash: hash), isFalse);
    });

    test('evaluatePin distinguishes between Real PIN, Duress PIN, and Invalid PIN', () {
      const realPin = '1122';
      const duressPin = '9900';

      final realSalt = PinSecurityService.generateSalt();
      final realHash = PinSecurityService.hashPin(realPin, realSalt);

      final duressSalt = PinSecurityService.generateSalt();
      final duressHash = PinSecurityService.hashPin(duressPin, duressSalt);

      // 1. Test Real PIN entered
      final resultReal = PinSecurityService.evaluatePin(
        enteredPin: realPin,
        realSalt: realSalt,
        realHash: realHash,
        duressSalt: duressSalt,
        duressHash: duressHash,
      );
      expect(resultReal, equals(PinVerificationResult.real));

      // 2. Test Duress PIN entered
      final resultDuress = PinSecurityService.evaluatePin(
        enteredPin: duressPin,
        realSalt: realSalt,
        realHash: realHash,
        duressSalt: duressSalt,
        duressHash: duressHash,
      );
      expect(resultDuress, equals(PinVerificationResult.duress));

      // 3. Test Wrong PIN entered
      final resultWrong = PinSecurityService.evaluatePin(
        enteredPin: '0000',
        realSalt: realSalt,
        realHash: realHash,
        duressSalt: duressSalt,
        duressHash: duressHash,
      );
      expect(resultWrong, equals(PinVerificationResult.invalid));

      // 4. Test Empty PIN entered
      final resultEmpty = PinSecurityService.evaluatePin(
        enteredPin: '',
        realSalt: realSalt,
        realHash: realHash,
        duressSalt: duressSalt,
        duressHash: duressHash,
      );
      expect(resultEmpty, equals(PinVerificationResult.invalid));
    });
  });
}
