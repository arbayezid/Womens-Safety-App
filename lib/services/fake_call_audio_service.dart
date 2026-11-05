import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/fake_caller.dart';
import 'fake_call_settings_service.dart';

/// Audio for the Fake Call screen (native FakeCallAudio on Android): ringtone with vibration while
/// ringing, then the caller's voice after the call is accepted (loudspeaker by default, earpiece
/// on request).
class FakeCallAudioService {
  FakeCallAudioService._internal();
  static final FakeCallAudioService instance = FakeCallAudioService._internal();

  static const MethodChannel _channel = MethodChannel('com.smartsafety.smart_safety/fake_call');

  /// Optional recorded English voice clip. When it is not bundled, the script below is spoken
  /// with the phone's built-in text-to-speech instead. (English voice, unchanged.)
  static const String voiceAssetPath = 'assets/sounds/fake_call_voice.mp3';

  /// Silence between two plays of a recorded Bangla/user clip, so the call never sounds like a loop.
  static const int recordedClipLoopGapMs = 4000;

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

  /// The call screen that owns the audio right now. A screen that is closing must not stop the
  /// sound of a newer call that already started (e.g. Decline then "Now" again quickly).
  Object? _owner;

  Future<void> startRinging({Object? owner}) async {
    _owner = owner;
    if (!_isSupported) return;
    try {
      final mode = await _channel.invokeMethod<String>('startRinging');
      debugPrint('[FakeCallAudio] Ringing mode: $mode');
    } catch (e) {
      debugPrint('[FakeCallAudio] Ringtone error: $e');
    }
  }

  /// Arguments for the native `startConversation` call for [source].
  @visibleForTesting
  static Map<String, Object> conversationArguments(FakeCallVoiceSource source, {required bool speaker}) {
    switch (source.kind) {
      case FakeCallVoiceKind.userRecording:
        return {
          'filePath': source.path,
          'assetPath': '',
          'script': conversationScript,
          'loopGapMs': recordedClipLoopGapMs,
          'speaker': speaker,
        };
      case FakeCallVoiceKind.bundledBangla:
        return {
          'filePath': '',
          'assetPath': source.path,
          'script': conversationScript,
          'loopGapMs': recordedClipLoopGapMs,
          'speaker': speaker,
        };
      case FakeCallVoiceKind.english:
        // Exactly the previous behaviour: optional English clip, looping, else English TTS.
        return {
          'filePath': '',
          'assetPath': voiceAssetPath,
          'script': conversationScript,
          'loopGapMs': 0,
          'speaker': speaker,
        };
    }
  }

  /// Starts the conversation audio for [caller]. Returns `asset`, `file`, `tts`, `unavailable`
  /// (no audio could be played: the caller should tell the user), `stopped`, or `unsupported`
  /// on other platforms.
  Future<String> startConversation({
    required FakeCaller caller,
    bool speaker = true,
  }) async {
    if (!_isSupported) return 'unsupported';
    final source = await FakeCallSettingsService.instance.resolveVoice(caller);
    debugPrint('[FakeCallAudio] Voice for ${caller.preset.name}: $source');
    try {
      final mode = await _channel.invokeMethod<String>(
        'startConversation',
        conversationArguments(source, speaker: speaker),
      );
      debugPrint('[FakeCallAudio] Conversation mode: $mode');
      return mode ?? 'unavailable';
    } catch (e) {
      debugPrint('[FakeCallAudio] Conversation audio error: $e');
      return 'unavailable';
    }
  }

  /// Routes the caller's voice to the loudspeaker ([speaker] true) or the earpiece.
  Future<void> setSpeaker(bool speaker) async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod('setSpeaker', {'speaker': speaker});
    } catch (e) {
      debugPrint('[FakeCallAudio] Speaker toggle error: $e');
    }
  }

  /// Stops every fake-call sound and vibration. With [owner], only if that call screen still
  /// owns the audio.
  Future<void> stop({Object? owner}) async {
    if (owner != null && _owner != null && !identical(owner, _owner)) return;
    _owner = null;
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[FakeCallAudio] Stop error: $e');
    }
  }
}
