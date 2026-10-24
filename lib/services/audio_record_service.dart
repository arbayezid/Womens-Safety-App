import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:telephony/telephony.dart';

import 'activity_service.dart';
import 'auth_service.dart';
import 'contact_service.dart';
import 'emergency_service.dart';
import 'location_service.dart';

/// Result envelope returned by [AudioRecordService.uploadAndDispatchAlert].
class AudioDispatchResult {
  final bool isSuccess;
  final String message;
  final String? audioUrl;
  final String? alertId;
  final int smsSentCount;
  final int totalRecipients;

  const AudioDispatchResult({
    required this.isSuccess,
    required this.message,
    this.audioUrl,
    this.alertId,
    this.smsSentCount = 0,
    this.totalRecipients = 0,
  });
}

/// Standalone isolated service handling:
/// 1. Microphone permission validation
/// 2. Audio recording lifecycle (temporary cache storage in .m4a / AAC)
/// 3. Upload to Firebase Storage under users/{currentUserId}/emergency_recordings/{timestamp}.m4a
/// 4. Dispatching Firestore SOS alert and SMS fallback to emergency contacts
/// 5. Local cache cleanup immediately after upload
class AudioRecordService {
  AudioRecordService._internal();

  /// Central singleton instance
  static final AudioRecordService instance = AudioRecordService._internal();

  final AudioRecorder _recorder = AudioRecorder();
  final Telephony _telephony = Telephony.instance;

  String? _currentLocalPath;
  Timer? _durationTimer;
  Timer? _timeoutTimer;
  int _elapsedSeconds = 0;

  /// Observable notifier for active recording duration in seconds
  final ValueNotifier<int> durationNotifier = ValueNotifier<int>(0);

  /// Observable notifier for recording state
  final ValueNotifier<bool> isRecordingNotifier = ValueNotifier<bool>(false);

  /// Current local audio file path, if recording or recently stopped
  String? get currentLocalPath => _currentLocalPath;

  /// Returns true if the device currently allows microphone recording.
  Future<bool> hasMicrophonePermission() async {
    try {
      final status = await Permission.microphone.status;
      return status.isGranted;
    } catch (e) {
      debugPrint('[AudioRecordService] Permission check error: $e');
      return false;
    }
  }

  /// Requests microphone permission and returns true if granted.
  Future<bool> requestMicrophonePermission() async {
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('[AudioRecordService] Permission request error: $e');
      return false;
    }
  }

  /// Starts recording audio locally to the device cache directory in .m4a (AAC) format.
  ///
  /// [onTimeout] is invoked when the 60-second maximum duration is reached.
  Future<bool> startRecording({VoidCallback? onTimeout}) async {
    try {
      // 1. Ensure permission
      final hasPerm = await requestMicrophonePermission();
      if (!hasPerm) {
        debugPrint('[AudioRecordService] Microphone permission not granted.');
        return false;
      }

      // If already recording, stop first
      if (await _recorder.isRecording()) {
        await cancelRecording();
      }

      // 2. Prepare temporary cache file
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${tempDir.path}/sos_recording_$timestamp.m4a';
      _currentLocalPath = filePath;

      // 3. Configure AAC-LC recording
      const config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      );

      // 4. Start recording to local file
      await _recorder.start(config, path: filePath);

      _elapsedSeconds = 0;
      durationNotifier.value = 0;
      isRecordingNotifier.value = true;

      // 5. Setup periodic 1-second elapsed timer
      _durationTimer?.cancel();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _elapsedSeconds++;
        durationNotifier.value = _elapsedSeconds;
      });

      // 6. Setup 60-second automatic timeout
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(const Duration(seconds: 60), () {
        debugPrint('[AudioRecordService] ⏱️ 60-second recording timeout reached.');
        onTimeout?.call();
      });

      debugPrint('[AudioRecordService] 🎙️ Recording started at $filePath');
      return true;
    } catch (e) {
      debugPrint('[AudioRecordService] Failed to start recording: $e');
      await cancelRecording();
      return false;
    }
  }

  /// Stops recording and returns the path to the recorded .m4a file.
  Future<String?> stopRecording() async {
    _durationTimer?.cancel();
    _durationTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    try {
      final isRec = await _recorder.isRecording();
      if (!isRec) {
        isRecordingNotifier.value = false;
        return _currentLocalPath;
      }

      final recordedPath = await _recorder.stop();
      isRecordingNotifier.value = false;
      _currentLocalPath = recordedPath ?? _currentLocalPath;
      debugPrint('[AudioRecordService] ⏹️ Recording stopped. File: $_currentLocalPath');
      return _currentLocalPath;
    } catch (e) {
      debugPrint('[AudioRecordService] Error stopping recording: $e');
      isRecordingNotifier.value = false;
      return null;
    }
  }

  /// Cancels active recording and immediately purges any temporary local audio file.
  Future<void> cancelRecording() async {
    _durationTimer?.cancel();
    _durationTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (e) {
      debugPrint('[AudioRecordService] Error cancelling recorder: $e');
    } finally {
      isRecordingNotifier.value = false;
      durationNotifier.value = 0;
      _elapsedSeconds = 0;
      await cleanupLocalCache();
    }
  }

  /// Deletes the temporary local recording file from disk.
  Future<void> cleanupLocalCache() async {
    if (_currentLocalPath != null) {
      try {
        final file = File(_currentLocalPath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[AudioRecordService] 🗑️ Cleaned up temporary local audio file: $_currentLocalPath');
        }
      } catch (e) {
        debugPrint('[AudioRecordService] Failed to delete temporary audio file: $e');
      } finally {
        _currentLocalPath = null;
      }
    }
  }

  /// Uploads the recorded audio file to Firebase Storage, reads emergency contacts
  /// and location, and dispatches the alert via Cloud Firestore and SMS fallback.
  Future<AudioDispatchResult> uploadAndDispatchAlert({
    required String filePath,
    String? customNote,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return const AudioDispatchResult(
        isSuccess: false,
        message: 'Audio recording file not found.',
      );
    }

    try {
      // 1. Resolve current user identity
      final user = FirebaseAuth.instance.currentUser;
      final currentUserId = user?.uid ?? 'guest_${DateTime.now().millisecondsSinceEpoch}';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final senderName = user?.displayName ??
          AuthService.instance.displayName.ifEmpty('Smart Safety User');
      final senderEmail = (user?.email ?? AuthService.instance.email ?? '').toLowerCase().trim();
      final senderPhone = user?.phoneNumber ?? AuthService.instance.currentProfile.phone;

      // 2. Upload to Firebase Storage: users/{currentUserId}/emergency_recordings/{timestamp}.m4a
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('users/$currentUserId/emergency_recordings/$timestamp.m4a');

      debugPrint('[AudioRecordService] ☁️ Uploading audio to: ${storageRef.fullPath} ...');

      final uploadTask = storageRef.putFile(
        file,
        SettableMetadata(
          contentType: 'audio/m4a',
          customMetadata: {
            'senderId': currentUserId,
            'senderName': senderName,
            'timestamp': timestamp.toString(),
            'source': 'Record Audio Quick Action',
          },
        ),
      );

      final snapshot = await uploadTask.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Audio upload timed out after 15 seconds.'),
      );

      final downloadUrl = await snapshot.ref.getDownloadURL();
      debugPrint('[AudioRecordService] ✅ Audio uploaded successfully. URL: $downloadUrl');

      // 3. Extract GPS Location (Read-only caller of LocationService / Geolocator)
      Position? position;
      String mapsUrl = '';
      String humanAddress = 'Live GPS Coordinates Unavailable';
      double latitude = 0.0;
      double longitude = 0.0;
      double accuracy = 0.0;

      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        ).timeout(const Duration(seconds: 4), onTimeout: () => throw TimeoutException('GPS timeout'));
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }

      if (position != null) {
        latitude = position.latitude;
        longitude = position.longitude;
        accuracy = position.accuracy;
        mapsUrl = 'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
        humanAddress = LocationService.formatCoordinates(latitude, longitude);

        try {
          final placemarks = await placemarkFromCoordinates(latitude, longitude)
              .timeout(const Duration(seconds: 2), onTimeout: () => []);
          if (placemarks.isNotEmpty) {
            humanAddress = LocationService.formatPlacemark(placemarks.first);
          }
        } catch (_) {}
      }

      // 4. Read emergency contacts (Read-only caller of ContactService)
      final contacts = await ContactService.instance.getContacts();
      final List<String> recipientEmails = [];
      final List<String> recipientUids = [];
      final List<String> recipientPhones = [];

      for (final c in contacts) {
        final email = c.email.toLowerCase().trim();
        if (email.isNotEmpty && !recipientEmails.contains(email)) {
          recipientEmails.add(email);
        }
        if (c.contactUid != null &&
            c.contactUid!.isNotEmpty &&
            !c.contactUid!.startsWith('offline_') &&
            !recipientUids.contains(c.contactUid)) {
          recipientUids.add(c.contactUid!);
        }
        if (c.hasPhone) {
          final formatted = EmergencyService.instance.formatRecipientPhone(c.phone);
          if (formatted.isNotEmpty && !recipientPhones.contains(formatted)) {
            recipientPhones.add(formatted);
          }
        }
      }

      // 5. Dispatch Firestore Alert in `sos_alerts` collection
      final alertDoc = FirebaseFirestore.instance.collection('sos_alerts').doc();
      final alertId = alertDoc.id;
      final defaultMessage = '🚨 EMERGENCY AUDIO ALERT: $senderName recorded an urgent voice note!';
      final alertMessage = (customNote != null && customNote.trim().isNotEmpty)
          ? customNote.trim()
          : defaultMessage;

      await alertDoc.set({
        'alertId': alertId,
        'id': alertId,
        'senderId': currentUserId,
        'sender_uid': currentUserId,
        'senderName': senderName,
        'sender_name': senderName,
        'senderEmail': senderEmail,
        'sender_email': senderEmail,
        'senderPhone': senderPhone,
        'sender_phone': senderPhone,
        'recipientEmails': recipientEmails,
        'recipientUids': recipientUids,
        'notifiedUids': recipientUids,
        'source': 'Record Audio',
        'type': 'AUDIO_SOS',
        'status': 'active',
        'message': alertMessage,
        'note': alertMessage,
        'audioUrl': downloadUrl,
        'audio_url': downloadUrl,
        'recordingUrl': downloadUrl,
        'hasAudio': true,
        'latitude': latitude,
        'longitude': longitude,
        'google_maps_url': mapsUrl,
        'location': {
          'latitude': latitude,
          'longitude': longitude,
          'accuracy': accuracy,
          'address': humanAddress,
          'googleMapsUrl': mapsUrl,
        },
        'triggeredAt': FieldValue.serverTimestamp(),
        'timestamp': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 4), onTimeout: () {
        debugPrint('[AudioRecordService] ⏱️ Firestore write queued offline');
      });

      debugPrint('[AudioRecordService] 📢 Dispatched Firestore alert: $alertId');

      // 6. SMS Fallback: Send emergency SMS with playable audio URL and GPS coordinates
      int smsSentCount = 0;
      if (recipientPhones.isNotEmpty) {
        final smsLocationPart = mapsUrl.isNotEmpty ? '\nMap: $mapsUrl' : '';
        final smsBody = 'EMERGENCY AUDIO ALERT from $senderName!\n'
            'Audio: $downloadUrl'
            '$smsLocationPart';

        for (final phone in recipientPhones) {
          try {
            await _telephony.sendSms(
              to: phone,
              message: smsBody,
              isMultipart: true,
            );
            smsSentCount++;
            debugPrint('[AudioRecordService] ✅ Emergency audio SMS sent to: $phone');
          } catch (smsErr) {
            debugPrint('[AudioRecordService] ⚠️ SMS dispatch error for $phone: $smsErr');
          }
        }
      }

      // 7. Log Quick Action activity
      ActivityService.instance.logQuickAction('Record Audio');

      return AudioDispatchResult(
        isSuccess: true,
        message: 'Audio alert sent successfully!',
        audioUrl: downloadUrl,
        alertId: alertId,
        smsSentCount: smsSentCount,
        totalRecipients: contacts.length,
      );
    } catch (e) {
      debugPrint('[AudioRecordService] ❌ Dispatch error: $e');
      return AudioDispatchResult(
        isSuccess: false,
        message: 'Failed to send audio alert: ${e.toString().replaceAll('Exception: ', '')}',
      );
    } finally {
      // 8. Delete temporary local audio file immediately after upload/attempt
      await cleanupLocalCache();
    }
  }

  /// Disposes internal resources
  void dispose() {
    _durationTimer?.cancel();
    _timeoutTimer?.cancel();
    _recorder.dispose();
  }
}

extension _StringExt on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
