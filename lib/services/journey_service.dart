import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';
import '../models/activity_model.dart';
import '../models/journey_model.dart';
import 'activity_service.dart';
import 'auth_service.dart';
import 'background_service.dart';
import 'contact_service.dart';
import 'emergency_service.dart';
import 'live_tracking_service.dart';
import 'notification_service.dart';

/// Categories of safety triggers evaluated by the Safe Journey monitor loop
enum JourneySafetyTriggerType {
  delay,
  deviation,
  inactivity,
  gpsLost,
}

/// Represents an identified safety issue requiring Dead-Man's Switch confirmation
class JourneySafetyTrigger {
  final JourneySafetyTriggerType type;
  final String title;
  final String reason;

  const JourneySafetyTrigger({
    required this.type,
    required this.title,
    required this.reason,
  });

  @override
  String toString() => 'JourneySafetyTrigger($type: $reason)';
}

/// Reactive state representing an active 60-second safety check countdown
class SafetyCheckState {
  final JourneySafetyTrigger trigger;
  final DateTime triggeredAt;
  final int secondsRemaining;

  const SafetyCheckState({
    required this.trigger,
    required this.triggeredAt,
    required this.secondsRemaining,
  });

  SafetyCheckState copyWith({int? secondsRemaining}) {
    return SafetyCheckState(
      trigger: trigger,
      triggeredAt: triggeredAt,
      secondsRemaining: secondsRemaining ?? this.secondsRemaining,
    );
  }
}

/// Central service managing Safe Journey monitoring, Dead-Man's Switch countdowns,
/// and automated emergency escalation.
class JourneyService {
  JourneyService._internal();

  /// Singleton instance
  static final JourneyService instance = JourneyService._internal();

  static const String prefKeyActiveJourneyId = 'active_journey_id';
  static const String prefKeySirenOnAutoSos = 'pref_siren_on_auto_sos';
  static const double earthRadiusMeters = 6371000.0;

  final Telephony _telephony = Telephony.instance;

  /// Reactive notifier holding the current active journey model (or null)
  final ValueNotifier<JourneyModel?> activeJourneyNotifier =
      ValueNotifier<JourneyModel?>(null);

  /// Reactive notifier holding the active 60s Dead-Man's Switch safety check (or null)
  final ValueNotifier<SafetyCheckState?> activeSafetyCheckNotifier =
      ValueNotifier<SafetyCheckState?>(null);

  JourneyModel? get activeJourney => activeJourneyNotifier.value;
  bool get isJourneyActive => activeJourney != null && activeJourney!.isActive;

  Timer? _monitorTimer;
  Timer? _countdownTimer;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _journeyDocSub;

  final Map<JourneySafetyTriggerType, DateTime> _triggerCooldowns = {};
  final List<double> _recentDistancesToDest = [];
  final List<Map<String, dynamic>> _recentLocationTrail = [];

  // ─────────────────────────────────────────────────────────────
  //  PURE STATIC GEO-MATH & TRIGGER FUNCTIONS (100% UNIT TESTABLE)
  // ─────────────────────────────────────────────────────────────

  /// Calculates great-circle distance between two GPS coordinates in meters.
  static double haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final dLat = (lat2 - lat1) * (math.pi / 180.0);
    final dLon = (lon2 - lon1) * (math.pi / 180.0);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (math.pi / 180.0)) *
            math.cos(lat2 * (math.pi / 180.0)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Calculates perpendicular cross-track distance in meters from a [point]
  /// to the great-circle path between [start] and [destination].
  static double crossTrackDistance({
    required double pointLat,
    required double pointLon,
    required double startLat,
    required double startLon,
    required double destLat,
    required double destLon,
  }) {
    // If start and destination are effectively identical, return direct distance
    final pathLength = haversineDistance(startLat, startLon, destLat, destLon);
    if (pathLength < 1.0) {
      return haversineDistance(pointLat, pointLon, startLat, startLon);
    }

    final pLat = pointLat * (math.pi / 180.0);
    final pLon = pointLon * (math.pi / 180.0);
    final sLat = startLat * (math.pi / 180.0);
    final sLon = startLon * (math.pi / 180.0);
    final dLat = destLat * (math.pi / 180.0);
    final dLon = destLon * (math.pi / 180.0);

    final d13 = haversineDistance(startLat, startLon, pointLat, pointLon) / earthRadiusMeters;

    final y12 = math.sin(dLon - sLon) * math.cos(dLat);
    final x12 = math.cos(sLat) * math.sin(dLat) -
        math.sin(sLat) * math.cos(dLat) * math.cos(dLon - sLon);
    final theta12 = math.atan2(y12, x12);

    final y13 = math.sin(pLon - sLon) * math.cos(pLat);
    final x13 = math.cos(sLat) * math.sin(pLat) -
        math.sin(sLat) * math.cos(pLat) * math.cos(pLon - sLon);
    final theta13 = math.atan2(y13, x13);

    final dxt = math.asin(math.sin(d13) * math.sin(theta13 - theta12));
    return (dxt * earthRadiusMeters).abs();
  }

  /// Estimates walking duration in minutes for a given distance in meters (default 5.0 km/h).
  static int estimateWalkingDurationMinutes(
    double distanceMeters, [
    double speedKmH = 5.0,
  ]) {
    if (distanceMeters <= 0) return 1;
    final hours = (distanceMeters / 1000.0) / speedKmH;
    final minutes = (hours * 60.0).round();
    return math.max(1, minutes);
  }

  /// Determines whether the user has arrived within [thresholdMeters] (default 100m) of destination.
  static bool isArrived({
    required double currentLat,
    required double currentLon,
    required double destLat,
    required double destLon,
    double thresholdMeters = 100.0,
  }) {
    return haversineDistance(currentLat, currentLon, destLat, destLon) <= thresholdMeters;
  }

  /// Evaluates whether the last [requiredCount] consecutive distance measurements
  /// strictly increased (indicating user is actively moving away from destination).
  static bool hasConsecutiveDistanceIncreases(
    List<double> recentDistancesToDest, [
    int requiredCount = 4,
  ]) {
    if (recentDistancesToDest.length < requiredCount + 1) return false;
    final startIdx = recentDistancesToDest.length - requiredCount - 1;
    for (int i = startIdx; i < recentDistancesToDest.length - 1; i++) {
      if (recentDistancesToDest[i + 1] <= recentDistancesToDest[i] + 5.0) {
        return false;
      }
    }
    return true;
  }

  /// Pure, testable helper evaluating all safety trigger conditions against cooldowns.
  static JourneySafetyTrigger? evaluateSafetyTriggers({
    required DateTime now,
    required DateTime startedAt,
    required DateTime expectedArrivalAt,
    required DateTime lastLocationTime,
    required double distanceToDest,
    required double crossTrackDist,
    required double distanceMovedInLast10Min,
    required List<double> recentDistancesToDest,
    required Map<JourneySafetyTriggerType, DateTime> cooldowns,
    int delayGraceMinutes = 5,
    double deviationCrossTrackThreshold = 500.0,
    double inactivityDistanceThreshold = 30.0,
    int inactivityTimeElapsedMinutes = 10,
    int gpsLostThresholdMinutes = 5,
    int cooldownMinutes = 10,
  }) {
    bool isTriggerOnCooldown(JourneySafetyTriggerType type) {
      final lastFired = cooldowns[type];
      if (lastFired == null) return false;
      return now.difference(lastFired).inMinutes < cooldownMinutes;
    }

    // 1. Check GPS Lost Trigger (no fix in > 5 min)
    if (!isTriggerOnCooldown(JourneySafetyTriggerType.gpsLost)) {
      if (now.difference(lastLocationTime).inMinutes >= gpsLostThresholdMinutes) {
        return const JourneySafetyTrigger(
          type: JourneySafetyTriggerType.gpsLost,
          title: 'GPS Signal Lost',
          reason: 'No location updates received in over 5 minutes. Are you safe?',
        );
      }
    }

    // 2. Check Delay Trigger (current time > expected arrival + 5 min grace)
    if (!isTriggerOnCooldown(JourneySafetyTriggerType.delay)) {
      if (now.isAfter(expectedArrivalAt.add(Duration(minutes: delayGraceMinutes)))) {
        final delayedBy = now.difference(expectedArrivalAt).inMinutes;
        return JourneySafetyTrigger(
          type: JourneySafetyTriggerType.delay,
          title: 'Arrival Delay Detected',
          reason: 'You are $delayedBy minutes past your estimated arrival time. Please confirm you are safe.',
        );
      }
    }

    // 3. Check Deviation Trigger (> 500m off path OR 4 consecutive distance increases)
    if (!isTriggerOnCooldown(JourneySafetyTriggerType.deviation)) {
      if (crossTrackDist > deviationCrossTrackThreshold) {
        return JourneySafetyTrigger(
          type: JourneySafetyTriggerType.deviation,
          title: 'Route Deviation Detected',
          reason: 'You are ${crossTrackDist.round()}m away from your intended route. Are you okay?',
        );
      }
      if (hasConsecutiveDistanceIncreases(recentDistancesToDest, 4)) {
        return const JourneySafetyTrigger(
          type: JourneySafetyTriggerType.deviation,
          title: 'Moving Away from Destination',
          reason: 'Your distance to destination has steadily increased. Please confirm your safety.',
        );
      }
    }

    // 4. Check Inactivity Trigger (moved < 30m in last 10 min, after at least 10 min of journey)
    if (!isTriggerOnCooldown(JourneySafetyTriggerType.inactivity)) {
      if (now.difference(startedAt).inMinutes >= inactivityTimeElapsedMinutes &&
          distanceMovedInLast10Min < inactivityDistanceThreshold) {
        return const JourneySafetyTrigger(
          type: JourneySafetyTriggerType.inactivity,
          title: 'Prolonged Inactivity Detected',
          reason: 'You have stayed in the same spot for 10 minutes. Please tap to confirm you are safe.',
        );
      }
    }

    return null;
  }

  // ─────────────────────────────────────────────────────────────
  //  LIFECYCLE MANAGEMENT
  // ─────────────────────────────────────────────────────────────

  /// Restores active journey from SharedPreferences on app startup
  Future<void> restoreActiveJourney() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(prefKeyActiveJourneyId);
      if (savedId != null && savedId.isNotEmpty) {
        debugPrint('[JourneyService] 🔄 Restoring active journey session: $savedId');
        await _attachToJourneyDoc(savedId);
      }
    } catch (e) {
      debugPrint('[JourneyService] Error restoring active journey: $e');
    }
  }

  Future<void> _attachToJourneyDoc(String journeyId) async {
    _journeyDocSub?.cancel();
    _journeyDocSub = FirebaseFirestore.instance
        .collection('journeys')
        .doc(journeyId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || snap.data() == null) {
        _clearLocalSession();
        return;
      }
      final model = JourneyModel.fromMap(snap.data()!, snap.id);
      activeJourneyNotifier.value = model;

      if (!model.isActive) {
        _cleanupMonitor();
      } else if (_monitorTimer == null || !_monitorTimer!.isActive) {
        _startMonitorLoop();
      }
    }, onError: (err) {
      debugPrint('[JourneyService] Error listening to journey doc: $err');
    });
  }

  /// Starts a new monitored Safe Journey
  Future<JourneyModel?> startJourney({
    required Map<String, dynamic> destination,
    int? customEstimatedMinutes,
    bool notifySms = false,
    List<String>? guardianUids,
    List<String>? guardianEmails,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Authentication required to start a Safe Journey');
    }

    // 1. Get current position for start location
    Position? startPos = await Geolocator.getLastKnownPosition();
    try {
      startPos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 4),
        ),
      ).timeout(const Duration(seconds: 4));
    } catch (_) {}

    final startLat = startPos?.latitude ?? 23.8103;
    final startLng = startPos?.longitude ?? 90.4125;

    final destLat = (destination['latitude'] as num?)?.toDouble() ?? startLat;
    final destLng = (destination['longitude'] as num?)?.toDouble() ?? startLng;
    final destLabel = destination['label']?.toString() ?? 'Destination';

    final distanceMeters = haversineDistance(startLat, startLng, destLat, destLng);
    final durationMinutes = customEstimatedMinutes ?? estimateWalkingDurationMinutes(distanceMeters);

    final now = DateTime.now();
    final expectedArrival = now.add(Duration(minutes: durationMinutes));

    final docRef = FirebaseFirestore.instance.collection('journeys').doc();
    final journeyId = docRef.id;

    final startLocationMap = {
      'latitude': startLat,
      'longitude': startLng,
      'address': 'Current Location',
      'googleMapsUrl': EmergencyService.instance.generateGoogleMapsUrl(startLat, startLng),
    };

    final destinationMap = {
      'latitude': destLat,
      'longitude': destLng,
      'label': destLabel,
      'address': destination['address'] ?? destLabel,
      'googleMapsUrl': EmergencyService.instance.generateGoogleMapsUrl(destLat, destLng),
    };

    final journey = JourneyModel(
      id: journeyId,
      ownerId: user.uid,
      ownerName: AuthService.instance.displayName,
      ownerPhone: AuthService.instance.currentProfile.phone,
      guardianUids: guardianUids ?? [],
      guardianEmails: guardianEmails ?? [],
      status: JourneyStatus.active,
      startLocation: startLocationMap,
      destination: destinationMap,
      startedAt: now,
      expectedArrivalAt: expectedArrival,
      currentLocation: startLocationMap,
      lastUpdatedAt: now,
      startSmsSent: notifySms,
    );

    // Save to Firestore
    await docRef.set(journey.toMap());

    // Save active ID locally
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKeyActiveJourneyId, journeyId);

    activeJourneyNotifier.value = journey;
    _recentDistancesToDest.clear();
    _recentDistancesToDest.add(distanceMeters);
    _recentLocationTrail.clear();
    _recentLocationTrail.add({'lat': startLat, 'lng': startLng, 'time': now});

    // 2. Start Live Tracking Service
    await LiveTrackingService.instance.startTrackingSession(
      sessionType: 'journey',
      documentId: journeyId,
      initialPosition: startPos,
    );

    // 3. Start Background Foreground Notification Service
    await BackgroundServiceManager.instance.startService(
      title: '🚶 Safe Journey Active',
      content: 'Heading to $destLabel (ETA: ${expectedArrival.hour}:${expectedArrival.minute.toString().padLeft(2, '0')})',
    );

    // 4. Send start SMS if requested
    if (notifySms) {
      _sendJourneySms(
        isStart: true,
        destLabel: destLabel,
        expectedArrival: expectedArrival,
        mapUrl: destinationMap['googleMapsUrl'],
      );
    }

    // 5. Start monitor loop
    await _attachToJourneyDoc(journeyId);
    _startMonitorLoop();

    // 6. Log activity
    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.location,
        title: 'Safe Journey Started',
        subtitle: 'Destination: $destLabel • ETA: $durationMinutes min',
        timestamp: now,
      ),
    );

    return journey;
  }

  void _sendJourneySms({
    required bool isStart,
    required String destLabel,
    DateTime? expectedArrival,
    String? mapUrl,
  }) async {
    final phoneNumbers = await ContactService.instance.getEmergencyPhoneNumbers();
    if (phoneNumbers.isEmpty) return;

    final userName = AuthService.instance.displayName;
    final String message;

    if (isStart) {
      final etaStr = expectedArrival != null
          ? '${expectedArrival.hour == 0 ? 12 : (expectedArrival.hour > 12 ? expectedArrival.hour - 12 : expectedArrival.hour)}:${expectedArrival.minute.toString().padLeft(2, '0')} ${expectedArrival.hour >= 12 ? 'PM' : 'AM'}'
          : 'soon';
      message = '$userName started a safe journey to $destLabel. ETA: $etaStr. Live tracking active.';
    } else {
      message = '$userName has arrived safely at $destLabel.';
    }

    for (final phone in phoneNumbers) {
      try {
        await _telephony.sendSms(
          to: phone,
          message: message,
          isMultipart: false,
        );
      } catch (e) {
        debugPrint('[JourneyService] Failed to send journey SMS to $phone: $e');
      }
    }
  }

  void _startMonitorLoop() {
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _performMonitorCheck();
    });
  }

  /// Periodic tick evaluating arrival, deviation, inactivity, and delay
  Future<void> _performMonitorCheck() async {
    final journey = activeJourney;
    if (journey == null || !journey.isActive) return;

    // Fetch current position
    Position? position = await Geolocator.getLastKnownPosition();
    try {
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 3),
        ),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}

    final now = DateTime.now();
    final curLat = position?.latitude ?? journey.currentLat;
    final curLng = position?.longitude ?? journey.currentLng;

    // Check Arrival (<= 100m)
    final distanceToDest = haversineDistance(curLat, curLng, journey.destinationLat, journey.destinationLng);
    if (distanceToDest <= 100.0) {
      debugPrint('[JourneyService] 🎯 User arrived within ${distanceToDest.round()}m of destination!');
      await completeJourney();
      return;
    }

    _recentDistancesToDest.add(distanceToDest);
    if (_recentDistancesToDest.length > 10) _recentDistancesToDest.removeAt(0);

    // Track movement history
    _recentLocationTrail.add({'lat': curLat, 'lng': curLng, 'time': now});
    _recentLocationTrail.removeWhere((entry) =>
        now.difference(entry['time'] as DateTime).inMinutes > 15);

    // Compute distance moved in last 10 minutes
    double distanceMovedInLast10Min = 0.0;
    if (_recentLocationTrail.length >= 2) {
      final oldestIn10Min = _recentLocationTrail.firstWhere(
        (e) => now.difference(e['time'] as DateTime).inMinutes <= 10,
        orElse: () => _recentLocationTrail.first,
      );
      distanceMovedInLast10Min = haversineDistance(
        (oldestIn10Min['lat'] as num).toDouble(),
        (oldestIn10Min['lng'] as num).toDouble(),
        curLat,
        curLng,
      );
    }

    // Compute cross-track deviation
    final crossTrack = crossTrackDistance(
      pointLat: curLat,
      pointLon: curLng,
      startLat: journey.startLat,
      startLon: journey.startLng,
      destLat: journey.destinationLat,
      destLon: journey.destinationLng,
    );

    // Evaluate triggers
    final trigger = evaluateSafetyTriggers(
      now: now,
      startedAt: journey.startedAt,
      expectedArrivalAt: journey.expectedArrivalAt,
      lastLocationTime: journey.lastUpdatedAt,
      distanceToDest: distanceToDest,
      crossTrackDist: crossTrack,
      distanceMovedInLast10Min: distanceMovedInLast10Min,
      recentDistancesToDest: _recentDistancesToDest,
      cooldowns: _triggerCooldowns,
    );

    if (trigger != null && activeSafetyCheckNotifier.value == null) {
      debugPrint('[JourneyService] ⚠️ Safety trigger activated: ${trigger.title} (${trigger.reason})');
      _triggerSafetyCheck(trigger);
    }
  }

  /// Initiates 60-second Dead-Man's Switch countdown
  void _triggerSafetyCheck(JourneySafetyTrigger trigger) {
    _triggerCooldowns[trigger.type] = DateTime.now();

    activeSafetyCheckNotifier.value = SafetyCheckState(
      trigger: trigger,
      triggeredAt: DateTime.now(),
      secondsRemaining: 60,
    );

    // Display high-priority notification
    NotificationService.instance.showSafetyCheckNotification(
      secondsRemaining: 60,
      reason: trigger.reason,
    );

    // Start 1-second interval countdown
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final current = activeSafetyCheckNotifier.value;
      if (current == null) {
        timer.cancel();
        return;
      }

      final remaining = current.secondsRemaining - 1;
      if (remaining <= 0) {
        timer.cancel();
        activeSafetyCheckNotifier.value = null;
        _escalateDeadManSwitch(trigger);
      } else {
        activeSafetyCheckNotifier.value = current.copyWith(secondsRemaining: remaining);
      }
    });
  }

  /// User confirms they are safe during the 60s countdown
  Future<void> confirmSafe() async {
    debugPrint('[JourneyService] 🛡️ User confirmed safe in safety check.');
    _countdownTimer?.cancel();
    activeSafetyCheckNotifier.value = null;
    await NotificationService.instance.cancelSafetyCheckNotification();

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.location,
        title: 'Safety Check Confirmed',
        subtitle: 'User confirmed safety during safe journey monitor check.',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Extends expected arrival time by [minutes] (e.g. +15 min)
  Future<void> extendTime(int minutes) async {
    final journey = activeJourney;
    if (journey == null) return;

    final newExpected = journey.expectedArrivalAt.add(Duration(minutes: minutes));
    await FirebaseFirestore.instance.collection('journeys').doc(journey.id).update({
      'expectedArrivalAt': Timestamp.fromDate(newExpected),
      'lastUpdatedAt': FieldValue.serverTimestamp(),
    });

    _triggerCooldowns.remove(JourneySafetyTriggerType.delay);
    await confirmSafe();

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.location,
        title: 'Journey Extended',
        subtitle: 'Added $minutes minutes to expected arrival time.',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Dead-man's switch triggered: 60s expired with no response
  Future<void> _escalateDeadManSwitch(JourneySafetyTrigger trigger) async {
    final journey = activeJourney;
    if (journey == null) return;

    debugPrint('[JourneyService] 🚨 DEAD-MAN\'S SWITCH EXPIRED! Escalating to Emergency SOS...');
    await NotificationService.instance.cancelSafetyCheckNotification();

    // Check setting: Siren on automatic SOS (default false)
    final prefs = await SharedPreferences.getInstance();
    final playSiren = prefs.getBool(prefKeySirenOnAutoSos) ?? false;

    // Trigger full SOS pipeline
    await EmergencyService.instance.triggerEmergency(
      source: 'JOURNEY_SOS',
      customMessage: 'AUTOMATIC EMERGENCY ALERT: ${journey.ownerName} did not respond to safety check during journey to ${journey.destinationLabel}. Immediate help requested.',
      playSiren: playSiren,
      linkedJourneyId: journey.id,
    );

    // Update journey status to alert
    await FirebaseFirestore.instance.collection('journeys').doc(journey.id).update({
      'status': JourneyStatus.alert.name,
      'linkedSosAlertId': EmergencyService.instance.activeAlertId,
      'lastUpdatedAt': FieldValue.serverTimestamp(),
    });

    // Notify user on screen
    NotificationService.instance.showStatusNotification(
      id: 1001,
      title: '🚨 Emergency SOS Dispatched',
      body: 'Your guardians were alerted automatically because the safety check was unanswered.',
    );
  }

  /// Marks the journey as arrived and informs contacts if start SMS was sent
  Future<void> completeJourney() async {
    final journey = activeJourney;
    if (journey == null) return;

    debugPrint('[JourneyService] 🎉 Completing Safe Journey: ${journey.id}');

    await FirebaseFirestore.instance.collection('journeys').doc(journey.id).update({
      'status': JourneyStatus.arrived.name,
      'lastUpdatedAt': FieldValue.serverTimestamp(),
    });

    if (journey.startSmsSent) {
      _sendJourneySms(
        isStart: false,
        destLabel: journey.destinationLabel,
      );
    }

    _cleanupMonitor();
    _clearLocalSession();

    await LiveTrackingService.instance.stopTrackingSession();
    await BackgroundServiceManager.instance.stopService();

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.location,
        title: 'Safe Journey Completed',
        subtitle: 'Arrived safely at ${journey.destinationLabel}.',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Cancels the current journey
  Future<void> cancelJourney() async {
    final journey = activeJourney;
    if (journey == null) return;

    debugPrint('[JourneyService] 🛑 Cancelling Safe Journey: ${journey.id}');

    await FirebaseFirestore.instance.collection('journeys').doc(journey.id).update({
      'status': JourneyStatus.cancelled.name,
      'lastUpdatedAt': FieldValue.serverTimestamp(),
    });

    _cleanupMonitor();
    _clearLocalSession();

    await LiveTrackingService.instance.stopTrackingSession();
    await BackgroundServiceManager.instance.stopService();

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.location,
        title: 'Safe Journey Cancelled',
        subtitle: 'Journey to ${journey.destinationLabel} was cancelled by user.',
        timestamp: DateTime.now(),
      ),
    );
  }

  void _cleanupMonitor() {
    _monitorTimer?.cancel();
    _countdownTimer?.cancel();
    _journeyDocSub?.cancel();
    activeSafetyCheckNotifier.value = null;
  }

  void _clearLocalSession() async {
    activeJourneyNotifier.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefKeyActiveJourneyId);
    } catch (_) {}
  }
}
