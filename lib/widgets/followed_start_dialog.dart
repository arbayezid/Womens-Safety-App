import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../core/app_text.dart';
import '../core/app_tokens.dart';

/// Starts Followed Mode after a short countdown instead of asking for confirmation:
/// one tap is enough when someone is following you, and a mistaken tap can still be cancelled.
///
/// Silent on purpose (light vibration only). Returns true to start, false when cancelled.
class FollowedStartDialog extends StatefulWidget {
  const FollowedStartDialog({super.key, this.seconds = 5});

  final int seconds;

  static Future<bool> show(BuildContext context) async {
    final start = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const FollowedStartDialog(),
    );
    return start == true;
  }

  @override
  State<FollowedStartDialog> createState() => _FollowedStartDialogState();
}

class _FollowedStartDialogState extends State<FollowedStartDialog> {
  late int _left = widget.seconds;
  Timer? _timer;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_left <= 1) {
        _close(true);
      } else {
        HapticFeedback.selectionClick();
        setState(() => _left--);
      }
    });
  }

  void _close(bool start) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (mounted) Navigator.of(context).pop(start);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close(false);
      },
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: AppColors.actionOrange.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: AppColors.actionOrange,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$_left',
                    style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Starting Followed Mode',
                textAlign: TextAlign.center,
                style: AppText.greeting.copyWith(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Your guardians will be alerted and see your live location.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => _close(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.actionOrange,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: Text(
                    'Start now',
                    style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => _close(false),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
