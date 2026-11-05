import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/activity_model.dart';
import 'activity_service.dart';
import 'background_service.dart';
import 'emergency_service.dart';
import 'pin_security_service.dart';

/// Tuning for [ShakeDetector].
class ShakeDetectorConfig {
  final double gravity;

  /// How far (m/s²) the total acceleration must move away from gravity to count as a shake.
  /// About 1.6g: well above walking, below what a deliberate hard shake produces.
  final double shakeThreshold;

  /// Peaks closer together than this belong to the same shake (one back-and-forth motion).
  final int minGapMs;

  /// Number of shakes needed to trigger.
  final int requiredShakes;

  /// All [requiredShakes] must happen within this window.
  final int windowMs;

  /// After a trigger, further shakes are ignored for this long.
  final int cooldownMs;

  const ShakeDetectorConfig({
    this.gravity = 9.81,
    this.shakeThreshold = 16.0,
    this.minGapMs = 250,
    this.requiredShakes = 3,
    this.windowMs = 1500,
    this.cooldownMs = 10000,
  });
}

/// Pure, testable shake counter: feed it accelerometer samples, it returns `true`
/// once [ShakeDetectorConfig.requiredShakes] distinct shakes land inside the window.
class ShakeDetector {
  final ShakeDetectorConfig config;
  final List<DateTime> _shakes = [];
  DateTime? _lastTrigger;

  ShakeDetector({this.config = const ShakeDetectorConfig()});

  int get pendingShakes => _shakes.length;

  void reset() => _shakes.clear();

  bool processSample({
    required DateTime timestamp,
    required double x,
    required double y,
    required double z,
  }) {
    if (_lastTrigger != null &&
        timestamp.difference(_lastTrigger!).inMilliseconds < config.cooldownMs) {
      return false;
    }

    final magnitude = math.sqrt(x * x + y * y + z * z);
    if ((magnitude - config.gravity).abs() < config.shakeThreshold) return false;

    if (_shakes.isNotEmpty &&
        timestamp.difference(_shakes.last).inMilliseconds < config.minGapMs) {
      return false; // same shake, still swinging
    }

    _shakes.add(timestamp);
    _shakes.removeWhere((t) => timestamp.difference(t).inMilliseconds > config.windowMs);

    if (_shakes.length >= config.requiredShakes) {
      _lastTrigger = timestamp;
      _shakes.clear();
      return true;
    }
    return false;
  }
}

/// "Shake to SOS": while enabled, listens to the accelerometer. Three hard shakes start a
/// short countdown (shown by the home screen) that the user can cancel; when it runs out,
/// the normal SOS pipeline is triggered.
///
/// Runs while the app process is alive (the foreground service keeps it alive when the
/// app is in the background). If the app is in the background the countdown cannot be
/// seen, so SOS is sent when it runs out; the phone vibrates every second as a warning.
class ShakeSosService {
  ShakeSosService._internal();
  static final ShakeSosService instance = ShakeSosService._internal();

  static const String prefKey = 'pref_shake_to_sos';
  static const int countdownSeconds = 5;

  final ShakeDetector _detector = ShakeDetector();
  StreamSubscription<AccelerometerEvent>? _sub;
  Timer? _countdownTimer;

  final ValueNotifier<bool> isEnabledNotifier = ValueNotifier<bool>(false);

  /// Seconds left before SOS is sent, or null when no countdown is running.
  final ValueNotifier<int?> activeCountdownNotifier = ValueNotifier<int?>(null);

  bool get isEnabled => isEnabledNotifier.value;
  bool get isListening => _sub != null;
  bool get isCountdownActive => activeCountdownNotifier.value != null;

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      isEnabledNotifier.value = prefs.getBool(prefKey) ?? false;
      await _sync();
    } catch (e) {
      debugPrint('[ShakeSos] Init warning: $e');
    }
  }

  Future<bool> isShakeEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    isEnabledNotifier.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, enabled);
    } catch (_) {}
    await _sync();
  }

  Future<void> _sync() async {
    if (isEnabled && !isListening) {
      await _start();
    } else if (!isEnabled && isListening) {
      await _stop();
    }
  }

  Future<void> _start() async {
    try {
      // Keep the process alive in the background so shakes are still detected.
      await BackgroundServiceManager.instance.startService(
        title: 'Woman Guard Protection Active',
        content: 'Shake to SOS & safety monitoring active',
      );
    } catch (_) {}

    _detector.reset();
    _sub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (e) {
        if (_detector.processSample(timestamp: DateTime.now(), x: e.x, y: e.y, z: e.z)) {
          _onShakeDetected();
        }
      },
      onError: (Object err) => debugPrint('[ShakeSos] Accelerometer error: $err'),
    );
    debugPrint('[ShakeSos] Listening for shakes');
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    _detector.reset();
    cancelCountdown(log: false);
    debugPrint('[ShakeSos] Stopped listening');
  }

  void _onShakeDetected() {
    if (isCountdownActive) return;
    // An SOS is already running: nothing more to do.
    if (EmergencyService.instance.activeAlertId != null) return;
    // In camouflage the countdown can't be shown; the Duress PIN is the silent route there.
    if (PinSecurityService.instance.isCamouflageActive) return;

    debugPrint('[ShakeSos] Shake pattern detected; starting $countdownSeconds s countdown');
    HapticFeedback.heavyImpact();

    var remaining = countdownSeconds;
    activeCountdownNotifier.value = remaining;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remaining--;
      if (remaining > 0) {
        activeCountdownNotifier.value = remaining;
        HapticFeedback.heavyImpact();
      } else {
        timer.cancel();
        _countdownTimer = null;
        activeCountdownNotifier.value = null;
        unawaited(_sendSos());
      }
    });
  }

  /// User tapped Cancel in the countdown dialog.
  void cancelCountdown({bool log = true}) {
    if (!isCountdownActive) return;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    activeCountdownNotifier.value = null;
    if (log) {
      ActivityService.instance.logActivity(
        ActivityItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          type: ActivityType.profile,
          title: 'Shake SOS Cancelled',
          subtitle: 'Shake detected but cancelled before sending.',
          timestamp: DateTime.now(),
        ),
      );
    }
  }

  /// User tapped "Send SOS now" in the countdown dialog.
  Future<void> sendNow() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    activeCountdownNotifier.value = null;
    await _sendSos();
  }

  Future<void> _sendSos() async {
    try {
      await EmergencyService.instance.triggerEmergency(
        source: 'SHAKE_SOS',
        customMessage: 'EMERGENCY: SOS triggered by shaking the phone.',
      );
    } catch (e) {
      debugPrint('[ShakeSos] Error sending SOS: $e');
    }
  }
}
