import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'activity_service.dart';
import 'guardian_alert_service.dart';

/// Central Singleton Service for handling the "Loud Siren" Quick Action.
///
/// Uses [AudioPlayer] to play an emergency alarm loop at maximum volume.
/// Exposes reactive state via [isPlayingNotifier] for seamless UI binding.
class SirenService {
  SirenService._internal();

  /// Singleton instance
  static final SirenService instance = SirenService._internal();

  AudioPlayer? _audioPlayer;
  bool _isInitAttempted = false;

  /// How long the siren of an incoming live SOS alert rings unless the guardian stops it or the
  /// sender ends the alert. Same as AlertSirenPlayer.MAX_RING_MS on Android.
  static const Duration incomingAlertRingDuration = Duration(minutes: 2);

  /// Reactive notifier for UI bindings: true while this app's siren or the native incoming-alert
  /// siren is sounding.
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier<bool>(false);

  bool _dartPlaying = false;
  bool _nativePlaying = false;
  Timer? _ringLimitTimer;
  String? _dartAlertId;

  void _publish() {
    final playing = _dartPlaying || _nativePlaying;
    if (isPlayingNotifier.value != playing) isPlayingNotifier.value = playing;
  }

  /// Called by GuardianAlertService when the native alert siren starts or stops.
  void setNativeAlertSirenPlaying(bool playing) {
    _nativePlaying = playing;
    _publish();
  }

  bool get _useNativeAlertSiren => !kIsWeb && Platform.isAndroid;

  /// Rings for an incoming live SOS alert: loud, alarm stream (also in silent mode), for
  /// [incomingAlertRingDuration]. Stop it early only through a guardian action or the alert
  /// ending, with [stopAlertSiren] (or [stopSiren] for an explicit "stop all").
  Future<void> startAlertSiren(String alertId) async {
    if (_useNativeAlertSiren) {
      final started = await GuardianAlertService.instance.startNativeAlertSiren(alertId);
      if (started) {
        _nativePlaying = true;
        _publish();
        debugPrint('[SirenService] 🚨 Native alert siren for $alertId (2 min)');
        return;
      }
    }
    await startSiren();
    _dartAlertId = alertId;
    _ringLimitTimer?.cancel();
    _ringLimitTimer = Timer(incomingAlertRingDuration, () {
      if (_dartAlertId == alertId) stopAlertSiren(alertId);
    });
  }

  /// Stops the siren only if it is ringing for [alertId], so ending one alert can never silence
  /// another, newer one.
  Future<void> stopAlertSiren(String alertId) async {
    if (alertId.isEmpty) return;
    await GuardianAlertService.instance.stopNativeAlertSiren(alertId);
    if (_dartAlertId == alertId) await stopSiren();
  }

  /// Getter for current siren state
  bool get isPlaying => isPlayingNotifier.value;

  /// Reliable fallback online siren audio URL in case local asset audio file is missing
  static const String _fallbackSirenUrl =
      'https://actions.google.com/sounds/v1/emergency/police_siren_short.ogg';

  /// Lazily and safely creates the [AudioPlayer] instance, tolerating headless/test environments
  AudioPlayer? _getOrCreatePlayer() {
    if (_audioPlayer != null) return _audioPlayer;
    if (_isInitAttempted) return null;
    _isInitAttempted = true;
    try {
      final player = AudioPlayer();
      player.setReleaseMode(ReleaseMode.loop).catchError((_) {});
      player.onPlayerStateChanged.listen((state) {
        _dartPlaying = state == PlayerState.playing;
        _publish();
      }, onError: (_) {});
      _audioPlayer = player;
      return player;
    } catch (e) {
      debugPrint('[SirenService] AudioPlayer initialization note (e.g. test environment): $e');
      return null;
    }
  }

  /// Starts the loud emergency siren audio at max volume (1.0) on continuous loop.
  Future<void> startSiren() async {
    try {
      debugPrint('[SirenService] 🚨 Starting Loud Emergency Siren...');

      final player = _getOrCreatePlayer();
      if (player != null) {
        // Ensure max volume
        await player.setVolume(1.0);
        await player.setReleaseMode(ReleaseMode.loop);

        // Try playing local asset first, fallback to URL if asset fails
        try {
          await player.play(AssetSource('sounds/siren.mp3'));
        } catch (assetErr) {
          debugPrint('[SirenService] Asset play failed ($assetErr). Playing fallback online siren...');
          await player.play(UrlSource(_fallbackSirenUrl));
        }
      }

      _dartAlertId = null;
      _dartPlaying = true;
      _publish();
      ActivityService.instance.logSiren(isPlaying: true);
      debugPrint('[SirenService] 🔊 Siren is now playing on loop at MAX volume.');
    } catch (e) {
      debugPrint('[SirenService] ❌ Failed to play siren audio: $e');
      _dartPlaying = false;
      _publish();
    }
  }

  /// Stops every siren immediately (this app's and the native incoming-alert siren). For an
  /// explicit guardian/user action only; code acting for one alert uses [stopAlertSiren].
  Future<void> stopSiren() async {
    _ringLimitTimer?.cancel();
    _dartAlertId = null;
    try {
      debugPrint('[SirenService] 🔇 Stopping Emergency Siren...');
      final player = _audioPlayer;
      if (player != null) {
        await player.stop();
      }
      // An incoming alert may be ringing through the native guardian service instead
      await GuardianAlertService.instance.stopNativeSiren();
      _dartPlaying = false;
      _nativePlaying = false;
      _publish();
      ActivityService.instance.logSiren(isPlaying: false);
      debugPrint('[SirenService] ✅ Siren stopped.');
    } catch (e) {
      debugPrint('[SirenService] ❌ Error stopping siren audio: $e');
      _dartPlaying = false;
      _publish();
    }
  }

  /// Toggles the emergency siren state (starts if stopped, stops if playing).
  Future<bool> toggleSiren() async {
    if (isPlaying) {
      await stopSiren();
    } else {
      await startSiren();
    }
    return isPlaying;
  }

  /// Dispose player resources
  void dispose() {
    try {
      _audioPlayer?.dispose();
    } catch (_) {}
    isPlayingNotifier.dispose();
  }
}
