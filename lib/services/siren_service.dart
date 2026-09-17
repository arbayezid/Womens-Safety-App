import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Central Singleton Service for handling the "Loud Siren" Quick Action.
///
/// Uses [AudioPlayer] to play an emergency alarm loop at maximum volume.
/// Exposes reactive state via [isPlayingNotifier] for seamless UI binding.
class SirenService {
  SirenService._internal() {
    _initAudioPlayer();
  }

  /// Singleton instance
  static final SirenService instance = SirenService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();

  /// Reactive notifier for UI bindings
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier<bool>(false);

  /// Getter for current siren state
  bool get isPlaying => isPlayingNotifier.value;

  /// Reliable fallback online siren audio URL in case local asset audio file is missing
  static const String _fallbackSirenUrl =
      'https://actions.google.com/sounds/v1/emergency/police_siren_short.ogg';

  /// Initializes player configuration
  void _initAudioPlayer() {
    _audioPlayer.setReleaseMode(ReleaseMode.loop);

    // Listen to player state changes
    _audioPlayer.onPlayerStateChanged.listen((state) {
      final playing = (state == PlayerState.playing);
      if (isPlayingNotifier.value != playing) {
        isPlayingNotifier.value = playing;
      }
    });
  }

  /// Starts the loud emergency siren audio at max volume (1.0) on continuous loop.
  Future<void> startSiren() async {
    try {
      debugPrint('[SirenService] 🚨 Starting Loud Emergency Siren...');

      // Ensure max volume
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);

      // Try playing local asset first, fallback to URL if asset fails
      try {
        await _audioPlayer.play(AssetSource('sounds/siren.mp3'));
      } catch (assetErr) {
        debugPrint('[SirenService] Asset play failed ($assetErr). Playing fallback online siren...');
        await _audioPlayer.play(UrlSource(_fallbackSirenUrl));
      }

      isPlayingNotifier.value = true;
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
      await _audioPlayer.stop();
      isPlayingNotifier.value = false;
      debugPrint('[SirenService] ✅ Siren stopped.');
    } catch (e) {
      debugPrint('[SirenService] ❌ Error stopping siren audio: $e');
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
    _audioPlayer.dispose();
    isPlayingNotifier.dispose();
  }
}
