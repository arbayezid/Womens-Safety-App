import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../core/app_colors.dart';
import '../utils/geohash_helper.dart';

/// Categories of community-submitted safety reports.
enum SafetyIncidentType {
  poorLighting,
  harassment,
  isolated,
  suspicious,
  other;

  String get key {
    switch (this) {
      case SafetyIncidentType.poorLighting:
        return 'poor_lighting';
      case SafetyIncidentType.harassment:
        return 'harassment';
      case SafetyIncidentType.isolated:
        return 'isolated';
      case SafetyIncidentType.suspicious:
        return 'suspicious';
      case SafetyIncidentType.other:
        return 'other';
    }
  }

  String get label {
    switch (this) {
      case SafetyIncidentType.poorLighting:
        return 'Poor Street Lighting';
      case SafetyIncidentType.harassment:
        return 'Harassment / Eve-teasing';
      case SafetyIncidentType.isolated:
        return 'Deserted / Isolated Area';
      case SafetyIncidentType.suspicious:
        return 'Suspicious Activity';
      case SafetyIncidentType.other:
        return 'Other Safety Concern';
    }
  }

  double get baseSeverityWeight {
    switch (this) {
      case SafetyIncidentType.poorLighting:
        return 1.2;
      case SafetyIncidentType.harassment:
        return 3.0; // High severity
      case SafetyIncidentType.isolated:
        return 1.8;
      case SafetyIncidentType.suspicious:
        return 2.4;
      case SafetyIncidentType.other:
        return 1.0;
    }
  }

  IconData get icon {
    switch (this) {
      case SafetyIncidentType.poorLighting:
        return Icons.lightbulb_outline_rounded;
      case SafetyIncidentType.harassment:
        return Icons.warning_amber_rounded;
      case SafetyIncidentType.isolated:
        return Icons.person_off_rounded;
      case SafetyIncidentType.suspicious:
        return Icons.visibility_rounded;
      case SafetyIncidentType.other:
        return Icons.report_problem_rounded;
    }
  }

  Color get color {
    switch (this) {
      case SafetyIncidentType.poorLighting:
        return const Color(0xFFF59E0B); // Amber
      case SafetyIncidentType.harassment:
        return AppColors.sosRed; // Red
      case SafetyIncidentType.isolated:
        return const Color(0xFF8B5CF6); // Purple
      case SafetyIncidentType.suspicious:
        return const Color(0xFFEF4444); // Bright Red
      case SafetyIncidentType.other:
        return const Color(0xFF6B7280); // Gray
    }
  }

  static SafetyIncidentType fromString(String? val) {
    switch (val?.toLowerCase()) {
      case 'poor_lighting':
      case 'poorlighting':
        return SafetyIncidentType.poorLighting;
      case 'harassment':
        return SafetyIncidentType.harassment;
      case 'isolated':
        return SafetyIncidentType.isolated;
      case 'suspicious':
        return SafetyIncidentType.suspicious;
      case 'other':
      default:
        return SafetyIncidentType.other;
    }
  }
}

/// Community-submitted report identifying an unsafe spot or incident.
class SafetyReportModel {
  final String id;
  final String userId;
  final String userName;
  final SafetyIncidentType incidentType;
  final String description;
  final double latitude;
  final double longitude;
  final String geohash5;
  final String geohash6;
  final DateTime createdAt;
  final int verifiedCount;
  final String status; // 'active' | 'resolved'

  const SafetyReportModel({
    required this.id,
    required this.userId,
    required this.userName,
    required this.incidentType,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.geohash5,
    required this.geohash6,
    required this.createdAt,
    this.verifiedCount = 0,
    this.status = 'active',
  });

  /// Factory helper that automatically generates geohash5 and geohash6 from coordinates.
  factory SafetyReportModel.create({
    required String id,
    required String userId,
    required String userName,
    required SafetyIncidentType incidentType,
    required String description,
    required double latitude,
    required double longitude,
    DateTime? createdAt,
    int verifiedCount = 0,
    String status = 'active',
  }) {
    final g5 = GeohashHelper.encode(latitude, longitude, precision: 5);
    final g6 = GeohashHelper.encode(latitude, longitude, precision: 6);
    return SafetyReportModel(
      id: id,
      userId: userId,
      userName: userName,
      incidentType: incidentType,
      description: description,
      latitude: latitude,
      longitude: longitude,
      geohash5: g5,
      geohash6: g6,
      createdAt: createdAt ?? DateTime.now(),
      verifiedCount: verifiedCount,
      status: status,
    );
  }

  /// Calculates decayed risk weight using exponential half-life time decay:
  /// w = baseWeight * (1 + 0.2 * verifiedCount) * e^(-lambda * deltaDays)
  ///
  /// Half-life is set to 14 days (lambda = ln(2) / 14 ~ 0.0495).
  double computeDecayedWeight({DateTime? at}) {
    if (status == 'resolved') return 0.0;

    final targetTime = at ?? DateTime.now();
    final elapsedHours = targetTime.difference(createdAt).inHours;
    if (elapsedHours < 0) return incidentType.baseSeverityWeight;

    final elapsedDays = elapsedHours / 24.0;
    // Half-life: 14 days
    const halfLifeDays = 14.0;
    final lambda = math.log(2.0) / halfLifeDays;
    final decayFactor = math.exp(-lambda * elapsedDays);

    // Each community verification adds 20% confidence up to +100% (max 5)
    final verificationMultiplier = 1.0 + (math.min(verifiedCount, 5) * 0.2);

    return incidentType.baseSeverityWeight * verificationMultiplier * decayFactor;
  }

  /// Firestore serialization map
  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userName': userName,
      'incidentType': incidentType.key,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'geohash5': geohash5,
      'geohash6': geohash6,
      'createdAt': Timestamp.fromDate(createdAt),
      'verifiedCount': verifiedCount,
      'status': status,
    };
  }

  /// Deserialization from Firestore Map
  factory SafetyReportModel.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val) ?? DateTime.now();
      return DateTime.now();
    }

    final lat = (map['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (map['longitude'] as num?)?.toDouble() ?? 0.0;
    final g5 = map['geohash5'] as String? ?? GeohashHelper.encode(lat, lng, precision: 5);
    final g6 = map['geohash6'] as String? ?? GeohashHelper.encode(lat, lng, precision: 6);

    return SafetyReportModel(
      id: id,
      userId: map['userId'] as String? ?? '',
      userName: map['userName'] as String? ?? 'Anonymous',
      incidentType: SafetyIncidentType.fromString(map['incidentType'] as String?),
      description: map['description'] as String? ?? '',
      latitude: lat,
      longitude: lng,
      geohash5: g5,
      geohash6: g6,
      createdAt: parseDate(map['createdAt']),
      verifiedCount: (map['verifiedCount'] as num?)?.toInt() ?? 0,
      status: map['status'] as String? ?? 'active',
    );
  }

  SafetyReportModel copyWith({
    String? id,
    String? userId,
    String? userName,
    SafetyIncidentType? incidentType,
    String? description,
    double? latitude,
    double? longitude,
    String? geohash5,
    String? geohash6,
    DateTime? createdAt,
    int? verifiedCount,
    String? status,
  }) {
    return SafetyReportModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      incidentType: incidentType ?? this.incidentType,
      description: description ?? this.description,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      geohash5: geohash5 ?? this.geohash5,
      geohash6: geohash6 ?? this.geohash6,
      createdAt: createdAt ?? this.createdAt,
      verifiedCount: verifiedCount ?? this.verifiedCount,
      status: status ?? this.status,
    );
  }
}

/// Clustered cell representation for rendering on flutter_map heatmap overlay.
class SafetyCluster {
  final String geohash6;
  final double centerLat;
  final double centerLng;
  final List<SafetyReportModel> reports;
  final double totalRiskScore;

  const SafetyCluster({
    required this.geohash6,
    required this.centerLat,
    required this.centerLng,
    required this.reports,
    required this.totalRiskScore,
  });

  /// Risk level categorization for UI color styling:
  /// - Low (< 2.0): Yellowish / Caution
  /// - Medium (2.0 - 5.0): Orange / Warning
  /// - High (> 5.0): Red / Danger
  Color get clusterColor {
    if (totalRiskScore >= 5.0) {
      return AppColors.sosRed.withValues(alpha: 0.7);
    } else if (totalRiskScore >= 2.0) {
      return AppColors.actionOrange.withValues(alpha: 0.65);
    } else {
      return const Color(0xFFFBBF24).withValues(alpha: 0.6); // Amber
    }
  }

  double get radiusMeters {
    // Geohash6 is ~600m radius
    if (totalRiskScore >= 5.0) return 280.0;
    if (totalRiskScore >= 2.0) return 220.0;
    return 160.0;
  }
}
