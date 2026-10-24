import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'safety_report_service.dart';

/// Reusable singleton service managing live GPS location tracking and throttled
/// Firestore synchronization for active SOS emergencies and Safe Journeys.
///
/// **Throttling Policy:**
/// - Writes to Firestore ONLY when:
///   1. Elapsed time >= 30 seconds AND distance moved >= 25 meters, OR
///   2. Elapsed time >= 120 seconds (2-minute heartbeat regardless of movement).
/// - Writes are NEVER executed faster than every 30 seconds to conserve battery
///   and remain comfortably within free Firebase Spark plan write quotas.
class LiveTrackingService {
  LiveTrackingService._internal();

  /// Central singleton instance
  static final LiveTrackingService instance = LiveTrackingService._internal();

  final Battery _battery = Battery();
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  /// Current session type ('sos' or 'journey')
  String? _sessionType;

  /// Firestore document ID for the active session (alertId or journeyId)
  String? _documentId;

  /// Stream subscription for live device GPS positions
  StreamSubscription<Position>? _positionSubscription;

  /// Heartbeat timer ensuring writes at least once every 2 minutes
  Timer? _heartbeatTimer;

  /// Timestamp of the last successful Firestore write
  DateTime? _lastWriteTime;

  /// Coordinates recorded at the time of the last Firestore write
  double? _lastWriteLat;
  double? _lastWriteLng;

  /// Current reactive location notifier for UI and background monitors
  final ValueNotifier<Position?> currentPositionNotifier = ValueNotifier<Position?>(null);

  /// Current tracking active status notifier
  final ValueNotifier<bool> isTrackingNotifier = ValueNotifier<bool>(false);

  /// Current battery level notifier
  final ValueNotifier<int> batteryLevelNotifier = ValueNotifier<int>(100);

  /// Getter for current tracking active state
  bool get isTracking => isTrackingNotifier.value;

  /// Getter for current session document ID
  String? get activeDocumentId => _documentId;

  /// Getter for current session type
  String? get activeSessionType => _sessionType;

  /// Pure, testable helper evaluating whether a Firestore write should occur based on
  /// elapsed time, distance moved, and heartbeat intervals.
  static bool shouldWriteUpdate({
    required DateTime? lastWriteTime,
    required double? lastLat,
    required double? lastLng,
    required DateTime now,
    required double currentLat,
    required double currentLng,
  }) {
    if (lastWriteTime == null) return true;

    final elapsedSeconds = now.difference(lastWriteTime).inSeconds;
    // Enforce strict 30-second minimum interval
    if (elapsedSeconds < 30) return false;

    // Heartbeat: write regardless of distance if 2 minutes (120s) have passed
    if (elapsedSeconds >= 120) return true;

    if (lastLat == null || lastLng == null) return true;

    final distanceMeters = Geolocator.distanceBetween(lastLat, lastLng, currentLat, currentLng);
    // Write if moved at least 25 meters
    return distanceMeters >= 25.0;
  }

  /// Starts a live tracking session for an active SOS emergency or Safe Journey.
  Future<bool> startTrackingSession({
    required String sessionType, // 'sos' | 'journey'
    required String documentId,
    Position? initialPosition,
  }) async {
    if (isTracking && _documentId == documentId) {
      debugPrint('[LiveTracking] Tracking session already active for $documentId');
      return true;
    }

    // Stop any existing session before starting a new one
    await stopTrackingSession();

    _sessionType = sessionType;
    _documentId = documentId;
    _lastWriteTime = null;
    _lastWriteLat = null;
    _lastWriteLng = null;

    if (initialPosition != null) {
      currentPositionNotifier.value = initialPosition;
    }

    isTrackingNotifier.value = true;
    debugPrint('[LiveTracking] 🚀 Started $sessionType live tracking for doc: $documentId');

    // 1. Initial immediate write if an initial position is provided
    if (initialPosition != null) {
      await _syncLocationToCloud(initialPosition, force: true);
    }

    // 2. Start high-accuracy location stream with a 5m distance filter
    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (position) {
          currentPositionNotifier.value = position;
          _checkAndSyncPosition(position);
        },
        onError: (err) {
          debugPrint('[LiveTracking] Position stream error: $err');
        },
      );
    } catch (e) {
      debugPrint('[LiveTracking] Error initializing position stream: $e');
    }

    // 3. Heartbeat timer checking every 30 seconds whether a write is needed
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final currentPos = currentPositionNotifier.value;
      if (currentPos != null && isTracking) {
        _checkAndSyncPosition(currentPos);
      }
    });

    return true;
  }

  /// Evaluates throttling conditions and triggers cloud sync if met.
  void _checkAndSyncPosition(Position position) {
    // Proximity Risk Check for community hazards
    SafetyReportService.instance.evaluateAndNotifyProximityRisk(position.latitude, position.longitude);

    final now = DateTime.now();
    final shouldWrite = shouldWriteUpdate(
      lastWriteTime: _lastWriteTime,
      lastLat: _lastWriteLat,
      lastLng: _lastWriteLng,
      now: now,
      currentLat: position.latitude,
      currentLng: position.longitude,
    );

    if (shouldWrite) {
      _syncLocationToCloud(position);
    }
  }

  /// Writes updated location and battery metadata to Firestore.
  Future<void> _syncLocationToCloud(Position position, {bool force = false}) async {
    final docId = _documentId;
    final type = _sessionType;
    if (docId == null || type == null || (!isTracking && !force)) return;

    final lat = position.latitude;
    final lng = position.longitude;
    final acc = position.accuracy;
    final mapsUrl = 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';

    int batteryLevel = 100;
    try {
      batteryLevel = await _battery.batteryLevel;
      batteryLevelNotifier.value = batteryLevel;
    } catch (_) {}

    String address = 'Live Coordinates';
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng)
          .timeout(const Duration(seconds: 2), onTimeout: () => []);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final parts = [p.name, p.subLocality, p.locality]
            .where((s) => s != null && s.trim().isNotEmpty)
            .toList();
        if (parts.isNotEmpty) address = parts.join(', ');
      }
    } catch (_) {}

    final locationMap = {
      'latitude': lat,
      'longitude': lng,
      'accuracy': acc,
      'address': address,
      'googleMapsUrl': mapsUrl,
    };

    try {
      if (type == 'sos') {
        await _firestore.collection('sos_alerts').doc(docId).update({
          'liveLocation': locationMap,
          'location': locationMap,
          'latitude': lat,
          'longitude': lng,
          'google_maps_url': mapsUrl,
          'liveUpdatedAt': FieldValue.serverTimestamp(),
          'lastUpdatedAt': FieldValue.serverTimestamp(),
          'batteryLevel': batteryLevel,
          'isTrackingActive': true,
          'recentTrail': FieldValue.arrayUnion([
            {
              'latitude': lat,
              'longitude': lng,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }
          ]),
        }).timeout(const Duration(seconds: 4));
      } else if (type == 'journey') {
        await _firestore.collection('journeys').doc(docId).update({
          'currentLocation': locationMap,
          'lastUpdatedAt': FieldValue.serverTimestamp(),
          'batteryLevel': batteryLevel,
        }).timeout(const Duration(seconds: 4));
      }

      _lastWriteTime = DateTime.now();
      _lastWriteLat = lat;
      _lastWriteLng = lng;
      debugPrint('[LiveTracking] 📍 Synced location to $type/$docId (battery: $batteryLevel%)');
    } catch (e) {
      debugPrint('[LiveTracking] Notice syncing to Firestore: $e');
    }
  }

  /// Stops tracking cleanly, cancels subscriptions, and marks session as inactive.
  Future<void> stopTrackingSession({bool markCloudInactive = true}) async {
    final docId = _documentId;
    final type = _sessionType;

    _positionSubscription?.cancel();
    _positionSubscription = null;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    isTrackingNotifier.value = false;
    _documentId = null;
    _sessionType = null;
    _lastWriteTime = null;
    _lastWriteLat = null;
    _lastWriteLng = null;

    if (markCloudInactive && docId != null && type == 'sos') {
      try {
        await _firestore.collection('sos_alerts').doc(docId).update({
          'isTrackingActive': false,
          'lastUpdatedAt': FieldValue.serverTimestamp(),
        }).timeout(const Duration(seconds: 3));
        debugPrint('[LiveTracking] Marked isTrackingActive: false for $docId');
      } catch (_) {}
    }

    debugPrint('[LiveTracking] 🛑 Live tracking stopped.');
  }

  /// Checks Firestore on app launch: if the current user has an active SOS alert or journey,
  /// automatically resumes tracking.
  Future<void> autoResumeActiveSessions() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // 1. Check for active SOS alert where current user is sender
      final activeSosSnap = await _firestore
          .collection('sos_alerts')
          .where('senderId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'active')
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 3));

      if (activeSosSnap.docs.isNotEmpty) {
        final alertDoc = activeSosSnap.docs.first;
        final alertId = alertDoc.id;
        debugPrint('[LiveTracking] 🔄 Auto-resuming active SOS tracking for $alertId');
        final currentPos = await Geolocator.getLastKnownPosition();
        await startTrackingSession(
          sessionType: 'sos',
          documentId: alertId,
          initialPosition: currentPos,
        );
        return;
      }

      // 2. Check for active Safe Journey where current user is owner
      final activeJourneySnap = await _firestore
          .collection('journeys')
          .where('ownerId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'active')
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 3));

      if (activeJourneySnap.docs.isNotEmpty) {
        final journeyDoc = activeJourneySnap.docs.first;
        final journeyId = journeyDoc.id;
        debugPrint('[LiveTracking] 🔄 Auto-resuming active Journey tracking for $journeyId');
        final currentPos = await Geolocator.getLastKnownPosition();
        await startTrackingSession(
          sessionType: 'journey',
          documentId: journeyId,
          initialPosition: currentPos,
        );
      }
    } catch (e) {
      debugPrint('[LiveTracking] Notice checking active sessions: $e');
    }
  }
}
