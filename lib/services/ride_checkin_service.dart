import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';

import '../models/activity_model.dart';
import '../models/ride_checkin.dart';
import 'activity_service.dart';
import 'auth_service.dart';
import 'background_service.dart';
import 'contact_service.dart';
import 'emergency_service.dart';
import 'journey_service.dart';
import 'live_tracking_service.dart';
import 'notification_service.dart';

/// Central Singleton Service managing Ride Safety Check-in sessions,
/// image compression, Firestore persistence, live GPS tracking, SMS fallback,
/// overdue dead-man's switch escalation, and guardian synchronization.
class RideCheckinService {
  RideCheckinService._internal();
  static final RideCheckinService instance = RideCheckinService._internal();

  static const String prefKeyActiveRideId = 'active_ride_checkin_id';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final Telephony _telephony = Telephony.instance;

  /// Reactive notifier holding the currently active ride check-in model (or null)
  final ValueNotifier<RideCheckinModel?> activeRideNotifier =
      ValueNotifier<RideCheckinModel?>(null);

  /// Synchronous getter
  RideCheckinModel? get activeRide => activeRideNotifier.value;
  bool get isRideActive => activeRide != null && activeRide!.isActive;

  Timer? _overdueMonitorTimer;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _activeRideDocSub;

  /// Compresses an image file to ~200-300 KB with max dimension 1280px
  Future<File> compressImage(File file, {String suffix = 'comp'}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final targetPath =
          '${tempDir.path}/ride_${DateTime.now().millisecondsSinceEpoch}_$suffix.jpg';

      final XFile? result = await FlutterImageCompress.compressAndGetFile(
        file.absolute.path,
        targetPath,
        quality: 75,
        minWidth: 1280,
        minHeight: 1280,
        format: CompressFormat.jpeg,
      );

      if (result != null) {
        return File(result.path);
      }
      return file;
    } catch (e) {
      debugPrint('[RideCheckinService] Compression notice: $e; using original file');
      return file;
    }
  }

  /// Uploads an image to Firebase Storage under `ride_checkins/{userId}/{rideId}/{filename}`
  Future<String?> uploadRideImage({
    required String userId,
    required String rideId,
    required File file,
    required String filename,
  }) async {
    try {
      final compressed = await compressImage(file, suffix: filename);
      final ref = _storage.ref().child('ride_checkins/$userId/$rideId/$filename');
      final metadata = SettableMetadata(contentType: 'image/jpeg');

      final uploadTask = ref.putFile(compressed, metadata);
      final snapshot = await uploadTask.timeout(const Duration(seconds: 15));
      final downloadUrl = await snapshot.ref.getDownloadURL();
      debugPrint('[RideCheckinService] 📸 Uploaded $filename -> $downloadUrl');
      return downloadUrl;
    } catch (e) {
      debugPrint('[RideCheckinService] ❌ Failed to upload image $filename: $e');
      return null;
    }
  }

  /// Creates and starts a new Ride Safety Check-in session.
  Future<RideCheckinModel> startRideCheckin({
    required String rideType,
    String? appName,
    required String plateFormatted,
    String? plateCity,
    String? plateSeries,
    String? plateClass,
    String? plateSerial,
    String? plateRawText,
    bool isPlateManual = false,
    String? driverName,
    String? driverPhone,
    String? notes,
    File? platePhotoFile,
    File? screenshotFile,
    bool shareScreenshot = false,
    required List<String> guardianIds,
    required List<String> guardianEmails,
    required List<String> guardianPhones,
    Map<String, dynamic>? destination,
    int? expectedMinutes,
    Position? initialPosition,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to start a Ride Check-in.');
    }

    final userId = user.uid;
    final profileName = AuthService.instance.displayName;
    final userName = user.displayName ?? (profileName.isNotEmpty ? profileName : 'Traveler');
    final userPhone = user.phoneNumber ?? AuthService.instance.phone;

    // 1. Get GPS coordinates
    Position? position = initialPosition;
    position ??= await Geolocator.getLastKnownPosition();
    try {
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 3),
        ),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}

    final lat = position?.latitude ?? 23.8103;
    final lng = position?.longitude ?? 90.4125;
    final startLocation = {
      'latitude': lat,
      'longitude': lng,
      'googleMapsUrl': 'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    };

    final docRef = _firestore.collection('ride_checkins').doc();
    final rideId = docRef.id;
    final now = DateTime.now();

    // 2. Upload photos asynchronously or in sequence
    String? platePhotoUrl;
    if (platePhotoFile != null && await platePhotoFile.exists()) {
      platePhotoUrl = await uploadRideImage(
        userId: userId,
        rideId: rideId,
        file: platePhotoFile,
        filename: 'plate.jpg',
      );
    }

    String? screenshotUrl;
    if (shareScreenshot && screenshotFile != null && await screenshotFile.exists()) {
      screenshotUrl = await uploadRideImage(
        userId: userId,
        rideId: rideId,
        file: screenshotFile,
        filename: 'screenshot.jpg',
      );
    }

    // 3. Assemble model
    final ride = RideCheckinModel(
      id: rideId,
      userId: userId,
      userName: userName,
      userPhone: userPhone.isNotEmpty ? userPhone : null,
      rideType: rideType,
      appName: appName,
      plateFormatted: plateFormatted,
      plateCity: plateCity,
      plateSeries: plateSeries,
      plateClass: plateClass,
      plateSerial: plateSerial,
      plateRawText: plateRawText,
      isPlateManual: isPlateManual,
      driverName: driverName,
      driverPhone: driverPhone,
      notes: notes,
      platePhotoUrl: platePhotoUrl,
      screenshotUrl: screenshotUrl,
      guardianIds: guardianIds,
      guardianEmails: guardianEmails,
      startLocation: startLocation,
      destination: destination,
      expectedMinutes: expectedMinutes,
      status: RideStatus.active,
      createdAt: now,
      currentLocation: startLocation,
      lastUpdatedAt: now,
      recentTrail: [
        {
          'latitude': lat,
          'longitude': lng,
          'timestamp': now.millisecondsSinceEpoch,
        }
      ],
    );

    // 4. Write to Firestore
    await docRef.set(ride.toMap());

    // 5. Save locally for persistence across app kills
    activeRideNotifier.value = ride;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyActiveRideId, rideId);
    } catch (_) {}

    // 6. Start Live GPS Tracking via existing LiveTrackingService
    await LiveTrackingService.instance.startTrackingSession(
      sessionType: 'ride',
      documentId: rideId,
      initialPosition: position,
    );

    // 7. Start Foreground Background Service
    try {
      await BackgroundServiceManager.instance.startService(
        title: '🚗 Ride Safety Active ($rideType)',
        content: '$plateFormatted • Tracking live location',
      );
    } catch (_) {}

    // 8. SMS Fallback to selected primary guardians
    _sendRideStartSms(
      userName: userName,
      rideType: rideType,
      plateFormatted: plateFormatted,
      phones: guardianPhones,
      lat: lat,
      lng: lng,
    );

    // 9. Attach real-time Firestore listener and start overdue timer
    _attachRideListener(rideId);
    _startOverdueMonitor(ride);

    // 10. Log Activity
    ActivityService.instance.logActivity(
      ActivityItem(
        id: 'ride_${now.millisecondsSinceEpoch}',
        type: ActivityType.ride,
        title: 'Ride Check-in Started',
        subtitle: '$rideType ($plateFormatted) • Guardians alerted',
        timestamp: now,
      ),
    );

    debugPrint('[RideCheckinService] 🚀 Ride Check-in started: $rideId');
    return ride;
  }

  /// Sends background SMS fallback to selected guardians
  Future<void> _sendRideStartSms({
    required String userName,
    required String rideType,
    required String plateFormatted,
    required List<String> phones,
    required double lat,
    required double lng,
  }) async {
    if (phones.isEmpty) return;
    final mapUrl = 'https://maps.google.com/?q=$lat,$lng';
    final message =
        'Ride Check-in: $userName started a $rideType ride. Vehicle: $plateFormatted. Location: $mapUrl';

    for (final phone in phones) {
      final formatted = EmergencyService.instance.formatRecipientPhone(phone);
      if (formatted.isNotEmpty) {
        try {
          await _telephony.sendSms(
            to: formatted,
            message: message,
            isMultipart: true,
          );
          debugPrint('[RideCheckinService] ✉️ Sent Ride Check-in SMS to $formatted');
        } catch (e) {
          debugPrint('[RideCheckinService] ❌ Failed to send SMS to $formatted: $e');
        }
      }
    }
  }

  /// Marks the active ride as completed ("Arrived Safely")
  Future<void> arriveSafely({String? rideId}) async {
    final targetId = rideId ?? activeRide?.id;
    if (targetId == null) return;

    final currentRide = activeRide;
    final now = DateTime.now();

    // 1. Update Firestore
    try {
      await _firestore.collection('ride_checkins').doc(targetId).update({
        'status': RideStatus.arrived.name,
        'endedAt': FieldValue.serverTimestamp(),
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[RideCheckinService] Error marking arrived in Firestore: $e');
    }

    // 2. Stop tracking & background service
    await LiveTrackingService.instance.stopTrackingSession();
    try {
      await BackgroundServiceManager.instance.stopService();
    } catch (_) {}

    // 3. Clear local state
    _overdueMonitorTimer?.cancel();
    _overdueMonitorTimer = null;
    _activeRideDocSub?.cancel();
    _activeRideDocSub = null;
    activeRideNotifier.value = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefKeyActiveRideId);
    } catch (_) {}

    // 4. Send Arrival SMS to guardians
    if (currentRide != null) {
      final userName = currentRide.userName;
      final safeMessage = '$userName has arrived safely.';
      final phoneNumbers = await ContactService.instance.getEmergencyPhoneNumbers();

      for (final phone in phoneNumbers) {
        final formatted = EmergencyService.instance.formatRecipientPhone(phone);
        if (formatted.isNotEmpty) {
          try {
            await _telephony.sendSms(
              to: formatted,
              message: safeMessage,
              isMultipart: false,
            );
          } catch (_) {}
        }
      }
    }

    // 5. Log Activity
    ActivityService.instance.logActivity(
      ActivityItem(
        id: 'ride_arrived_${now.millisecondsSinceEpoch}',
        type: ActivityType.ride,
        title: 'Arrived Safely',
        subtitle: currentRide != null
            ? '${currentRide.rideType} (${currentRide.plateFormatted}) completed safely'
            : 'Ride finished successfully',
        timestamp: now,
      ),
    );

    debugPrint('[RideCheckinService] ✅ Arrived safely for ride: $targetId');
  }

  /// Cancels an active ride
  Future<void> cancelRide({String? rideId}) async {
    final targetId = rideId ?? activeRide?.id;
    if (targetId == null) return;

    final currentRide = activeRide;
    final now = DateTime.now();

    try {
      await _firestore.collection('ride_checkins').doc(targetId).update({
        'status': RideStatus.cancelled.name,
        'endedAt': FieldValue.serverTimestamp(),
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    await LiveTrackingService.instance.stopTrackingSession();
    try {
      await BackgroundServiceManager.instance.stopService();
    } catch (_) {}

    _overdueMonitorTimer?.cancel();
    _overdueMonitorTimer = null;
    _activeRideDocSub?.cancel();
    _activeRideDocSub = null;
    activeRideNotifier.value = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefKeyActiveRideId);
    } catch (_) {}

    ActivityService.instance.logActivity(
      ActivityItem(
        id: 'ride_cancelled_${now.millisecondsSinceEpoch}',
        type: ActivityType.ride,
        title: 'Ride Cancelled',
        subtitle: currentRide != null
            ? '${currentRide.rideType} (${currentRide.plateFormatted}) cancelled'
            : 'Ride cancelled by user',
        timestamp: now,
      ),
    );

    debugPrint('[RideCheckinService] 🛑 Ride cancelled: $targetId');
  }

  /// Extends expected ride duration by additional [minutes]
  Future<void> extendRideTime(int minutes) async {
    final ride = activeRide;
    if (ride == null) return;

    final updatedMinutes = (ride.expectedMinutes ?? 30) + minutes;
    try {
      await _firestore.collection('ride_checkins').doc(ride.id).update({
        'expectedMinutes': updatedMinutes,
        'status': RideStatus.active.name,
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      });
      activeRideNotifier.value = ride.copyWith(
        expectedMinutes: updatedMinutes,
        status: RideStatus.active,
      );
    } catch (e) {
      debugPrint('[RideCheckinService] Failed to extend ride time: $e');
    }
  }

  /// Listens to the active ride document in Firestore
  void _attachRideListener(String rideId) {
    _activeRideDocSub?.cancel();
    _activeRideDocSub = _firestore
        .collection('ride_checkins')
        .doc(rideId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) {
        activeRideNotifier.value = null;
        return;
      }
      final ride = RideCheckinModel.fromMap(snapshot.data()!, snapshot.id);
      activeRideNotifier.value = ride;

      if (!ride.isActive && !ride.isOverdue) {
        _overdueMonitorTimer?.cancel();
        _overdueMonitorTimer = null;
      }
    }, onError: (e) {
      debugPrint('[RideCheckinService] Ride doc listener error: $e');
    });
  }

  /// Starts the overdue monitor checking elapsed time against expectedMinutes + 10 min grace
  void _startOverdueMonitor(RideCheckinModel ride) {
    _overdueMonitorTimer?.cancel();
    _overdueMonitorTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkOverdueState();
    });
  }

  /// Evaluates whether the ride has exceeded `expectedMinutes + 10 min grace`
  Future<void> _checkOverdueState() async {
    final ride = activeRide;
    if (ride == null || !ride.isActive || ride.expectedMinutes == null) return;

    final now = DateTime.now();
    final graceDeadline =
        ride.createdAt.add(Duration(minutes: ride.expectedMinutes! + 10));

    if (now.isAfter(graceDeadline) && ride.status == RideStatus.active) {
      debugPrint('[RideCheckinService] ⚠️ RIDE IS OVERDUE! Triggering overdue protocol...');
      // 1. Mark overdue in Firestore
      try {
        await _firestore.collection('ride_checkins').doc(ride.id).update({
          'status': RideStatus.overdue.name,
          'lastUpdatedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      // 2. Alert primary guardians via SMS fallback
      final phoneNumbers = await ContactService.instance.getEmergencyPhoneNumbers();
      final mapUrl = 'https://maps.google.com/?q=${ride.currentLat},${ride.currentLng}';
      final alertMsg =
          'OVERDUE RIDE ALERT: ${ride.userName}\'s ${ride.rideType} ride (${ride.plateFormatted}) is overdue by 10+ minutes. Last location: $mapUrl';

      for (final phone in phoneNumbers) {
        final formatted = EmergencyService.instance.formatRecipientPhone(phone);
        if (formatted.isNotEmpty) {
          try {
            await _telephony.sendSms(
              to: formatted,
              message: alertMsg,
              isMultipart: true,
            );
          } catch (_) {}
        }
      }

      // 3. Trigger 60s Dead-Man's Switch via JourneyService safety check
      JourneyService.instance.activeSafetyCheckNotifier.value = SafetyCheckState(
        trigger: const JourneySafetyTrigger(
          type: JourneySafetyTriggerType.delay,
          title: 'Ride Overdue Check-In',
          reason: 'Your ride is overdue by more than 10 minutes. Tap to confirm you are safe.',
        ),
        triggeredAt: now,
        secondsRemaining: 60,
      );

      NotificationService.instance.showSafetyCheckNotification(
        secondsRemaining: 60,
        reason: 'Ride is overdue by 10+ minutes. Please confirm you are safe.',
      );

      // Log Activity
      ActivityService.instance.logActivity(
        ActivityItem(
          id: 'ride_overdue_${now.millisecondsSinceEpoch}',
          type: ActivityType.ride,
          title: 'Ride Overdue Alert',
          subtitle: '${ride.rideType} (${ride.plateFormatted}) is overdue. Safety check triggered.',
          timestamp: now,
        ),
      );
    }
  }

  /// Automatically restores any active ride on app launch
  Future<void> autoResumeActiveRide() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final snap = await _firestore
          .collection('ride_checkins')
          .where('userId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'active')
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 4));

      if (snap.docs.isNotEmpty) {
        final doc = snap.docs.first;
        final ride = RideCheckinModel.fromMap(doc.data(), doc.id);
        activeRideNotifier.value = ride;
        _attachRideListener(ride.id);
        _startOverdueMonitor(ride);

        debugPrint('[RideCheckinService] 🔄 Auto-resumed active ride: ${ride.id}');

        // Resume Live Tracking
        final pos = await Geolocator.getLastKnownPosition();
        await LiveTrackingService.instance.startTrackingSession(
          sessionType: 'ride',
          documentId: ride.id,
          initialPosition: pos,
        );
      } else {
        // Also check if SharedPreferences has a stale active ID to clear
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(prefKeyActiveRideId);
      }
    } catch (e) {
      debugPrint('[RideCheckinService] Notice auto-resuming ride: $e');
    }
  }

  /// Stream of active ride for the user
  Stream<RideCheckinModel?> streamActiveRide(String userId) {
    return _firestore
        .collection('ride_checkins')
        .where('userId', isEqualTo: userId)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .snapshots()
        .map((snap) {
      if (snap.docs.isEmpty) return null;
      return RideCheckinModel.fromMap(snap.docs.first.data(), snap.docs.first.id);
    });
  }

  /// Stream of a specific ride by document ID
  Stream<RideCheckinModel?> streamRide(String rideId) {
    return _firestore.collection('ride_checkins').doc(rideId).snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      return RideCheckinModel.fromMap(snap.data()!, snap.id);
    });
  }
}
