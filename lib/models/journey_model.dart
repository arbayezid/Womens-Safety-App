import 'package:cloud_firestore/cloud_firestore.dart';

/// Status of a Safe Journey session
enum JourneyStatus {
  active,
  arrived,
  alert,
  cancelled,
}

/// Model representing a monitored Safe Journey session with Dead-Man's Switch protection.
class JourneyModel {
  final String id;
  final String ownerId;
  final String ownerName;
  final String? ownerPhone;
  final List<String> guardianUids;
  final List<String> guardianEmails;
  final JourneyStatus status;
  final Map<String, dynamic> startLocation;
  final Map<String, dynamic> destination;
  final DateTime startedAt;
  final DateTime expectedArrivalAt;
  final Map<String, dynamic>? currentLocation;
  final DateTime lastUpdatedAt;
  final int? batteryLevel;
  final DateTime? lastSafetyCheckAt;
  final String? linkedSosAlertId;
  final bool startSmsSent;

  const JourneyModel({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    this.ownerPhone,
    required this.guardianUids,
    required this.guardianEmails,
    required this.status,
    required this.startLocation,
    required this.destination,
    required this.startedAt,
    required this.expectedArrivalAt,
    this.currentLocation,
    required this.lastUpdatedAt,
    this.batteryLevel,
    this.lastSafetyCheckAt,
    this.linkedSosAlertId,
    this.startSmsSent = false,
  });

  /// Destination label helper
  String get destinationLabel =>
      destination['label']?.toString() ?? destination['address']?.toString() ?? 'Destination';

  /// Destination latitude
  double get destinationLat => (destination['latitude'] as num?)?.toDouble() ?? 0.0;

  /// Destination longitude
  double get destinationLng => (destination['longitude'] as num?)?.toDouble() ?? 0.0;

  /// Start latitude
  double get startLat => (startLocation['latitude'] as num?)?.toDouble() ?? 0.0;

  /// Start longitude
  double get startLng => (startLocation['longitude'] as num?)?.toDouble() ?? 0.0;

  /// Current latitude (falls back to start)
  double get currentLat =>
      (currentLocation?['latitude'] as num?)?.toDouble() ?? startLat;

  /// Current longitude (falls back to start)
  double get currentLng =>
      (currentLocation?['longitude'] as num?)?.toDouble() ?? startLng;

  /// Whether journey is currently active
  bool get isActive => status == JourneyStatus.active;

  /// Converts model to Firestore map representation
  Map<String, dynamic> toMap() {
    return {
      'ownerId': ownerId,
      'ownerName': ownerName,
      if (ownerPhone != null) 'ownerPhone': ownerPhone,
      'guardianUids': guardianUids,
      'guardianEmails': guardianEmails,
      'status': status.name,
      'startLocation': startLocation,
      'destination': destination,
      'startedAt': Timestamp.fromDate(startedAt),
      'expectedArrivalAt': Timestamp.fromDate(expectedArrivalAt),
      if (currentLocation != null) 'currentLocation': currentLocation,
      'lastUpdatedAt': Timestamp.fromDate(lastUpdatedAt),
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
      if (lastSafetyCheckAt != null) 'lastSafetyCheckAt': Timestamp.fromDate(lastSafetyCheckAt!),
      if (linkedSosAlertId != null) 'linkedSosAlertId': linkedSosAlertId,
      'startSmsSent': startSmsSent,
    };
  }

  /// Parses Firestore document snapshot data into a [JourneyModel]
  factory JourneyModel.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic value, DateTime fallback) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String) return DateTime.tryParse(value) ?? fallback;
      return fallback;
    }

    final now = DateTime.now();

    JourneyStatus parseStatus(dynamic value) {
      final s = value?.toString().toLowerCase().trim();
      switch (s) {
        case 'arrived':
          return JourneyStatus.arrived;
        case 'alert':
          return JourneyStatus.alert;
        case 'cancelled':
          return JourneyStatus.cancelled;
        case 'active':
        default:
          return JourneyStatus.active;
      }
    }

    return JourneyModel(
      id: id,
      ownerId: map['ownerId']?.toString() ?? '',
      ownerName: map['ownerName']?.toString() ?? 'Traveler',
      ownerPhone: map['ownerPhone']?.toString(),
      guardianUids: List<String>.from(map['guardianUids'] ?? []),
      guardianEmails: List<String>.from(map['guardianEmails'] ?? []),
      status: parseStatus(map['status']),
      startLocation: Map<String, dynamic>.from(map['startLocation'] ?? {}),
      destination: Map<String, dynamic>.from(map['destination'] ?? {}),
      startedAt: parseDate(map['startedAt'], now),
      expectedArrivalAt: parseDate(map['expectedArrivalAt'], now.add(const Duration(minutes: 30))),
      currentLocation: map['currentLocation'] != null
          ? Map<String, dynamic>.from(map['currentLocation'])
          : null,
      lastUpdatedAt: parseDate(map['lastUpdatedAt'], now),
      batteryLevel: (map['batteryLevel'] as num?)?.toInt(),
      lastSafetyCheckAt: map['lastSafetyCheckAt'] != null
          ? parseDate(map['lastSafetyCheckAt'], now)
          : null,
      linkedSosAlertId: map['linkedSosAlertId']?.toString(),
      startSmsSent: map['startSmsSent'] as bool? ?? false,
    );
  }

  /// Copy with helper
  JourneyModel copyWith({
    String? id,
    String? ownerId,
    String? ownerName,
    String? ownerPhone,
    List<String>? guardianUids,
    List<String>? guardianEmails,
    JourneyStatus? status,
    Map<String, dynamic>? startLocation,
    Map<String, dynamic>? destination,
    DateTime? startedAt,
    DateTime? expectedArrivalAt,
    Map<String, dynamic>? currentLocation,
    DateTime? lastUpdatedAt,
    int? batteryLevel,
    DateTime? lastSafetyCheckAt,
    String? linkedSosAlertId,
    bool? startSmsSent,
  }) {
    return JourneyModel(
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      ownerName: ownerName ?? this.ownerName,
      ownerPhone: ownerPhone ?? this.ownerPhone,
      guardianUids: guardianUids ?? this.guardianUids,
      guardianEmails: guardianEmails ?? this.guardianEmails,
      status: status ?? this.status,
      startLocation: startLocation ?? this.startLocation,
      destination: destination ?? this.destination,
      startedAt: startedAt ?? this.startedAt,
      expectedArrivalAt: expectedArrivalAt ?? this.expectedArrivalAt,
      currentLocation: currentLocation ?? this.currentLocation,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      lastSafetyCheckAt: lastSafetyCheckAt ?? this.lastSafetyCheckAt,
      linkedSosAlertId: linkedSosAlertId ?? this.linkedSosAlertId,
      startSmsSent: startSmsSent ?? this.startSmsSent,
    );
  }
}
