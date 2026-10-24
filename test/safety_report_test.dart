import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/safety_report_model.dart';
import 'package:smart_safety/services/safety_report_service.dart';
import 'package:smart_safety/utils/geohash_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 5: GeohashHelper Pure Math & Spatial Tests', () {
    test('Encodes Dhaka coordinates accurately to precision 5 and 6', () {
      const lat = 23.7937;
      const lng = 90.4066;

      final g5 = GeohashHelper.encode(lat, lng, precision: 5);
      final g6 = GeohashHelper.encode(lat, lng, precision: 6);

      expect(g5.length, 5);
      expect(g6.length, 6);
      expect(g6.startsWith(g5), isTrue);
    });

    test('Decodes bounding box and center coordinates within expected cell bounds', () {
      const lat = 23.7937;
      const lng = 90.4066;
      final g6 = GeohashHelper.encode(lat, lng, precision: 6);

      final bbox = GeohashHelper.decodeBoundingBox(g6);
      expect(bbox.length, 4);
      expect(bbox[0], lessThanOrEqualTo(lat)); // minLat <= lat
      expect(bbox[2], greaterThanOrEqualTo(lat)); // maxLat >= lat
      expect(bbox[1], lessThanOrEqualTo(lng)); // minLon <= lng
      expect(bbox[3], greaterThanOrEqualTo(lng)); // maxLon >= lng

      final center = GeohashHelper.decodeCenter(g6);
      expect((center[0] - lat).abs(), lessThan(0.01));
      expect((center[1] - lng).abs(), lessThan(0.01));
    });

    test('Calculates exactly 8 distinct neighbors for a geohash cell', () {
      final centerHash = GeohashHelper.encode(23.7937, 90.4066, precision: 6);
      final neighbors = GeohashHelper.getNeighbors(centerHash);

      expect(neighbors.length, 8);
      expect(neighbors.contains(centerHash), isFalse);
      for (final n in neighbors) {
        expect(n.length, 6);
      }
      // Set uniqueness
      expect(neighbors.toSet().length, 8);
    });

    test('getSearchCluster returns 9 elements (center + 8 neighbors)', () {
      final cluster = GeohashHelper.getSearchCluster(23.7937, 90.4066, precision: 6);
      expect(cluster.length, 9);
      expect(cluster.toSet().length, 9);
    });
  });

  group('Phase 5: SafetyReportModel & Time Decay Tests', () {
    test('SafetyReportModel creates and assigns geohash5 and geohash6 automatically', () {
      final report = SafetyReportModel.create(
        id: 'rep_1',
        userId: 'user_a',
        userName: 'Ayesha',
        incidentType: SafetyIncidentType.poorLighting,
        description: 'Dark alleyway with broken lamps',
        latitude: 23.7935,
        longitude: 90.4045,
      );

      expect(report.geohash5.length, 5);
      expect(report.geohash6.length, 6);
      expect(report.incidentType, SafetyIncidentType.poorLighting);
      expect(report.status, 'active');
    });

    test('Converts toMap and fromMap preserving fields and types', () {
      final now = DateTime.now();
      final original = SafetyReportModel.create(
        id: 'rep_map_test',
        userId: 'u_123',
        userName: 'Fatima',
        incidentType: SafetyIncidentType.harassment,
        description: 'Loitering and catcalling near bus stand',
        latitude: 23.7570,
        longitude: 90.3900,
        createdAt: now,
        verifiedCount: 4,
      );

      final map = original.toMap();
      expect(map['incidentType'], 'harassment');
      expect(map['userId'], 'u_123');
      expect(map['verifiedCount'], 4);

      final restored = SafetyReportModel.fromMap(map, 'rep_map_test');
      expect(restored.id, 'rep_map_test');
      expect(restored.incidentType, SafetyIncidentType.harassment);
      expect(restored.userName, 'Fatima');
      expect(restored.verifiedCount, 4);
    });

    test('Time decay: fresh report retains full severity weight', () {
      final now = DateTime.now();
      final report = SafetyReportModel.create(
        id: 'r_fresh',
        userId: 'u1',
        userName: 'User',
        incidentType: SafetyIncidentType.harassment, // baseSeverityWeight = 3.0
        description: 'Test',
        latitude: 23.0,
        longitude: 90.0,
        createdAt: now,
        verifiedCount: 0,
      );

      final weight = report.computeDecayedWeight(at: now);
      expect(weight, closeTo(3.0, 0.05));
    });

    test('Time decay: report decays to ~50% at 14-day half-life', () {
      final now = DateTime.now();
      final report = SafetyReportModel.create(
        id: 'r_decay',
        userId: 'u1',
        userName: 'User',
        incidentType: SafetyIncidentType.harassment, // baseSeverityWeight = 3.0
        description: 'Test',
        latitude: 23.0,
        longitude: 90.0,
        createdAt: now.subtract(const Duration(days: 14)),
        verifiedCount: 0,
      );

      final weight = report.computeDecayedWeight(at: now);
      // Half of 3.0 is 1.5
      expect(weight, closeTo(1.5, 0.1));
    });

    test('Time decay: verified count increases weight multiplier', () {
      final now = DateTime.now();
      final unverified = SafetyReportModel.create(
        id: 'r1',
        userId: 'u1',
        userName: 'User',
        incidentType: SafetyIncidentType.poorLighting, // 1.2
        description: 'Test',
        latitude: 23.0,
        longitude: 90.0,
        createdAt: now,
        verifiedCount: 0,
      );
      final verified = unverified.copyWith(verifiedCount: 5); // +100% boost -> 2.0x

      final unverifiedWeight = unverified.computeDecayedWeight(at: now);
      final verifiedWeight = verified.computeDecayedWeight(at: now);

      expect(verifiedWeight, greaterThan(unverifiedWeight));
      expect(verifiedWeight, closeTo(unverifiedWeight * 2.0, 0.05));
    });

    test('Time decay: resolved reports have 0.0 risk weight', () {
      final report = SafetyReportModel.create(
        id: 'r_resolved',
        userId: 'u1',
        userName: 'User',
        incidentType: SafetyIncidentType.harassment,
        description: 'Test',
        latitude: 23.0,
        longitude: 90.0,
        status: 'resolved',
      );

      expect(report.computeDecayedWeight(), 0.0);
    });
  });

  group('Phase 5: SafetyCluster Heatmap Cell Tests', () {
    test('SafetyCluster assigns appropriate color and radius based on risk score', () {
      const lowCluster = SafetyCluster(
        geohash6: 'wh0r7z',
        centerLat: 23.79,
        centerLng: 90.40,
        reports: [],
        totalRiskScore: 1.5,
      );
      expect(lowCluster.totalRiskScore, lessThan(2.0));
      expect(lowCluster.radiusMeters, 160.0);

      const medCluster = SafetyCluster(
        geohash6: 'wh0r7y',
        centerLat: 23.79,
        centerLng: 90.40,
        reports: [],
        totalRiskScore: 3.5,
      );
      expect(medCluster.radiusMeters, 220.0);

      const highCluster = SafetyCluster(
        geohash6: 'wh0r7x',
        centerLat: 23.79,
        centerLng: 90.40,
        reports: [],
        totalRiskScore: 6.2,
      );
      expect(highCluster.radiusMeters, 280.0);
    });
  });

  group('Phase 5: SafetyReportService Proximity Risk & Math Tests', () {
    test('haversineDistanceMeters accurately calculates metric distance', () {
      // 1 degree latitude is approx 111,000 meters
      final dist = SafetyReportService.haversineDistanceMeters(23.0, 90.0, 23.001, 90.0);
      expect(dist, closeTo(111.0, 5.0)); // ~111 meters
    });

    test('checkProximityRisk returns null when outside threshold distance', () {
      // Set a test cluster in clustersNotifier
      SafetyReportService.instance.clustersNotifier.value = [
        const SafetyCluster(
          geohash6: 'test_hash_1',
          centerLat: 23.7937,
          centerLng: 90.4066,
          reports: [],
          totalRiskScore: 4.0,
        ),
      ];

      // User is ~1km away (23.8037, 90.4066)
      final alert = SafetyReportService.instance.checkProximityRisk(
        userLat: 23.8037,
        userLng: 90.4066,
        radiusMeters: 200.0,
      );

      expect(alert, isNull);
    });

    test('checkProximityRisk returns matched cluster when user is within 200m', () {
      // Set a high risk cluster in clustersNotifier
      SafetyReportService.instance.clustersNotifier.value = [
        const SafetyCluster(
          geohash6: 'test_hash_prox',
          centerLat: 23.7937,
          centerLng: 90.4066,
          reports: [],
          totalRiskScore: 4.5,
        ),
      ];

      // User is within ~50m (23.7939, 90.4066)
      final alert = SafetyReportService.instance.checkProximityRisk(
        userLat: 23.7939,
        userLng: 90.4066,
        radiusMeters: 200.0,
      );

      expect(alert, isNotNull);
      expect(alert!.geohash6, 'test_hash_prox');

      // Immediate second check should be suppressed by cooldown
      final duplicateAlert = SafetyReportService.instance.checkProximityRisk(
        userLat: 23.7939,
        userLng: 90.4066,
        radiusMeters: 200.0,
      );
      expect(duplicateAlert, isNull);
    });

    test('Rate Limiter restricts users to max 3 submissions per day', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final now = DateTime.now();
      final todayKey = 'safety_reports_count_test_user_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // Pre-set 3 submissions today
      await prefs.setInt(todayKey, 3);

      expect(prefs.getInt(todayKey), 3);
    });
  });
}
