import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Audio for the Fake Call screen (native FakeCallAudio on Android): ringtone with vibration while
/// ringing, then the caller's voice through the loudspeaker after the call is accepted.
class FakeCallAudioService {
  FakeCallAudioService._internal();
  static final FakeCallAudioService instance = FakeCallAudioService._internal();

  static const MethodChannel _channel = MethodChannel('com.smartsafety.smart_safety/fake_call');

  /// Optional recorded voice clip. When it is not bundled, the script below is spoken with the
  /// phone's built-in text-to-speech instead.
  static const String voiceAssetPath = 'assets/sounds/fake_call_voice.mp3';

  /// What the "caller" says; the pauses in between leave room for the user to answer.
  static const List<String> conversationScript = [
    'Hello? Hi, it\'s me. Can you hear me?',
    'I\'m calling to check where you are right now.',
    'Okay. Stay where you are, I\'m coming to pick you up.',
    'I can see your location. I\'ll be there in about five minutes.',
    'Keep talking to me, okay? Don\'t hang up.',
    'I\'m almost there. I\'m just around the corner.',
    'Alright, I can see the place now. Come outside, I\'m waiting for you.',
  ];

  bool get _isSupported => !kIsWeb && Platform.isAndroid;

  Future<void> startRinging() async {
    if (!_isSupported) return;
    try {
      final mode = await _channel.invokeMethod<String>('startRinging');
      debugPrint('[FakeCallAudio] Ringing mode: $mode');
    } catch (e) {
      debugPrint('[FakeCallAudio] Ringtone error: $e');
    }
  }

  /// Starts the conversation audio. Returns `asset`, `tts`, `unavailable` (no audio could be
  /// played: the caller should tell the user), `stopped`, or `unsupported` on other platforms.
  Future<String> startConversation() async {
    if (!_isSupported) return 'unsupported';
    try {
      final mode = await _channel.invokeMethod<String>('startConversation', {
        'assetPath': voiceAssetPath,
        'script': conversationScript,
      });
      debugPrint('[FakeCallAudio] Conversation mode: $mode');
      return mode ?? 'unavailable';
    } catch (e) {
      debugPrint('[FakeCallAudio] Conversation audio error: $e');
      return 'unavailable';
    }
  }

  /// Stops every fake-call sound and vibration.
  Future<void> stop() async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[FakeCallAudio] Stop error: $e');
    }
  }
}
