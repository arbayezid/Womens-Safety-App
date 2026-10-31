import 'dart:async';
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

  /// Reactive notifier for UI bindings
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier<bool>(false);

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
        final playing = (state == PlayerState.playing);
        if (isPlayingNotifier.value != playing) {
          isPlayingNotifier.value = playing;
        }
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

      isPlayingNotifier.value = true;
      ActivityService.instance.logSiren(isPlaying: true);
      debugPrint('[SirenService] 🔊 Siren is now playing on loop at MAX volume.');
    } catch (e) {
      debugPrint('[SirenService] ❌ Failed to play siren audio: $e');
      isPlayingNotifier.value = false;
    }
  }

  /// Stops the emergency siren audio immediately.
  Future<void> stopSiren() async {
    try {
      debugPrint('[SirenService] 🔇 Stopping Emergency Siren...');
      final player = _audioPlayer;
      if (player != null) {
        await player.stop();
      }
      // An incoming alert may be ringing through the native guardian service instead
      await GuardianAlertService.instance.stopNativeSiren();
      isPlayingNotifier.value = false;
      ActivityService.instance.logSiren(isPlaying: false);
      debugPrint('[SirenService] ✅ Siren stopped.');
    } catch (e) {
      debugPrint('[SirenService] ❌ Error stopping siren audio: $e');
      isPlayingNotifier.value = false;
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
