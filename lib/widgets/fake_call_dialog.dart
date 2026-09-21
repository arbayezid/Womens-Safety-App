import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/activity_service.dart';
import '../services/contact_service.dart';

/// Full-screen realistic incoming phone call simulator.
///
/// Designed as a discreet, authentic escape mechanism for women in uncomfortable
/// or unsafe environments. Simulates an incoming call with vibration and an active
/// call timer upon answering.
class FakeCallDialog extends StatefulWidget {
  const FakeCallDialog({super.key});

  /// Displays the fake call simulator as a full-screen modal route.
  static Future<void> show(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => const FakeCallDialog(),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(opacity: anim, child: child);
        },
      ),
    );
  }

  @override
  State<FakeCallDialog> createState() => _FakeCallDialogState();
}

class _FakeCallDialogState extends State<FakeCallDialog> {
  bool _isCallAnswered = false;
  bool _isMuted = false;
  bool _isSpeaker = false;

  Timer? _vibrationTimer;
  Timer? _callDurationTimer;
  int _secondsElapsed = 0;

  late String _callerName;
  late String _callerPhone;

  @override
  void initState() {
    super.initState();

    // Dynamically use primary contact or Mom as caller
    final contacts = ContactService.instance.contacts;
    final primary = contacts.where((c) => c.isPrimary).firstOrNull ??
        contacts.firstOrNull;

    _callerName = primary?.name ?? 'Mom';
    _callerPhone = primary != null && primary.phone.isNotEmpty
        ? primary.phone
        : '+880 1711-000001';

    _startIncomingRinging();
    ActivityService.instance.logQuickAction('Fake Call');
  }

  @override
  void dispose() {
    _vibrationTimer?.cancel();
    _callDurationTimer?.cancel();
    super.dispose();
  }

  void _startIncomingRinging() {
    HapticFeedback.vibrate();
    _vibrationTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!_isCallAnswered && mounted) {
        HapticFeedback.vibrate();
      }
    });
  }

  void _answerCall() {
    _vibrationTimer?.cancel();
    HapticFeedback.heavyImpact();

    setState(() {
      _isCallAnswered = true;
    });

    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
        });
      }
    });
  }

  void _endCall() {
    HapticFeedback.mediumImpact();
    _vibrationTimer?.cancel();
    _callDurationTimer?.cancel();
    Navigator.of(context).pop();
  }

  String _formatTimer(int totalSeconds) {
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    final minStr = minutes.toString().padLeft(2, '0');
    final secStr = seconds.toString().padLeft(2, '0');
    return '$minStr:$secStr';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: _isCallAnswered ? _buildActiveCallUI() : _buildIncomingCallUI(),
      ),
    );
  }

  /// 1. Incoming Call Screen UI
  Widget _buildIncomingCallUI() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const SizedBox(height: 30),

        // Caller Info
        Column(
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C63FF), Color(0xFF3F3D56)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  _callerName.isNotEmpty ? _callerName[0].toUpperCase() : 'M',
                  style: GoogleFonts.poppins(
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _callerName,
              style: GoogleFonts.poppins(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _callerPhone,
              style: GoogleFonts.poppins(
                fontSize: 15,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Incoming Call...',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  color: const Color(0xFF53D769),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),

        // Accept / Decline buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Decline
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _endCall,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.sosRed,
                      ),
                      child: const Icon(Icons.call_end_rounded,
                          color: Colors.white, size: 34),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Decline',
                    style: GoogleFonts.poppins(
                        color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),

              // Accept
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _answerCall,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF34C759),
                      ),
                      child: const Icon(Icons.call_rounded,
                          color: Colors.white, size: 34),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Accept',
                    style: GoogleFonts.poppins(
                        color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 2. Active Call Screen UI
  Widget _buildActiveCallUI() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const SizedBox(height: 30),

        // Caller Info & Timer
        Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF2C303E),
              ),
              child: Center(
                child: Text(
                  _callerName.isNotEmpty ? _callerName[0].toUpperCase() : 'M',
                  style: GoogleFonts.poppins(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _callerName,
              style: GoogleFonts.poppins(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _formatTimer(_secondsElapsed),
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF34C759),
              ),
            ),
          ],
        ),

        // Call Control Buttons (Mute, Keypad, Speaker)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _callOption(
                    icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    label: _isMuted ? 'Unmute' : 'Mute',
                    isActive: _isMuted,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _isMuted = !_isMuted);
                    },
                  ),
                  _callOption(
                    icon: Icons.dialpad_rounded,
                    label: 'Keypad',
                    isActive: false,
                    onTap: () => HapticFeedback.selectionClick(),
                  ),
                  _callOption(
                    icon: _isSpeaker
                        ? Icons.volume_up_rounded
                        : Icons.volume_down_rounded,
                    label: 'Speaker',
                    isActive: _isSpeaker,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _isSpeaker = !_isSpeaker);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),

        // Hang Up Button
        Padding(
          padding: const EdgeInsets.only(bottom: 40),
          child: GestureDetector(
            onTap: _endCall,
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosRed,
              ),
              child: const Icon(Icons.call_end_rounded,
                  color: Colors.white, size: 34),
            ),
          ),
        ),
      ],
    );
  }

  Widget _callOption({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? Colors.white : const Color(0xFF1F2430),
            ),
            child: Icon(
              icon,
              color: isActive ? Colors.black : Colors.white,
              size: 26,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
