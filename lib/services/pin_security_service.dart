import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/activity_model.dart';
import 'activity_service.dart';
import 'audio_record_service.dart';
import 'auth_service.dart';
import 'background_service.dart';
import 'emergency_service.dart';

/// Result of evaluating an entered PIN against configured hashes
enum PinVerificationResult {
  real,
  duress,
  invalid,
}

/// Central service managing salted SHA-256 PIN security, duress alarm routing,
/// activity log suppression, and camouflage calculator mode.
class PinSecurityService {
  PinSecurityService._internal();

  /// Singleton instance
  static final PinSecurityService instance = PinSecurityService._internal();

  static const String prefKeyRealPinHash = 'sec_real_pin_hash';
  static const String prefKeyRealPinSalt = 'sec_real_pin_salt';
  static const String prefKeyDuressPinHash = 'sec_duress_pin_hash';
  static const String prefKeyDuressPinSalt = 'sec_duress_pin_salt';
  static const String prefKeyPinEnabled = 'sec_pin_protection_enabled';
  static const String prefKeyRequireOnOpen = 'sec_pin_require_on_open';
  static const String prefKeyCamouflageActive = 'sec_camouflage_active';
  static const String prefKeyDuressActive = 'sec_duress_active';

  /// Reactive notifier for Camouflage Calculator state
  final ValueNotifier<bool> isCamouflageActiveNotifier = ValueNotifier<bool>(false);

  /// Reactive notifier for active Duress state
  final ValueNotifier<bool> isDuressActiveNotifier = ValueNotifier<bool>(false);

  bool get isCamouflageActive => isCamouflageActiveNotifier.value;
  bool get isDuressActive => isDuressActiveNotifier.value;

  /// Private queue holding suppressed activity logs created during duress mode
  final List<ActivityItem> _suppressedActivityLogs = [];

  // ─────────────────────────────────────────────────────────────
  //  PURE TESTABLE CRYPTO FUNCTIONS
  // ─────────────────────────────────────────────────────────────

  /// Generates a random cryptographic salt string
  static String generateSalt([int length = 16]) {
    final rand = Random.secure();
    final bytes = List<int>.generate(length, (_) => rand.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Hashes a PIN with a salt using SHA-256
  static String hashPin(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  /// Pure, testable helper verifying an entered PIN against salt and stored hash
  static bool verifyHash({
    required String enteredPin,
    required String salt,
    required String storedHash,
  }) {
    if (enteredPin.isEmpty || salt.isEmpty || storedHash.isEmpty) return false;
    final computed = hashPin(enteredPin, salt);
    return computed == storedHash;
  }

  /// Evaluates an entered PIN against stored real and duress hashes
  static PinVerificationResult evaluatePin({
    required String enteredPin,
    required String? realSalt,
    required String? realHash,
    required String? duressSalt,
    required String? duressHash,
  }) {
    if (enteredPin.isEmpty) return PinVerificationResult.invalid;

    // Check Real PIN
    if (realSalt != null && realHash != null) {
      if (verifyHash(enteredPin: enteredPin, salt: realSalt, storedHash: realHash)) {
        return PinVerificationResult.real;
      }
    }

    // Check Duress PIN
    if (duressSalt != null && duressHash != null) {
      if (verifyHash(enteredPin: enteredPin, salt: duressSalt, storedHash: duressHash)) {
        return PinVerificationResult.duress;
      }
    }

    return PinVerificationResult.invalid;
  }

  // ─────────────────────────────────────────────────────────────
  //  INITIALIZATION & CONFIGURATION
  // ─────────────────────────────────────────────────────────────

  /// Restores camouflage and duress mode state from SharedPreferences on app launch
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasRealPin = prefs.containsKey(prefKeyRealPinHash) && prefs.containsKey(prefKeyRealPinSalt);
      final camouflageActive = prefs.getBool(prefKeyCamouflageActive) ?? false;

      // Never trap users in camouflage if no Real PIN is configured
      if (camouflageActive && !hasRealPin) {
        await prefs.setBool(prefKeyCamouflageActive, false);
        await prefs.setBool(prefKeyDuressActive, false);
        isCamouflageActiveNotifier.value = false;
        isDuressActiveNotifier.value = false;
      } else {
        isCamouflageActiveNotifier.value = camouflageActive;
        isDuressActiveNotifier.value = prefs.getBool(prefKeyDuressActive) ?? false;
      }
    } catch (_) {}
  }

  /// Whether PIN protection is enabled by the user
  Future<bool> isPinEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKeyPinEnabled) ?? false;
  }

  /// Sets whether PIN protection is enabled
  Future<void> setPinEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyPinEnabled, enabled);
  }

  /// Whether PIN is required upon opening the app
  Future<bool> isPinRequiredOnOpen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKeyRequireOnOpen) ?? false;
  }

  /// Sets whether PIN is required upon opening the app
  Future<void> setPinRequiredOnOpen(bool required) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyRequireOnOpen, required);
  }

  /// Checks if a Real PIN is configured
  Future<bool> isRealPinConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(prefKeyRealPinHash) && prefs.containsKey(prefKeyRealPinSalt);
  }

  /// Checks if a Duress PIN is configured
  Future<bool> isDuressPinConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(prefKeyDuressPinHash) && prefs.containsKey(prefKeyDuressPinSalt);
  }

  /// Sets the Real Security PIN
  Future<bool> setRealPin(String newPin) async {
    if (newPin.length < 4) return false;

    final prefs = await SharedPreferences.getInstance();

    // Check if identical to existing Duress PIN
    final duressSalt = prefs.getString(prefKeyDuressPinSalt);
    final duressHash = prefs.getString(prefKeyDuressPinHash);
    if (duressSalt != null && duressHash != null) {
      if (verifyHash(enteredPin: newPin, salt: duressSalt, storedHash: duressHash)) {
        throw Exception('Real PIN cannot be the same as your Duress PIN.');
      }
    }

    final salt = generateSalt();
    final hash = hashPin(newPin, salt);

    await prefs.setString(prefKeyRealPinSalt, salt);
    await prefs.setString(prefKeyRealPinHash, hash);
    await setPinEnabled(true);
    return true;
  }

  /// Sets the Duress Emergency PIN
  Future<bool> setDuressPin(String newPin) async {
    if (newPin.length < 4) return false;

    final prefs = await SharedPreferences.getInstance();

    // Check if identical to existing Real PIN
    final realSalt = prefs.getString(prefKeyRealPinSalt);
    final realHash = prefs.getString(prefKeyRealPinHash);
    if (realSalt != null && realHash != null) {
      if (verifyHash(enteredPin: newPin, salt: realSalt, storedHash: realHash)) {
        throw Exception('Duress PIN cannot be the same as your Real PIN.');
      }
    }

    final salt = generateSalt();
    final hash = hashPin(newPin, salt);

    await prefs.setString(prefKeyDuressPinSalt, salt);
    await prefs.setString(prefKeyDuressPinHash, hash);
    return true;
  }

  /// Manually engages camouflage calculator mode for preview or privacy
  Future<void> enterCamouflageManually() async {
    final hasRealPin = await isRealPinConfigured();
    if (hasRealPin) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKeyCamouflageActive, true);
    }
    isCamouflageActiveNotifier.value = true;
  }

  /// Clears all PIN security configurations
  Future<void> clearAllPins() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefKeyRealPinHash);
    await prefs.remove(prefKeyRealPinSalt);
    await prefs.remove(prefKeyDuressPinHash);
    await prefs.remove(prefKeyDuressPinSalt);
    await prefs.remove(prefKeyPinEnabled);
    await prefs.remove(prefKeyRequireOnOpen);
    await exitCamouflage();
  }

  // ─────────────────────────────────────────────────────────────
  //  VERIFICATION & DURESS PIPELINE
  // ─────────────────────────────────────────────────────────────

  /// Verifies an entered PIN and triggers duress pipeline if Duress PIN matches
  Future<PinVerificationResult> verifyPin(String enteredPin) async {
    final prefs = await SharedPreferences.getInstance();
    final realSalt = prefs.getString(prefKeyRealPinSalt);
    final realHash = prefs.getString(prefKeyRealPinHash);
    final duressSalt = prefs.getString(prefKeyDuressPinSalt);
    final duressHash = prefs.getString(prefKeyDuressPinHash);

    final result = evaluatePin(
      enteredPin: enteredPin,
      realSalt: realSalt,
      realHash: realHash,
      duressSalt: duressSalt,
      duressHash: duressHash,
    );

    if (result == PinVerificationResult.duress) {
      await triggerDuressPipeline();
    } else if (result == PinVerificationResult.real) {
      if (isDuressActive || isCamouflageActive) {
        await exitCamouflage();
      }
    }

    return result;
  }

  /// Executes the silent duress emergency pipeline:
  /// 1. Immediately switches UI to Camouflage Mode (Working Calculator)
  /// 2. Dispatches silent SOS via [EmergencyService] with isDuress = true
  /// 3. Switches foreground service notification to neutral disguise
  /// 4. Begins private local audio recording
  /// 5. Suppresses user-visible activity logs until exited by Real PIN
  Future<void> triggerDuressPipeline() async {
    debugPrint('[PinSecurity] 🚨 SILENT DURESS EMERGENCY TRIGGERED!');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyCamouflageActive, true);
    await prefs.setBool(prefKeyDuressActive, true);

    isCamouflageActiveNotifier.value = true;
    isDuressActiveNotifier.value = true;

    // 1. Silent SOS dispatch
    final userName = AuthService.instance.displayName;
    final silentMessage =
        'SILENT EMERGENCY: $userName may be under direct threat. Do NOT call her phone! Monitor her live GPS location discreetly.';

    // Queue suppressed log item
    _suppressedActivityLogs.add(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.sos,
        title: 'Silent Duress SOS Dispatched',
        subtitle: 'Silently alerted emergency contacts with duress warning.',
        timestamp: DateTime.now(),
      ),
    );

    try {
      await EmergencyService.instance.triggerEmergency(
        source: 'DURESS_PIN',
        isDuress: true,
        playSiren: false,
        customMessage: silentMessage,
      );
    } catch (e) {
      debugPrint('[PinSecurity] Duress emergency dispatch notice: $e');
    }

    // 2. Disguise background service notification
    try {
      await BackgroundServiceManager.instance.startService(
        title: 'Calculator',
        content: 'Running background mathematical process',
      );
    } catch (_) {}

    // 3. Start private local audio recording
    try {
      await AudioRecordService.instance.startRecording();
    } catch (e) {
      debugPrint('[PinSecurity] Duress audio record notice: $e');
    }
  }

  /// Exits Camouflage and Duress mode when user enters Real PIN
  Future<void> exitCamouflage() async {
    debugPrint('[PinSecurity] 🛡️ Exiting Camouflage Mode via Real PIN verification');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyCamouflageActive, false);
    await prefs.setBool(prefKeyDuressActive, false);

    isCamouflageActiveNotifier.value = false;
    isDuressActiveNotifier.value = false;

    // Stop audio recording if active
    try {
      if (AudioRecordService.instance.isRecordingNotifier.value) {
        await AudioRecordService.instance.stopRecording();
      }
    } catch (_) {}

    // Restore background service title if still tracking
    if (EmergencyService.instance.activeAlertId != null) {
      try {
        await BackgroundServiceManager.instance.startService(
          title: '🚨 Emergency SOS Live Tracking Active',
          content: 'Broadcasting live coordinates to your guardians',
        );
      } catch (_) {}
    }

    // Flush suppressed activity logs
    if (_suppressedActivityLogs.isNotEmpty) {
      for (final item in _suppressedActivityLogs) {
        ActivityService.instance.logActivity(item);
      }
      _suppressedActivityLogs.clear();
    }

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.profile,
        title: 'Camouflage Mode Exited',
        subtitle: 'User unlocked normal application view with Real PIN.',
        timestamp: DateTime.now(),
      ),
    );
  }
}
