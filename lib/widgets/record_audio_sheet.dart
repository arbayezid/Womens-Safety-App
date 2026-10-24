import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_colors.dart';
import '../services/audio_record_service.dart';

/// Modal bottom sheet widget for recording an emergency voice note and dispatching
/// it to mutual guardians and emergency contacts.
///
/// Features:
/// - Real-time timer indicator (00:01 up to 01:00)
/// - Pulsing microphone animation with ripple halo
/// - Prominent "Stop & Send Alert" and "Cancel" actions
/// - 60-second automatic timeout with auto-dispatch
/// - Non-intrusive progress state ("Sending audio to emergency contacts...")
/// - Automatic local cache cleanup upon upload or cancellation
class RecordAudioSheet extends StatefulWidget {
  const RecordAudioSheet({super.key});

  /// Convenience method to open the bottom sheet modal.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const RecordAudioSheet(),
    );
  }

  @override
  State<RecordAudioSheet> createState() => _RecordAudioSheetState();
}

/// Alias for compatibility
typedef RecordAudioModal = RecordAudioSheet;

class _RecordAudioSheetState extends State<RecordAudioSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  late final Animation<double> _haloFade;

  bool _isInitializing = true;
  bool _permissionDenied = false;
  bool _isSending = false;
  String? _statusText;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 1.0, end: 1.16).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _haloFade = Tween<double>(begin: 0.25, end: 0.65).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startRecordingFlow();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// Verifies microphone permission and starts audio recording.
  Future<void> _startRecordingFlow() async {
    setState(() {
      _isInitializing = true;
      _permissionDenied = false;
    });

    final hasPerm = await AudioRecordService.instance.requestMicrophonePermission();
    if (!mounted) return;

    if (!hasPerm) {
      setState(() {
        _isInitializing = false;
        _permissionDenied = true;
      });
      return;
    }

    // Start recording with 60-second automatic timeout
    final success = await AudioRecordService.instance.startRecording(
      onTimeout: () {
        if (mounted && !_isSending) {
          debugPrint('[RecordAudioSheet] ⏱️ Timeout auto-dispatching audio alert...');
          _stopAndSendAlert();
        }
      },
    );

    if (!mounted) return;

    if (!success) {
      setState(() {
        _isInitializing = false;
        _permissionDenied = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to initialize audio recorder. Please try again.',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
          ),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ),
      );
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _isInitializing = false;
      _permissionDenied = false;
    });
  }

  /// Stops recording and triggers cloud upload and multi-channel dispatch.
  Future<void> _stopAndSendAlert() async {
    if (_isSending) return;

    HapticFeedback.heavyImpact();

    setState(() {
      _isSending = true;
      _statusText = 'Sending audio to emergency contacts...';
    });

    try {
      final recordedPath = await AudioRecordService.instance.stopRecording();
      if (!mounted) return;

      if (recordedPath == null) {
        throw Exception('No audio recording data available.');
      }

      final result = await AudioRecordService.instance.uploadAndDispatchAlert(
        filePath: recordedPath,
      );

      if (!mounted) return;

      // Close bottom sheet
      Navigator.of(context).pop();

      // Show confirmation SnackBar
      if (result.isSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Audio alert sent successfully!',
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.successForeground,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            ),
            backgroundColor: AppColors.sosRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to dispatch audio alert: ${e.toString().replaceAll('Exception: ', '')}',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
          ),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Cancels recording, purges local cache, and closes sheet without dispatching.
  Future<void> _cancelRecording() async {
    HapticFeedback.lightImpact();
    await AudioRecordService.instance.cancelRecording();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  String _formatTimer(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSending,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_isSending) {
          AudioRecordService.instance.cancelRecording();
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 20,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isSending) {
      return _buildSendingState();
    }

    if (_permissionDenied) {
      return _buildPermissionDeniedState();
    }

    if (_isInitializing) {
      return _buildInitializingState();
    }

    return _buildActiveRecordingState();
  }

  /// Loading state while initiating recording session
  Widget _buildInitializingState() {
    return Column(
      key: const ValueKey('initializing'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrabHandle(),
        const SizedBox(height: 36),
        const SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(
            color: AppColors.actionPurple,
            strokeWidth: 3,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Preparing microphone...',
          style: GoogleFonts.poppins(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 28),
      ],
    );
  }

  /// Polite fallback UI when microphone permission is denied
  Widget _buildPermissionDeniedState() {
    return Column(
      key: const ValueKey('denied'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrabHandle(),
        const SizedBox(height: 24),
        Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            color: const Color(0xFFF0E6F9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.mic_off_rounded,
            size: 34,
            color: AppColors.actionPurple,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Microphone Permission Required',
          style: GoogleFonts.poppins(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Woman Guard needs access to your microphone to record emergency voice notes for your trusted contacts.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 13,
            color: AppColors.textSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: AppColors.divider),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  'Dismiss',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () async {
                  await openAppSettings();
                  if (mounted) Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: AppColors.actionPurple,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  'Open Settings',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Non-intrusive progress state when recording has stopped and is dispatching
  Widget _buildSendingState() {
    return Column(
      key: const ValueKey('sending'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrabHandle(),
        const SizedBox(height: 36),
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: const Color(0xFFF0E6F9),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                color: AppColors.actionPurple,
                strokeWidth: 3.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          _statusText ?? 'Sending audio to emergency contacts...',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Uploading recording and broadcasting live GPS coordinates',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 12.5,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  /// Active recording state with pulsating mic, timer, and primary buttons
  Widget _buildActiveRecordingState() {
    return Column(
      key: const ValueKey('active'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrabHandle(),
        const SizedBox(height: 16),

        // Header Title
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF0E6F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.sosRed,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'RECORDING AUDIO',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.actionPurple,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),

        // Pulsing Microphone with animated halo
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                // Outer subtle halo
                Transform.scale(
                  scale: _pulseScale.value * 1.15,
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.actionPurple.withValues(alpha: _haloFade.value * 0.25),
                    ),
                  ),
                ),
                // Inner glowing halo
                Transform.scale(
                  scale: _pulseScale.value,
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.actionPurple.withValues(alpha: _haloFade.value * 0.4),
                    ),
                  ),
                ),
                // Core Mic Button
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [AppColors.actionPurple, Color(0xFF7C3AED)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.actionPurple.withValues(alpha: 0.4),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.mic_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
              ],
            );
          },
        ),

        const SizedBox(height: 20),

        // Active Timer Stream & Progress Indicator (up to 60s)
        ValueListenableBuilder<int>(
          valueListenable: AudioRecordService.instance.durationNotifier,
          builder: (context, seconds, child) {
            final double progress = (seconds / 60.0).clamp(0.0, 1.0);

            return Column(
              children: [
                Text(
                  _formatTimer(seconds),
                  style: GoogleFonts.poppins(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Max duration: 01:00 • Auto-sends at 60s',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 5,
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: const Color(0xFFE5E5EA),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        progress > 0.85 ? AppColors.sosRed : AppColors.actionPurple,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),

        const SizedBox(height: 28),

        // Action Buttons: "Stop & Send Alert" and "Cancel"
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: _stopAndSendAlert,
              icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
              label: Text(
                'Stop & Send Alert',
                style: GoogleFonts.poppins(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.actionPurple,
                padding: const EdgeInsets.symmetric(vertical: 16),
                elevation: 3,
                shadowColor: AppColors.actionPurple.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _cancelRecording,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Cancel & Discard',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGrabHandle() {
    return Center(
      child: Container(
        width: 38,
        height: 4.5,
        decoration: BoxDecoration(
          color: const Color(0xFFD1D1D6),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
