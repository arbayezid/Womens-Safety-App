import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fake_caller.dart';

/// Where the caller's voice comes from when a Fake Call is answered.
enum FakeCallVoiceKind {
  /// A clip the user recorded on this phone for that caller.
  userRecording,

  /// A real human recording bundled in `assets/fake_call/bn/`.
  bundledBangla,

  /// The original English audio (optional English clip, otherwise the English TTS script).
  english,
}

class FakeCallVoiceSource {
  final FakeCallVoiceKind kind;

  /// File path for [FakeCallVoiceKind.userRecording], asset path for [FakeCallVoiceKind.bundledBangla],
  /// empty for [FakeCallVoiceKind.english].
  final String path;

  const FakeCallVoiceSource(this.kind, [this.path = '']);

  static const FakeCallVoiceSource english = FakeCallVoiceSource(FakeCallVoiceKind.english);

  @override
  bool operator ==(Object other) => other is FakeCallVoiceSource && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);

  @override
  String toString() => 'FakeCallVoiceSource(${kind.name}, $path)';
}

/// Bundled clips at or below this size are placeholders (a fraction of a second of silence),
/// not real recordings, and are skipped. A real 10-second clip at 48 kbps is about 60 KB.
const int fakeCallPlaceholderMaxBytes = 16 * 1024;

String bundledBanglaClipPath(FakeCallerPreset preset) => 'assets/fake_call/bn/${preset.bundledClipKey}.mp3';

/// Playback priority: the user's own recording for that caller, then (Bangla only) the bundled
/// Bangla clip for that caller, then the existing English audio.
///
/// [userRecordingPath] returns the path of a non-empty recording, or null.
/// [bundledAssetSize] returns the asset's size in bytes, or 0 when it is not bundled.
Future<FakeCallVoiceSource> resolveFakeCallVoice({
  required FakeCallerPreset preset,
  required FakeCallVoiceLanguage language,
  required Future<String?> Function(FakeCallerPreset preset) userRecordingPath,
  required Future<int> Function(String assetPath) bundledAssetSize,
}) async {
  try {
    final recording = await userRecordingPath(preset);
    if (recording != null && recording.isNotEmpty) {
      return FakeCallVoiceSource(FakeCallVoiceKind.userRecording, recording);
    }
  } catch (e) {
    debugPrint('[FakeCallVoice] Recording lookup failed: $e');
  }
  if (language == FakeCallVoiceLanguage.bangla) {
    final asset = bundledBanglaClipPath(preset);
    try {
      final size = await bundledAssetSize(asset);
      if (size > fakeCallPlaceholderMaxBytes) {
        return FakeCallVoiceSource(FakeCallVoiceKind.bundledBangla, asset);
      }
      debugPrint('[FakeCallVoice] $asset is missing or still a placeholder ($size bytes); using English audio');
    } catch (e) {
      debugPrint('[FakeCallVoice] Bundled clip lookup failed: $e');
    }
  }
  return FakeCallVoiceSource.english;
}

/// Fake Call preferences (caller, voice language) and the user's own caller recordings.
/// Everything is stored on this phone only.
class FakeCallSettingsService {
  FakeCallSettingsService._internal();
  static final FakeCallSettingsService instance = FakeCallSettingsService._internal();

  static const String prefCallerPreset = 'fake_call_caller_preset';
  static const String prefCustomName = 'fake_call_custom_name';
  static const String prefCustomPhone = 'fake_call_custom_phone';
  static const String prefVoiceLanguage = 'fake_call_voice_language';

  static const String _recordingsFolder = 'fake_call_voices';
  static const String recordingExtension = 'm4a';
  static const String recordingMimeType = 'audio/mp4';

  /// Current default caller, for screens that show it (Followed Mode, Settings).
  final ValueNotifier<FakeCaller> callerNotifier = ValueNotifier<FakeCaller>(FakeCaller.defaultCaller);

  final Map<String, int> _assetSizeCache = {};

  Future<FakeCaller> loadCaller() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final preset = FakeCallerPresetInfo.fromId(prefs.getString(prefCallerPreset));
      if (preset == null) return _publish(FakeCaller.defaultCaller);
      final caller = FakeCaller(
        preset,
        customName: prefs.getString(prefCustomName) ?? '',
        customPhone: prefs.getString(prefCustomPhone) ?? '',
      );
      return _publish(caller.isValid ? caller : FakeCaller.defaultCaller);
    } catch (e) {
      debugPrint('[FakeCallSettings] Load failed: $e');
      return callerNotifier.value;
    }
  }

  /// Remembers [caller] as the default for every Fake Call entry point.
  Future<void> saveCaller(FakeCaller caller) async {
    if (!caller.isValid) return;
    _publish(caller);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefCallerPreset, caller.preset.name);
      // The custom name/number are kept when a preset is picked, so switching back is quick.
      if (caller.preset == FakeCallerPreset.custom) {
        await prefs.setString(prefCustomName, caller.customName.trim());
        await prefs.setString(prefCustomPhone, caller.customPhone.trim());
      }
    } catch (e) {
      debugPrint('[FakeCallSettings] Save failed: $e');
    }
  }

  /// The last custom name/number typed, to prefill the picker.
  Future<FakeCaller> lastCustomCaller() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return FakeCaller(
        FakeCallerPreset.custom,
        customName: prefs.getString(prefCustomName) ?? '',
        customPhone: prefs.getString(prefCustomPhone) ?? '',
      );
    } catch (_) {
      return const FakeCaller(FakeCallerPreset.custom);
    }
  }

  FakeCaller _publish(FakeCaller caller) {
    callerNotifier.value = caller;
    return caller;
  }

  Future<FakeCallVoiceLanguage> loadLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return FakeCallVoiceLanguageInfo.fromId(prefs.getString(prefVoiceLanguage));
    } catch (_) {
      return FakeCallVoiceLanguage.bangla;
    }
  }

  Future<void> saveLanguage(FakeCallVoiceLanguage language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefVoiceLanguage, language.name);
    } catch (e) {
      debugPrint('[FakeCallSettings] Save language failed: $e');
    }
  }

  Future<Directory> recordingsDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$_recordingsFolder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Where the user's recording for [preset] is (or will be) saved.
  Future<File> recordingFile(FakeCallerPreset preset) async {
    final dir = await recordingsDirectory();
    return File('${dir.path}${Platform.pathSeparator}${preset.name}.$recordingExtension');
  }

  /// The user's non-empty recording for [preset], or null.
  Future<File?> existingRecording(FakeCallerPreset preset) async {
    try {
      final file = await recordingFile(preset);
      if (await file.exists() && await file.length() > 0) return file;
    } catch (e) {
      debugPrint('[FakeCallSettings] Recording lookup failed: $e');
    }
    return null;
  }

  Future<void> deleteRecording(FakeCallerPreset preset) async {
    try {
      final file = await recordingFile(preset);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[FakeCallSettings] Delete recording failed: $e');
    }
  }

  Future<int> _bundledAssetSize(String assetPath) async {
    final cached = _assetSizeCache[assetPath];
    if (cached != null) return cached;
    int size;
    try {
      final data = await rootBundle.load(assetPath);
      size = data.lengthInBytes;
    } catch (_) {
      size = 0;
    }
    _assetSizeCache[assetPath] = size;
    return size;
  }

  /// Picks the voice for [caller] using the saved language and the user's recordings.
  Future<FakeCallVoiceSource> resolveVoice(FakeCaller caller) async {
    final language = await loadLanguage();
    return resolveFakeCallVoice(
      preset: caller.preset,
      language: language,
      userRecordingPath: (p) async => (await existingRecording(p))?.path,
      bundledAssetSize: _bundledAssetSize,
    );
  }
}
