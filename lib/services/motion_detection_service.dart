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
import 'journey_service.dart';

/// Physical configuration thresholds and timing windows for the 3-stage fall detection algorithm.
class FallDetectionConfig {
  /// Standard acceleration due to gravity on Earth (m/s^2)
  final double gravity;

  /// Free-fall acceleration threshold as a fraction of g (default < 0.5g)
  final double freeFallThresholdG;

  /// Minimum continuous duration of free-fall (ms, default >= 80ms)
  final int freeFallDurationMs;

  /// Impact acceleration spike threshold as a multiple of g (default > 2.5g)
  final double impactThresholdG;

  /// Maximum permissible window between free-fall departure and impact spike (ms, default <= 1000ms)
  final int impactWindowMs;

  /// Post-impact stillness variance threshold as a fraction of g (default |a| within g +- 0.3g)
  final double stillnessVarianceThresholdG;

  /// Required continuous duration of post-impact stillness (ms, default >= 2000ms)
  final int stillnessDurationMs;

  /// Maximum permissible window after impact to establish stillness (ms, default <= 5000ms)
  final int stillnessWindowMs;

  /// Cooldown after a confirmed fall before a new detection cycle can begin (seconds, default 60s)
  final int cooldownSeconds;

  const FallDetectionConfig({
    this.gravity = 9.81,
    this.freeFallThresholdG = 0.5,
    this.freeFallDurationMs = 80,
    this.impactThresholdG = 2.5,
    this.impactWindowMs = 1000,
    this.stillnessVarianceThresholdG = 0.3,
    this.stillnessDurationMs = 2000,
    this.stillnessWindowMs = 5000,
    this.cooldownSeconds = 60,
  });
}

/// Stage states of the fall detection state machine.
enum FallDetectionStage {
  monitoring,
  freeFall,
  impactDetected,
}

/// Pure, testable state machine that evaluates accelerometer samples against
/// free-fall, impact, and post-impact stillness criteria.
class FallDetectionEngine {
  final FallDetectionConfig config;

  FallDetectionStage _stage = FallDetectionStage.monitoring;
  DateTime? _freeFallStartTime;
  DateTime? _freeFallEndTime;
  DateTime? _impactTime;
  DateTime? _stillnessStartTime;
  DateTime? _lastFallDetectedTime;

  FallDetectionStage get currentStage => _stage;
  DateTime? get lastFallDetectedTime => _lastFallDetectedTime;

  FallDetectionEngine({this.config = const FallDetectionConfig()});

  /// Resets the detection state machine back to monitoring.
  void reset() {
    _stage = FallDetectionStage.monitoring;
    _freeFallStartTime = null;
    _freeFallEndTime = null;
    _impactTime = null;
    _stillnessStartTime = null;
  }

  /// Calculates total acceleration magnitude: sqrt(x^2 + y^2 + z^2)
  static double calculateMagnitude(double x, double y, double z) {
    return math.sqrt(x * x + y * y + z * z);
  }

  /// Evaluates a single timestamped sensor reading.
  /// Returns `true` if and only if the full 3-stage fall pattern is confirmed.
  bool processSample({
    required DateTime timestamp,
    required double magnitude,
  }) {
    // 0. Cooldown check
    if (_lastFallDetectedTime != null) {
      final elapsedSinceLast = timestamp.difference(_lastFallDetectedTime!).inSeconds;
      if (elapsedSinceLast < config.cooldownSeconds) {
        return false;
      }
    }

    final freeFallLimit = config.freeFallThresholdG * config.gravity; // e.g. 4.905 m/s^2
    final impactLimit = config.impactThresholdG * config.gravity; // e.g. 24.525 m/s^2
    final stillnessMin = (1.0 - config.stillnessVarianceThresholdG) * config.gravity; // e.g. 6.867 m/s^2
    final stillnessMax = (1.0 + config.stillnessVarianceThresholdG) * config.gravity; // e.g. 12.753 m/s^2

    switch (_stage) {
      case FallDetectionStage.monitoring:
        if (magnitude < freeFallLimit) {
          _stage = FallDetectionStage.freeFall;
          _freeFallStartTime = timestamp;
          _freeFallEndTime = timestamp;
        }
        break;

      case FallDetectionStage.freeFall:
        if (magnitude < freeFallLimit) {
          _freeFallEndTime = timestamp;
        } else {
          // Free-fall ended. Check duration
          final durationMs = _freeFallEndTime!.difference(_freeFallStartTime!).inMilliseconds;
          if (durationMs >= config.freeFallDurationMs) {
            // Valid free-fall duration achieved
            if (magnitude > impactLimit) {
              // Impact occurred immediately on the exit sample
              _stage = FallDetectionStage.impactDetected;
              _impactTime = timestamp;
              _stillnessStartTime = null;
            } else {
              // Advance to await impact spike within impactWindowMs
              _stage = FallDetectionStage.impactDetected;
              _impactTime = null;
            }
          } else {
            // Free-fall was too transient (< 80ms)
            reset();
          }
        }
        break;

      case FallDetectionStage.impactDetected:
        if (_impactTime == null) {
          // Waiting for impact peak after free-fall
          final elapsedSinceFreeFall = timestamp.difference(_freeFallEndTime!).inMilliseconds;
          if (elapsedSinceFreeFall > config.impactWindowMs) {
            // Window expired without an impact spike
            reset();
          } else if (magnitude > impactLimit) {
            _impactTime = timestamp;
            _stillnessStartTime = null;
          }
        } else {
          // Impact occurred. Now evaluate post-impact stillness
          final elapsedSinceImpact = timestamp.difference(_impactTime!).inMilliseconds;
          if (elapsedSinceImpact > config.stillnessWindowMs) {
            // Stillness window expired without establishing sufficient resting duration
            reset();
          } else {
            final isWithinStillness = magnitude >= stillnessMin && magnitude <= stillnessMax;
            if (isWithinStillness) {
              _stillnessStartTime ??= timestamp;
              final stillnessDuration = timestamp.difference(_stillnessStartTime!).inMilliseconds;
              if (stillnessDuration >= config.stillnessDurationMs) {
                // Complete 3-stage fall pattern confirmed!
                _lastFallDetectedTime = timestamp;
                reset();
                return true;
              }
            } else {
              // High acceleration broke stillness; reset stillness timer
              _stillnessStartTime = null;
            }
          }
        }
        break;
    }

    return false;
  }
}

/// Central singleton service orchestrating accelerometer stream subscriptions,
/// fall detection evaluation, 30-second safety check countdowns, and automated SOS escalation.
class MotionDetectionService {
  MotionDetectionService._internal();

  /// Singleton instance
  static final MotionDetectionService instance = MotionDetectionService._internal();

  static const String prefKeyFallDetection = 'pref_fall_detection';

  final FallDetectionEngine _engine = FallDetectionEngine();

  StreamSubscription<AccelerometerEvent>? _accelerometerSub;
  Timer? _countdownTimer;

  /// User preference toggle state
  final ValueNotifier<bool> isEnabledNotifier = ValueNotifier<bool>(false);

  /// Whether sensor stream is actively being monitored
  final ValueNotifier<bool> isMonitoringNotifier = ValueNotifier<bool>(false);

  /// Reactive state holding remaining seconds for active 30s fall countdown (or null if none)
  final ValueNotifier<int?> activeCountdownNotifier = ValueNotifier<int?>(null);

  bool get isEnabled => isEnabledNotifier.value;
  bool get isMonitoring => isMonitoringNotifier.value;
  bool get isCountdownActive => activeCountdownNotifier.value != null;

  /// Initializes the service and restores user setting from SharedPreferences
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      isEnabledNotifier.value = prefs.getBool(prefKeyFallDetection) ?? false;
      await checkAndSyncMonitoringState();
    } catch (e) {
      debugPrint('[MotionDetectionService] Init warning: $e');
    }
  }

  /// Asynchronously queries persisted user preference for fall detection
  Future<bool> isFallDetectionEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKeyFallDetection) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sets whether Fall Detection is enabled in user preferences
  Future<void> setEnabled(bool enabled) async {
    isEnabledNotifier.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKeyFallDetection, enabled);
    } catch (_) {}
    await checkAndSyncMonitoringState();
  }

  /// Evaluates whether accelerometer sensor monitoring should be running:
  /// - User enabled Fall Detection toggle in Settings
  /// - Safe Journey is actively running
  /// - "I'm Being Followed" mode is active
  Future<void> checkAndSyncMonitoringState({bool isFollowedModeActive = false}) async {
    final shouldMonitor = isEnabledNotifier.value ||
        JourneyService.instance.isJourneyActive ||
        isFollowedModeActive;

    if (shouldMonitor && !isMonitoring) {
      await _startMonitoring();
    } else if (!shouldMonitor && isMonitoring) {
      await _stopMonitoring();
    }
  }

  /// Starts listening to device accelerometer events with foreground service protection
  Future<void> _startMonitoring() async {
    if (isMonitoring) return;

    try {
      // Ensure foreground service is running to avoid background OS suspension
      await BackgroundServiceManager.instance.startService(
        title: 'Woman Guard Protection Active',
        content: 'Fall detection & safety monitoring active',
      );

      _accelerometerSub?.cancel();
      _accelerometerSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(
        (event) {
          final mag = FallDetectionEngine.calculateMagnitude(event.x, event.y, event.z);
          final isFall = _engine.processSample(timestamp: DateTime.now(), magnitude: mag);
          if (isFall) {
            _handleFallDetected();
          }
        },
        onError: (err) {
          debugPrint('[MotionDetectionService] Accelerometer stream error: $err');
        },
      );

      isMonitoringNotifier.value = true;
      debugPrint('[MotionDetectionService] 🎯 Accelerometer fall monitoring started');
    } catch (e) {
      debugPrint('[MotionDetectionService] Error starting monitoring: $e');
    }
  }

  /// Stops listening to device accelerometer events
  Future<void> _stopMonitoring() async {
    await _accelerometerSub?.cancel();
    _accelerometerSub = null;
    isMonitoringNotifier.value = false;
    _engine.reset();
    debugPrint('[MotionDetectionService] ⏹️ Accelerometer fall monitoring stopped');
  }

  /// Handles a confirmed physical fall event: triggers vibration, attention alert,
  /// logs event, and initiates the 30-second countdown.
  void _handleFallDetected() {
    if (isCountdownActive) return; // Countdown already running

    debugPrint('[MotionDetectionService] ⚠️ FALL DETECTED! Initiating 30-second countdown...');

    // Attention alert & heavy vibration
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);

    // Log detection event
    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.sos,
        title: 'Fall Impact Detected',
        subtitle: 'Fall detected. Initiated 30-second safety check countdown.',
        timestamp: DateTime.now(),
      ),
    );

    int remaining = 30;
    activeCountdownNotifier.value = remaining;

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      remaining--;
      if (remaining > 0) {
        activeCountdownNotifier.value = remaining;
        if (remaining % 3 == 0) {
          HapticFeedback.mediumImpact();
        }
      } else {
        // 30 seconds elapsed without user response -> escalate to SOS
        timer.cancel();
        activeCountdownNotifier.value = null;
        await _escalateFallToSos();
      }
    });
  }

  /// Cancels the active countdown when user confirms they are safe ("I'm OK")
  void confirmSafe() {
    if (!isCountdownActive) return;

    _countdownTimer?.cancel();
    _countdownTimer = null;
    activeCountdownNotifier.value = null;

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.profile,
        title: 'Fall Safety Confirmed',
        subtitle: 'User confirmed safety. Fall alarm cancelled.',
        timestamp: DateTime.now(),
      ),
    );

    debugPrint('[MotionDetectionService] ✅ User confirmed OK. Fall alarm cancelled.');
  }

  /// Escalates immediately to Emergency SOS when user taps "Send SOS Now"
  Future<void> sendSosNow() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    activeCountdownNotifier.value = null;

    final prefs = await SharedPreferences.getInstance();
    final sirenOnAutoSos = prefs.getBool('pref_siren_on_auto_sos') ?? false;

    await EmergencyService.instance.triggerEmergency(
      source: 'FALL_SOS',
      isDuress: false,
      playSiren: sirenOnAutoSos,
      customMessage: 'EMERGENCY: User detected a fall and requested immediate assistance.',
    );
  }

  /// Automatically triggers full SOS pipeline when the 30s countdown expires unanswered
  Future<void> _escalateFallToSos() async {
    debugPrint('[MotionDetectionService] 🚨 Fall countdown expired! Escalating to FALL_SOS...');

    final prefs = await SharedPreferences.getInstance();
    final sirenOnAutoSos = prefs.getBool('pref_siren_on_auto_sos') ?? false;

    ActivityService.instance.logActivity(
      ActivityItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ActivityType.sos,
        title: 'Automatic Fall SOS Dispatched',
        subtitle: 'No response to 30s fall safety check. Alerted emergency contacts.',
        timestamp: DateTime.now(),
      ),
    );

    try {
      await EmergencyService.instance.triggerEmergency(
        source: 'FALL_SOS',
        isDuress: false,
        playSiren: sirenOnAutoSos,
        customMessage:
            'AUTOMATIC SOS: A fall impact was detected and the user did not respond to the safety check.',
      );
    } catch (e) {
      debugPrint('[MotionDetectionService] Error escalating fall SOS: $e');
    }
  }

  /// Manually simulates a fall detection event (useful for UI testing & emulator tests)
  void simulateFallEvent() {
    _handleFallDetected();
  }
}
