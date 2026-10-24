import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/safety_report_model.dart';
import 'auth_service.dart';
import 'notification_service.dart';

/// Service managing community safety reports, spatial clustering,
/// 15-minute in-memory Spark plan cache, rate limiting, and risk-zone proximity warnings.
class SafetyReportService {
  SafetyReportService._internal();
  static final SafetyReportService instance = SafetyReportService._internal();

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  /// In-memory cache of reports
  List<SafetyReportModel> _cachedReports = [];
  DateTime? _lastFetchTime;

  /// Cache expiration duration (15 minutes) to protect Spark plan quotas
  static const Duration cacheTtl = Duration(minutes: 15);

  /// Notifier exposing the latest reports
  final ValueNotifier<List<SafetyReportModel>> reportsNotifier =
      ValueNotifier<List<SafetyReportModel>>([]);

  /// Notifier exposing clustered heatmap cells
  final ValueNotifier<List<SafetyCluster>> clustersNotifier =
      ValueNotifier<List<SafetyCluster>>([]);

  /// Cooldown map for proximity alerts to prevent alert fatigue: geohash6 -> lastAlertTime
  final Map<String, DateTime> _proximityAlertCooldowns = {};

  // ─────────────────────────────────────────────────────────────
  //  FETCHING & CLUSTERING (15-min In-Memory Spark Cache)
  // ─────────────────────────────────────────────────────────────

  /// Fetches community safety reports for the given coordinates or Dhaka bounds.
  /// Uses a strict 15-minute in-memory cache to avoid repeated Firestore reads.
  Future<List<SafetyReportModel>> getReports({
    double? latitude,
    double? longitude,
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();

    // Check in-memory cache validity
    if (!forceRefresh &&
        _lastFetchTime != null &&
        now.difference(_lastFetchTime!) < cacheTtl &&
        _cachedReports.isNotEmpty) {
      debugPrint('[SafetyReportService] ⚡ Serving ${_cachedReports.length} reports from 15-min in-memory cache');
      return _cachedReports;
    }

    try {
      // Query recent safety reports from Firestore (limit to 100 for Spark tier efficiency)
      final snapshot = await _firestore
          .collection('safety_reports')
          .where('status', isEqualTo: 'active')
          .limit(100)
          .get();

      List<SafetyReportModel> reports = snapshot.docs
          .map((doc) => SafetyReportModel.fromMap(doc.data(), doc.id))
          .toList();

      // If Firestore collection is empty (e.g. freshly created or in local test/debug),
      // provide verified Dhaka seed reports for realistic safety visualization.
      if (reports.isEmpty) {
        reports = _getDhakaSeedReports();
      }

      _cachedReports = reports;
      _lastFetchTime = now;
      reportsNotifier.value = List.unmodifiable(_cachedReports);

      // Re-cluster reports for heatmap visualization
      _reclusterReports(_cachedReports);

      return _cachedReports;
    } catch (e) {
      debugPrint('[SafetyReportService] Error fetching safety reports: $e');
      if (_cachedReports.isEmpty) {
        _cachedReports = _getDhakaSeedReports();
        reportsNotifier.value = List.unmodifiable(_cachedReports);
        _reclusterReports(_cachedReports);
      }
      return _cachedReports;
    }
  }

  /// Groups reports by `geohash6` cell and computes the decayed risk score per cluster.
  void _reclusterReports(List<SafetyReportModel> reports) {
    final Map<String, List<SafetyReportModel>> cellMap = {};

    for (final report in reports) {
      cellMap.putIfAbsent(report.geohash6, () => []).add(report);
    }

    final List<SafetyCluster> clusters = [];
    final now = DateTime.now();

    for (final entry in cellMap.entries) {
      final cellHash = entry.key;
      final cellReports = entry.value;

      double cellRisk = 0.0;
      double sumLat = 0.0;
      double sumLng = 0.0;

      for (final r in cellReports) {
        cellRisk += r.computeDecayedWeight(at: now);
        sumLat += r.latitude;
        sumLng += r.longitude;
      }

      final centerLat = sumLat / cellReports.length;
      final centerLng = sumLng / cellReports.length;

      clusters.add(
        SafetyCluster(
          geohash6: cellHash,
          centerLat: centerLat,
          centerLng: centerLng,
          reports: List.unmodifiable(cellReports),
          totalRiskScore: cellRisk,
        ),
      );
    }

    clustersNotifier.value = List.unmodifiable(clusters);
  }

  // ─────────────────────────────────────────────────────────────
  //  SUBMIT REPORT & RATE LIMITING (Max 3 per day)
  // ─────────────────────────────────────────────────────────────

  /// Submits a new safety report with rate limiting (max 3 reports / user / 24h).
  Future<SafetyReportResult> submitReport({
    required SafetyIncidentType incidentType,
    required String description,
    required double latitude,
    required double longitude,
  }) async {
    final user = AuthService.instance.currentUser;
    if (user == null) {
      return SafetyReportResult.error('You must be signed in to submit a safety report.');
    }

    // Rate Limiting check
    final bool canSubmit = await _checkAndIncrementRateLimit(user.uid);
    if (!canSubmit) {
      return SafetyReportResult.rateLimited(
        'Daily limit reached. You can submit up to 3 safety reports per day to ensure data quality.',
      );
    }

    try {
      final report = SafetyReportModel.create(
        id: '',
        userId: user.uid,
        userName: AuthService.instance.displayName.isNotEmpty ? AuthService.instance.displayName : 'Community Member',
        incidentType: incidentType,
        description: description.trim(),
        latitude: latitude,
        longitude: longitude,
      );

      final docRef = await _firestore.collection('safety_reports').add(report.toMap());
      final savedReport = report.copyWith(id: docRef.id);

      // Add to local cache and refresh cluster
      _cachedReports.insert(0, savedReport);
      reportsNotifier.value = List.unmodifiable(_cachedReports);
      _reclusterReports(_cachedReports);

      return SafetyReportResult.success(savedReport);
    } catch (e) {
      debugPrint('[SafetyReportService] Error submitting safety report: $e');
      return SafetyReportResult.error('Failed to submit report: $e');
    }
  }

  /// Verifies or confirms an existing community safety report
  Future<bool> verifyReport(String reportId) async {
    try {
      await _firestore.collection('safety_reports').doc(reportId).update({
        'verifiedCount': FieldValue.increment(1),
      });

      // Update in memory
      final idx = _cachedReports.indexWhere((r) => r.id == reportId);
      if (idx != -1) {
        final updated = _cachedReports[idx].copyWith(
          verifiedCount: _cachedReports[idx].verifiedCount + 1,
        );
        _cachedReports[idx] = updated;
        reportsNotifier.value = List.unmodifiable(_cachedReports);
        _reclusterReports(_cachedReports);
      }
      return true;
    } catch (e) {
      debugPrint('[SafetyReportService] Error verifying report: $e');
      return false;
    }
  }

  /// Rate Limiter: Checks SharedPreferences for user submissions in the last 24h.
  Future<bool> _checkAndIncrementRateLimit(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = 'safety_reports_count_${userId}_${_getTodayString()}';
    final currentCount = prefs.getInt(todayKey) ?? 0;

    if (currentCount >= 3) {
      return false;
    }

    await prefs.setInt(todayKey, currentCount + 1);
    return true;
  }

  String _getTodayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  // ─────────────────────────────────────────────────────────────
  //  RISK-ZONE PROXIMITY WARNING (200m Alert)
  // ─────────────────────────────────────────────────────────────

  /// Checks if [userLat, userLng] is within [radiusMeters] (default 200m) of any high-risk cluster.
  /// If so, verifies that the alert is not on a 15-minute cooldown before returning the cluster.
  SafetyCluster? checkProximityRisk({
    required double userLat,
    required double userLng,
    double radiusMeters = 200.0,
    double minRiskScore = 2.0,
  }) {
    final clusters = clustersNotifier.value;
    if (clusters.isEmpty) return null;

    final now = DateTime.now();

    for (final cluster in clusters) {
      if (cluster.totalRiskScore < minRiskScore) continue;

      final dist = haversineDistanceMeters(userLat, userLng, cluster.centerLat, cluster.centerLng);
      if (dist <= radiusMeters) {
        final lastAlert = _proximityAlertCooldowns[cluster.geohash6];
        if (lastAlert == null || now.difference(lastAlert).inMinutes >= 15) {
          _proximityAlertCooldowns[cluster.geohash6] = now;
          debugPrint('[SafetyReportService] ⚠️ Proximity alert triggered for risk cluster ${cluster.geohash6} (dist: ${dist.round()}m, risk: ${cluster.totalRiskScore.toStringAsFixed(1)})');
          return cluster;
        }
      }
    }

    return null;
  }

  /// Dispatches a high-priority caution notification if the user entered a risk zone.
  Future<void> evaluateAndNotifyProximityRisk(double lat, double lng) async {
    final cluster = checkProximityRisk(userLat: lat, userLng: lng);
    if (cluster != null) {
      final dominantType = cluster.reports.isNotEmpty
          ? cluster.reports.first.incidentType.label
          : 'Safety concerns';

      await NotificationService.instance.showStatusNotification(
        id: 998,
        title: '⚠️ Caution: Risk-Zone Nearby',
        body: 'You are near an area with reported $dominantType. Stay alert and stick to well-lit main roads.',
      );
    }
  }

  /// Calculates distance in meters between two lat/lng points using Haversine formula
  static double haversineDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = (lat2 - lat1) * (math.pi / 180.0);
    final dLon = (lon2 - lon1) * (math.pi / 180.0);
    final lat1Rad = lat1 * (math.pi / 180.0);
    final lat2Rad = lat2 * (math.pi / 180.0);

    final sinDLat = math.sin(dLat / 2);
    final sinDLon = math.sin(dLon / 2);

    final a = sinDLat * sinDLat +
        math.cos(lat1Rad) * math.cos(lat2Rad) * sinDLon * sinDLon;
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  // ─────────────────────────────────────────────────────────────
  //  DHAKA SEED DATA (Debug / Initial Spark state)
  // ─────────────────────────────────────────────────────────────

  List<SafetyReportModel> _getDhakaSeedReports() {
    final now = DateTime.now();
    return [
      SafetyReportModel.create(
        id: 'seed_dhaka_1',
        userId: 'seed_system_1',
        userName: 'Ayesha K.',
        incidentType: SafetyIncidentType.poorLighting,
        description: 'Road 11 alleyway has broken streetlights for the past 2 weeks. Very dark after 8 PM.',
        latitude: 23.7935,
        longitude: 90.4045,
        createdAt: now.subtract(const Duration(days: 2)),
        verifiedCount: 4,
      ),
      SafetyReportModel.create(
        id: 'seed_dhaka_2',
        userId: 'seed_system_2',
        userName: 'Tania R.',
        incidentType: SafetyIncidentType.harassment,
        description: 'Group of men loitering near the footbridge staircase catcalling women walking home from the bus stop.',
        latitude: 23.7570,
        longitude: 90.3900,
        createdAt: now.subtract(const Duration(hours: 18)),
        verifiedCount: 6,
      ),
      SafetyReportModel.create(
        id: 'seed_dhaka_3',
        userId: 'seed_system_3',
        userName: 'Nadia S.',
        incidentType: SafetyIncidentType.suspicious,
        description: 'Suspicious motorbike following pedestrians slowly around the metro pillar intersection.',
        latitude: 23.8075,
        longitude: 90.3685,
        createdAt: now.subtract(const Duration(days: 4)),
        verifiedCount: 3,
      ),
      SafetyReportModel.create(
        id: 'seed_dhaka_4',
        userId: 'seed_system_4',
        userName: 'Farzana M.',
        incidentType: SafetyIncidentType.isolated,
        description: 'Deserted lake corner without security guards or adequate lighting after 9 PM.',
        latitude: 23.7480,
        longitude: 90.3790,
        createdAt: now.subtract(const Duration(days: 6)),
        verifiedCount: 2,
      ),
      SafetyReportModel.create(
        id: 'seed_dhaka_5',
        userId: 'seed_system_5',
        userName: 'Sabrina H.',
        incidentType: SafetyIncidentType.poorLighting,
        description: 'Underpass exit towards Mohakhali has no working lamps. Walk with someone if possible.',
        latitude: 23.7780,
        longitude: 90.4000,
        createdAt: now.subtract(const Duration(days: 1)),
        verifiedCount: 5,
      ),
    ];
  }
}

/// Result envelope for community safety report submissions.
class SafetyReportResult {
  final bool isSuccess;
  final bool isRateLimited;
  final String? errorMessage;
  final SafetyReportModel? report;

  const SafetyReportResult._({
    required this.isSuccess,
    this.isRateLimited = false,
    this.errorMessage,
    this.report,
  });

  factory SafetyReportResult.success(SafetyReportModel report) =>
      SafetyReportResult._(isSuccess: true, report: report);

  factory SafetyReportResult.rateLimited(String message) =>
      SafetyReportResult._(isSuccess: false, isRateLimited: true, errorMessage: message);

  factory SafetyReportResult.error(String message) =>
      SafetyReportResult._(isSuccess: false, errorMessage: message);
}
