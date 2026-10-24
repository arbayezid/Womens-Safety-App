import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/journey_model.dart';
import 'package:smart_safety/models/safe_zone_model.dart';
import 'package:smart_safety/services/journey_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4: Followed Mode - JourneyModel Tests', () {
    test('Default mode is safe_journey and isFollowedMode is false', () {
      final now = DateTime.now();
      final journey = JourneyModel(
        id: 'journey_1',
        ownerId: 'user_1',
        ownerName: 'Alice',
        guardianUids: const ['g1'],
        guardianEmails: const ['g1@test.com'],
        status: JourneyStatus.active,
        startLocation: const {'address': 'Gulshan 2', 'latitude': 23.7925, 'longitude': 90.4078},
        destination: const {'label': 'Banani', 'latitude': 23.7937, 'longitude': 90.4066},
        startedAt: now,
        expectedArrivalAt: now.add(const Duration(minutes: 30)),
        lastUpdatedAt: now,
      );

      expect(journey.mode, 'safe_journey');
      expect(journey.isFollowedMode, isFalse);
      expect(journey.destinationLabel, 'Banani');
    });

    test('Followed mode initialization sets mode and handles destinationLabel fallback', () {
      final now = DateTime.now();
      final journey = JourneyModel(
        id: 'followed_1',
        ownerId: 'user_1',
        ownerName: 'Alice',
        guardianUids: const ['g1'],
        guardianEmails: const ['g1@test.com'],
        status: JourneyStatus.active,
        startLocation: const {'address': 'Dhanmondi 27', 'latitude': 23.7538, 'longitude': 90.3770},
        destination: const {},
        startedAt: now,
        expectedArrivalAt: now.add(const Duration(hours: 12)),
        lastUpdatedAt: now,
        mode: 'followed',
      );

      expect(journey.mode, 'followed');
      expect(journey.isFollowedMode, isTrue);
      expect(journey.destinationLabel, 'Followed Mode (No fixed destination)');
    });

    test('JourneyModel converts toMap and fromMap preserving mode: followed', () {
      final now = DateTime.now();
      final original = JourneyModel(
        id: 'followed_map_test',
        ownerId: 'user_xyz',
        ownerName: 'Bob',
        guardianUids: const ['g2'],
        guardianEmails: const ['g2@test.com'],
        status: JourneyStatus.active,
        startLocation: const {'address': 'Mirpur 10', 'latitude': 23.8069, 'longitude': 90.3687},
        destination: const {'label': 'Police Station', 'latitude': 23.8070, 'longitude': 90.3690},
        startedAt: now,
        expectedArrivalAt: now.add(const Duration(hours: 2)),
        lastUpdatedAt: now,
        mode: 'followed',
      );

      final map = original.toMap();
      expect(map['mode'], 'followed');

      // Emulate Firestore document with Timestamps
      final firestoreMap = Map<String, dynamic>.from(map);
      firestoreMap['startedAt'] = Timestamp.fromDate(now);
      firestoreMap['expectedArrivalAt'] = Timestamp.fromDate(now.add(const Duration(hours: 2)));
      firestoreMap['lastUpdatedAt'] = Timestamp.fromDate(now);

      final restored = JourneyModel.fromMap(firestoreMap, 'followed_map_test');
      expect(restored.id, 'followed_map_test');
      expect(restored.mode, 'followed');
      expect(restored.isFollowedMode, isTrue);
      expect(restored.ownerId, 'user_xyz');
    });

    test('copyWith preserves or overrides mode properly', () {
      final now = DateTime.now();
      final journey = JourneyModel(
        id: 'j1',
        ownerId: 'u1',
        ownerName: 'Alice',
        guardianUids: const [],
        guardianEmails: const [],
        status: JourneyStatus.active,
        startLocation: const {'address': 'A', 'latitude': 23.0, 'longitude': 90.0},
        destination: const {'address': 'B', 'latitude': 23.1, 'longitude': 90.1},
        startedAt: now,
        expectedArrivalAt: now.add(const Duration(minutes: 30)),
        lastUpdatedAt: now,
        mode: 'followed',
      );

      final copiedSame = journey.copyWith(destination: const {'address': 'C', 'latitude': 23.2, 'longitude': 90.2});
      expect(copiedSame.mode, 'followed');
      expect(copiedSame.isFollowedMode, isTrue);

      final copiedSwitched = journey.copyWith(mode: 'safe_journey');
      expect(copiedSwitched.mode, 'safe_journey');
      expect(copiedSwitched.isFollowedMode, isFalse);
    });
  });

  group('Phase 4: Followed Mode - Safety Trigger Evaluation Tests', () {
    test('evaluateFollowedCheck returns true when elapsed time is 10 minutes or more', () {
      final now = DateTime.now();
      final lastCheck = now.subtract(const Duration(minutes: 10, seconds: 5));

      final shouldTrigger = JourneyService.evaluateFollowedCheck(
        now: now,
        lastCheckOrStart: lastCheck,
        isCooldownActive: false,
      );

      expect(shouldTrigger, isTrue);
    });

    test('evaluateFollowedCheck returns false when less than 10 minutes elapsed', () {
      final now = DateTime.now();
      final lastCheck = now.subtract(const Duration(minutes: 9, seconds: 30));

      final shouldTrigger = JourneyService.evaluateFollowedCheck(
        now: now,
        lastCheckOrStart: lastCheck,
        isCooldownActive: false,
      );

      expect(shouldTrigger, isFalse);
    });

    test('evaluateFollowedCheck returns false when cooldown is active', () {
      final now = DateTime.now();
      final lastCheck = now.subtract(const Duration(minutes: 15));

      final shouldTrigger = JourneyService.evaluateFollowedCheck(
        now: now,
        lastCheckOrStart: lastCheck,
        isCooldownActive: true,
      );

      expect(shouldTrigger, isFalse);
    });
  });

  group('Phase 4: Followed Mode - Safe Police Checkpoints Tests', () {
    test('Identifies nearest police station safe zone for followed user', () {
      // User is near Banani Police Station (23.7937, 90.4066)
      const userLat = 23.7930;
      const userLng = 90.4060;

      final policeZones = SafeZone.defaultDhakaSafeZones
          .where((z) => z.type == SafeZoneType.police)
          .toList();

      expect(policeZones, isNotEmpty);

      // Sort by distance to user
      policeZones.sort((a, b) {
        final distA = a.calculateDistanceKm(userLat, userLng);
        final distB = b.calculateDistanceKm(userLat, userLng);
        return distA.compareTo(distB);
      });

      final nearest = policeZones.first;
      expect(nearest.type, SafeZoneType.police);
      expect(nearest.calculateDistanceKm(userLat, userLng), lessThan(1.0)); // Within 1km
    });
  });
}
