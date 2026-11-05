import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../core/app_colors.dart';
import '../models/fake_caller.dart';
import '../services/fake_call_settings_service.dart';

/// "Record my own caller voice": one clip per caller, recorded with the microphone and kept on
/// this phone only. A recording overrides the bundled clip and the voice language for that caller.
class FakeCallVoiceScreen extends StatefulWidget {
  const FakeCallVoiceScreen({super.key});

  @override
  State<FakeCallVoiceScreen> createState() => _FakeCallVoiceScreenState();
}

class _FakeCallVoiceScreenState extends State<FakeCallVoiceScreen> {
  static const Duration _maxLength = Duration(minutes: 2);

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _playerDoneSub;

  final Set<FakeCallerPreset> _recorded = {};
  FakeCallerPreset? _recordingFor;
  FakeCallerPreset? _playingFor;
  File? _pendingFile;
  Timer? _elapsedTimer;
  int _elapsedSeconds = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _playerDoneSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingFor = null);
    });
    _refresh();
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _playerDoneSub?.cancel();
    _player.dispose();
    // Leaving mid-recording discards the new take and keeps the previous recording.
    if (_recordingFor != null) {
      _recorder.cancel().catchError((_) {});
      _deletePending();
    }
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final recorded = <FakeCallerPreset>{};
    for (final preset in FakeCallerPreset.values) {
      if (await FakeCallSettingsService.instance.existingRecording(preset) != null) recorded.add(preset);
    }
    if (!mounted) return;
    setState(() {
      _recorded
        ..clear()
        ..addAll(recorded);
      _loading = false;
    });
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating, action: action),
    );
  }

  Future<bool> _ensureMicrophone() async {
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted) return true;
      status = await Permission.microphone.request();
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied || status.isRestricted) {
        _snack(
          'Microphone access is off for Woman Guard. Turn it on in phone settings to record.',
          action: SnackBarAction(label: 'Open Settings', onPressed: () => openAppSettings()),
        );
      } else {
        _snack('Microphone permission is needed to record a caller voice.');
      }
    } catch (e) {
      _snack('Could not check microphone permission.');
    }
    return false;
  }

  Future<void> _startRecording(FakeCallerPreset preset) async {
    if (_recordingFor != null) return;
    if (!await _ensureMicrophone()) return;
    await _stopPreview();

    try {
      final target = await FakeCallSettingsService.instance.recordingFile(preset);
      // Record to a temporary file first, so a cancelled re-record keeps the old clip.
      final pending = File(target.path.replaceFirst(
        RegExp(r'\.' + FakeCallSettingsService.recordingExtension + r'$'),
        '.new.${FakeCallSettingsService.recordingExtension}',
      ));
      if (await pending.exists()) await pending.delete();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: pending.path,
      );
      HapticFeedback.mediumImpact();
      _pendingFile = pending;
      _elapsedSeconds = 0;
      _elapsedTimer?.cancel();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsedSeconds++);
        if (_elapsedSeconds >= _maxLength.inSeconds) _stopRecording();
      });
      if (mounted) setState(() => _recordingFor = preset);
    } catch (e) {
      debugPrint('[FakeCallVoice] Could not start recording: $e');
      _snack('Could not start recording. Is another app using the microphone?');
      _deletePending();
    }
  }

  Future<void> _stopRecording() async {
    final preset = _recordingFor;
    if (preset == null) return;
    _elapsedTimer?.cancel();
    final seconds = _elapsedSeconds;
    setState(() => _recordingFor = null);
    try {
      await _recorder.stop();
      final pending = _pendingFile;
      _pendingFile = null;
      if (pending == null || !await pending.exists() || await pending.length() == 0) {
        _snack('Nothing was recorded. Please try again.');
        return;
      }
      if (seconds < 3) {
        await pending.delete();
        _snack('Too short. Read the whole script, with pauses.');
        return;
      }
      final target = await FakeCallSettingsService.instance.recordingFile(preset);
      if (await target.exists()) await target.delete();
      await pending.rename(target.path);
      HapticFeedback.lightImpact();
      _snack('Saved. ${_callerLabel(preset)} will now use your recording.');
    } catch (e) {
      debugPrint('[FakeCallVoice] Could not save recording: $e');
      _snack('Could not save the recording.');
      _deletePending();
    }
    await _refresh();
  }

  void _deletePending() {
    final pending = _pendingFile;
    _pendingFile = null;
    if (pending == null) return;
    pending.exists().then((exists) {
      if (exists) pending.delete();
    }).catchError((_) {});
  }

  Future<void> _togglePreview(FakeCallerPreset preset) async {
    if (_playingFor == preset) {
      await _stopPreview();
      return;
    }
    await _stopPreview();
    final file = await FakeCallSettingsService.instance.existingRecording(preset);
    if (file == null) return;
    try {
      await _player.play(DeviceFileSource(file.path, mimeType: FakeCallSettingsService.recordingMimeType));
      if (mounted) setState(() => _playingFor = preset);
    } catch (e) {
      debugPrint('[FakeCallVoice] Preview failed: $e');
      _snack('Could not play this recording.');
    }
  }

  Future<void> _stopPreview() async {
    if (_playingFor == null) return;
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) setState(() => _playingFor = null);
  }

  Future<void> _delete(FakeCallerPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text('${_callerLabel(preset)} will go back to the built-in voice.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_playingFor == preset) await _stopPreview();
    await FakeCallSettingsService.instance.deleteRecording(preset);
    await _refresh();
  }

  String _callerLabel(FakeCallerPreset preset) =>
      preset == FakeCallerPreset.custom ? 'Custom caller' : preset.displayName;

  String _formatSeconds(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
        title: Text(
          'My Caller Voices',
          style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Text(
                  'Record a short clip for each caller in your own (or a family member\'s) voice. '
                  'It plays when you answer a fake call from that caller, instead of the built-in voice. '
                  'Pause 2–4 seconds where you see "…" so you can "reply". Recordings stay on this phone.',
                  style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary, height: 1.45),
                ),
                const SizedBox(height: 16),
                for (final preset in FakeCallerPreset.values) ...[
                  _callerCard(preset),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }

  Widget _callerCard(FakeCallerPreset preset) {
    final isRecording = _recordingFor == preset;
    final busy = _recordingFor != null && !isRecording;
    final hasClip = _recorded.contains(preset);
    final isPlaying = _playingFor == preset;
    final script = preset.banglaScript;

    final String status;
    if (isRecording) {
      status = 'Recording… ${_formatSeconds(_elapsedSeconds)} / ${_formatSeconds(_maxLength.inSeconds)}';
    } else if (hasClip) {
      status = 'Your recording is used';
    } else {
      status = 'Not recorded (built-in voice)';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isRecording ? AppColors.sosRed : Colors.black.withValues(alpha: 0.06),
          width: isRecording ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.actionBlue.withValues(alpha: 0.12),
                child: Text(
                  preset == FakeCallerPreset.custom ? '+' : preset.displayName[0],
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: AppColors.actionBlue),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.pickerLabel,
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      status,
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        color: isRecording
                            ? AppColors.sosRed
                            : (hasClip ? AppColors.successForeground : AppColors.textSecondary),
                        fontWeight: isRecording || hasClip ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              script ?? 'Say anything a caller would say, with pauses so you can reply. '
                  'Without a recording, a custom caller uses the Bhaiya voice.',
              style: script != null
                  ? const TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.textPrimary)
                  : GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (isRecording)
                FilledButton.icon(
                  onPressed: _stopRecording,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Stop & Save'),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.sosRed),
                )
              else
                FilledButton.icon(
                  onPressed: busy ? null : () => _startRecording(preset),
                  icon: const Icon(Icons.mic_rounded, size: 18),
                  label: Text(hasClip ? 'Re-record' : 'Record'),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.actionBlue),
                ),
              if (hasClip && !isRecording) ...[
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _togglePreview(preset),
                  icon: Icon(isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18),
                  label: Text(isPlaying ? 'Stop' : 'Preview'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : () => _delete(preset),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.sosRed),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
