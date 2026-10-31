import 'package:cloud_firestore/cloud_firestore.dart';

/// Status enum for a Ride Check-in session
enum RideStatus {
  active,
  arrived,
  overdue,
  sos,
  cancelled;

  static RideStatus fromString(String? value) {
    switch (value?.toLowerCase().trim()) {
      case 'arrived':
        return RideStatus.arrived;
      case 'overdue':
        return RideStatus.overdue;
      case 'sos':
        return RideStatus.sos;
      case 'cancelled':
        return RideStatus.cancelled;
      case 'active':
      default:
        return RideStatus.active;
    }
  }

  String get displayName {
    switch (this) {
      case RideStatus.active:
        return 'Active';
      case RideStatus.arrived:
        return 'Arrived Safely';
      case RideStatus.overdue:
        return 'Overdue';
      case RideStatus.sos:
        return 'SOS Alert';
      case RideStatus.cancelled:
        return 'Cancelled';
    }
  }
}

/// Data model representing a Ride Safety Check-in session.
class RideCheckinModel {
  final String id;
  final String userId;
  final String userName;
  final String? userPhone;
  final String rideType; // CNG, Bike, Car, Bus, Rickshaw
  final String? appName; // Uber, Pathao, etc.
  final String plateFormatted; // e.g. DHAKA METRO-THA 11-2233
  final String? plateCity;
  final String? plateSeries;
  final String? plateClass;
  final String? plateSerial;
  final String? plateRawText;
  final bool isPlateManual;
  final String? driverName;
  final String? driverPhone;
  final String? notes;
  final String? platePhotoUrl;
  final String? screenshotUrl;
  final List<String> guardianIds;
  final List<String> guardianEmails;
  final Map<String, dynamic> startLocation;
  final String? startAddress;
  final Map<String, dynamic>? destination;
  final int? expectedMinutes;
  final RideStatus status;
  final DateTime createdAt;
  final DateTime? endedAt;
  final String? linkedIncidentId;
  final Map<String, dynamic>? currentLocation;
  final DateTime? lastUpdatedAt;
  final int? batteryLevel;
  final List<Map<String, dynamic>> recentTrail;

  const RideCheckinModel({
    required this.id,
    required this.userId,
    required this.userName,
    this.userPhone,
    required this.rideType,
    this.appName,
    required this.plateFormatted,
    this.plateCity,
    this.plateSeries,
    this.plateClass,
    this.plateSerial,
    this.plateRawText,
    this.isPlateManual = true,
    this.driverName,
    this.driverPhone,
    this.notes,
    this.platePhotoUrl,
    this.screenshotUrl,
    required this.guardianIds,
    this.guardianEmails = const [],
    required this.startLocation,
    this.startAddress,
    this.destination,
    this.expectedMinutes,
    this.status = RideStatus.active,
    required this.createdAt,
    this.endedAt,
    this.linkedIncidentId,
    this.currentLocation,
    this.lastUpdatedAt,
    this.batteryLevel,
    this.recentTrail = const [],
  });

  bool get isActive => status == RideStatus.active;
  bool get isOverdue => status == RideStatus.overdue;

  double get startLat => (startLocation['latitude'] as num?)?.toDouble() ?? 0.0;
  double get startLng => (startLocation['longitude'] as num?)?.toDouble() ?? 0.0;

  double get currentLat =>
      (currentLocation?['latitude'] as num?)?.toDouble() ?? startLat;
  double get currentLng =>
      (currentLocation?['longitude'] as num?)?.toDouble() ?? startLng;

  DateTime get expectedArrivalTime =>
      createdAt.add(Duration(minutes: expectedMinutes ?? 30));

  /// Converts this model to a Firestore-friendly Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'userId': userId,
      'userName': userName,
      if (userPhone != null) 'userPhone': userPhone,
      'rideType': rideType,
      if (appName != null) 'appName': appName,
      'plateFormatted': plateFormatted,
      if (plateCity != null) 'plateCity': plateCity,
      if (plateSeries != null) 'plateSeries': plateSeries,
      if (plateClass != null) 'plateClass': plateClass,
      if (plateSerial != null) 'plateSerial': plateSerial,
      if (plateRawText != null) 'plateRawText': plateRawText,
      'isPlateManual': isPlateManual,
      if (driverName != null) 'driverName': driverName,
      if (driverPhone != null) 'driverPhone': driverPhone,
      if (notes != null) 'notes': notes,
      if (platePhotoUrl != null) 'platePhotoUrl': platePhotoUrl,
      if (screenshotUrl != null) 'screenshotUrl': screenshotUrl,
      'guardianIds': guardianIds,
      'guardianEmails': guardianEmails,
      'startLocation': startLocation,
      if (startAddress != null) 'startAddress': startAddress,
      if (destination != null) 'destination': destination,
      if (expectedMinutes != null) 'expectedMinutes': expectedMinutes,
      'status': status.name,
      'createdAt': Timestamp.fromDate(createdAt),
      if (endedAt != null) 'endedAt': Timestamp.fromDate(endedAt!),
      if (linkedIncidentId != null) 'linkedIncidentId': linkedIncidentId,
      if (currentLocation != null) 'currentLocation': currentLocation,
      if (lastUpdatedAt != null) 'lastUpdatedAt': Timestamp.fromDate(lastUpdatedAt!),
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
      'recentTrail': recentTrail,
    };
  }

  /// Parses a Firestore document snapshot map into a [RideCheckinModel]
  factory RideCheckinModel.fromMap(Map<String, dynamic> map, String docId) {
    DateTime parseDate(dynamic value, DateTime fallback) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String) return DateTime.tryParse(value) ?? fallback;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      return fallback;
    }

    final now = DateTime.now();

    List<Map<String, dynamic>> parseTrail(dynamic raw) {
      if (raw is List) {
        return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return [];
    }

    return RideCheckinModel(
      id: docId.isNotEmpty ? docId : (map['id']?.toString() ?? ''),
      userId: map['userId']?.toString() ?? '',
      userName: map['userName']?.toString() ?? 'Traveler',
      userPhone: map['userPhone']?.toString(),
      rideType: map['rideType']?.toString() ?? 'Ride',
      appName: map['appName']?.toString(),
      plateFormatted: map['plateFormatted']?.toString() ?? 'Vehicle Plate',
      plateCity: map['plateCity']?.toString(),
      plateSeries: map['plateSeries']?.toString(),
      plateClass: map['plateClass']?.toString(),
      plateSerial: map['plateSerial']?.toString(),
      plateRawText: map['plateRawText']?.toString(),
      isPlateManual: map['isPlateManual'] == true,
      driverName: map['driverName']?.toString(),
      driverPhone: map['driverPhone']?.toString(),
      notes: map['notes']?.toString(),
      platePhotoUrl: map['platePhotoUrl']?.toString(),
      screenshotUrl: map['screenshotUrl']?.toString(),
      guardianIds: List<String>.from(map['guardianIds'] ?? []),
      guardianEmails: List<String>.from(map['guardianEmails'] ?? []),
      startLocation: Map<String, dynamic>.from(map['startLocation'] ?? {}),
      startAddress: map['startAddress']?.toString(),
      destination: map['destination'] != null ? Map<String, dynamic>.from(map['destination']) : null,
      expectedMinutes: (map['expectedMinutes'] as num?)?.toInt(),
      status: RideStatus.fromString(map['status']?.toString()),
      createdAt: parseDate(map['createdAt'], now),
      endedAt: map['endedAt'] != null ? parseDate(map['endedAt'], now) : null,
      linkedIncidentId: map['linkedIncidentId']?.toString(),
      currentLocation: map['currentLocation'] != null
          ? Map<String, dynamic>.from(map['currentLocation'])
          : null,
      lastUpdatedAt: map['lastUpdatedAt'] != null
          ? parseDate(map['lastUpdatedAt'], now)
          : null,
      batteryLevel: (map['batteryLevel'] as num?)?.toInt(),
      recentTrail: parseTrail(map['recentTrail']),
    );
  }

  RideCheckinModel copyWith({
    String? id,
    String? userId,
    String? userName,
    String? userPhone,
    String? rideType,
    String? appName,
    String? plateFormatted,
    String? plateCity,
    String? plateSeries,
    String? plateClass,
    String? plateSerial,
    String? plateRawText,
    bool? isPlateManual,
    String? driverName,
    String? driverPhone,
    String? notes,
    String? platePhotoUrl,
    String? screenshotUrl,
    List<String>? guardianIds,
    List<String>? guardianEmails,
    Map<String, dynamic>? startLocation,
    String? startAddress,
    Map<String, dynamic>? destination,
    int? expectedMinutes,
    RideStatus? status,
    DateTime? createdAt,
    DateTime? endedAt,
    String? linkedIncidentId,
    Map<String, dynamic>? currentLocation,
    DateTime? lastUpdatedAt,
    int? batteryLevel,
    List<Map<String, dynamic>>? recentTrail,
  }) {
    return RideCheckinModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userPhone: userPhone ?? this.userPhone,
      rideType: rideType ?? this.rideType,
      appName: appName ?? this.appName,
      plateFormatted: plateFormatted ?? this.plateFormatted,
      plateCity: plateCity ?? this.plateCity,
      plateSeries: plateSeries ?? this.plateSeries,
      plateClass: plateClass ?? this.plateClass,
      plateSerial: plateSerial ?? this.plateSerial,
      plateRawText: plateRawText ?? this.plateRawText,
      isPlateManual: isPlateManual ?? this.isPlateManual,
      driverName: driverName ?? this.driverName,
      driverPhone: driverPhone ?? this.driverPhone,
      notes: notes ?? this.notes,
      platePhotoUrl: platePhotoUrl ?? this.platePhotoUrl,
      screenshotUrl: screenshotUrl ?? this.screenshotUrl,
      guardianIds: guardianIds ?? this.guardianIds,
      guardianEmails: guardianEmails ?? this.guardianEmails,
      startLocation: startLocation ?? this.startLocation,
      startAddress: startAddress ?? this.startAddress,
      destination: destination ?? this.destination,
      expectedMinutes: expectedMinutes ?? this.expectedMinutes,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      endedAt: endedAt ?? this.endedAt,
      linkedIncidentId: linkedIncidentId ?? this.linkedIncidentId,
      currentLocation: currentLocation ?? this.currentLocation,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      recentTrail: recentTrail ?? this.recentTrail,
    );
  }
}
