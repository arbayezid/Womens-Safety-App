import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/pin_security_service.dart';

/// Operational mode for [PinInputDialog]
enum PinDialogMode {
  verify,
  setupReal,
  setupDuress,
}

/// Reusable PIN entry dialog featuring a custom numerical keypad,
/// reactive PIN dot indicators, error animations, and support for
/// verification, real PIN setup, and silent duress PIN creation.
class PinInputDialog extends StatefulWidget {
  final PinDialogMode mode;
  final String? customTitle;
  final String? customSubtitle;
  final bool cancellable;

  const PinInputDialog({
    super.key,
    required this.mode,
    this.customTitle,
    this.customSubtitle,
    this.cancellable = true,
  });

  /// Displays the modal PIN input dialog
  static Future<bool?> show(
    BuildContext context, {
    required PinDialogMode mode,
    String? customTitle,
    String? customSubtitle,
    bool cancellable = true,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: cancellable,
      builder: (_) => PinInputDialog(
        mode: mode,
        customTitle: customTitle,
        customSubtitle: customSubtitle,
        cancellable: cancellable,
      ),
    );
  }

  @override
  State<PinInputDialog> createState() => _PinInputDialogState();
}

class _PinInputDialogState extends State<PinInputDialog>
    with SingleTickerProviderStateMixin {
  String _enteredPin = '';
  String? _firstEnteredPin; // Used during setup confirmation
  String? _errorMessage;
  bool _isProcessing = false;
  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -12.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -12.0, end: 12.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 12.0, end: -10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  void _triggerErrorShake(String message) {
    HapticFeedback.heavyImpact();
    setState(() {
      _errorMessage = message;
      _enteredPin = '';
    });
    _shakeController.forward(from: 0.0);
  }

  void _onDigitPressed(String digit) {
    if (_isProcessing || _enteredPin.length >= 6) return;
    HapticFeedback.lightImpact();

    setState(() {
      _errorMessage = null;
      _enteredPin += digit;
    });

    // Auto-evaluate when 4 digits entered in verify or setup modes
    if (_enteredPin.length == 4) {
      _handlePinCompleted();
    }
  }

  void _onBackspacePressed() {
    if (_isProcessing || _enteredPin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _errorMessage = null;
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
    });
  }

  Future<void> _handlePinCompleted() async {
    if (_isProcessing) return;
    final pin = _enteredPin;

    if (widget.mode == PinDialogMode.verify) {
      setState(() => _isProcessing = true);
      try {
        final result = await PinSecurityService.instance.verifyPin(pin);
        if (!mounted) return;

        if (result == PinVerificationResult.real) {
          HapticFeedback.mediumImpact();
          Navigator.of(context).pop(true);
        } else if (result == PinVerificationResult.duress) {
          // Duress pipeline automatically triggered by service
          Navigator.of(context).pop(false);
        } else {
          setState(() => _isProcessing = false);
          _triggerErrorShake('Incorrect PIN. Please try again.');
        }
      } catch (e) {
        if (!mounted) return;
        setState(() => _isProcessing = false);
        _triggerErrorShake('Verification failed. Try again.');
      }
    } else {
      // Setup Mode (setupReal or setupDuress)
      if (_firstEnteredPin == null) {
        // Step 1 completed, advance to confirmation
        setState(() {
          _firstEnteredPin = pin;
          _enteredPin = '';
        });
      } else {
        // Step 2 confirmation
        if (pin != _firstEnteredPin) {
          setState(() {
            _firstEnteredPin = null;
          });
          _triggerErrorShake('PINs did not match. Please try again.');
          return;
        }

        setState(() => _isProcessing = true);
        try {
          if (widget.mode == PinDialogMode.setupReal) {
            await PinSecurityService.instance.setRealPin(pin);
          } else {
            await PinSecurityService.instance.setDuressPin(pin);
          }
          if (!mounted) return;
          HapticFeedback.mediumImpact();
          Navigator.of(context).pop(true);
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _isProcessing = false;
            _firstEnteredPin = null;
          });
          _triggerErrorShake(e.toString().replaceAll('Exception: ', ''));
        }
      }
    }
  }

  String get _title {
    if (widget.customTitle != null) return widget.customTitle!;
    switch (widget.mode) {
      case PinDialogMode.verify:
        return 'Enter Security PIN';
      case PinDialogMode.setupReal:
        return _firstEnteredPin == null ? 'Set Real Security PIN' : 'Confirm Real PIN';
      case PinDialogMode.setupDuress:
        return _firstEnteredPin == null ? 'Set Duress Emergency PIN' : 'Confirm Duress PIN';
    }
  }

  String get _subtitle {
    if (widget.customSubtitle != null && _firstEnteredPin == null) {
      return widget.customSubtitle!;
    }
    switch (widget.mode) {
      case PinDialogMode.verify:
        return 'Enter your 4-digit PIN to proceed';
      case PinDialogMode.setupReal:
        return _firstEnteredPin == null
            ? 'Choose a 4-digit PIN you will remember'
            : 'Re-enter your 4-digit PIN to confirm';
      case PinDialogMode.setupDuress:
        return _firstEnteredPin == null
            ? 'Choose an alternative PIN for silent emergencies'
            : 'Re-enter your Duress PIN to confirm';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDuressSetup = widget.mode == PinDialogMode.setupDuress;

    return PopScope(
      canPop: widget.cancellable,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Header Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isDuressSetup
                            ? const Color(0xFFFFEEEE)
                            : AppColors.primarySurface,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isDuressSetup
                            ? Icons.warning_amber_rounded
                            : Icons.lock_outline_rounded,
                        color: isDuressSetup ? AppColors.sosRed : AppColors.primary,
                        size: 22,
                      ),
                    ),
                    if (widget.cancellable)
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                        onPressed: () => Navigator.of(context).pop(null),
                      )
                    else
                      const SizedBox(width: 40),
                  ],
                ),
                const SizedBox(height: 12),

                // Title & Subtitle
                Text(
                  _title,
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  _subtitle,
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                    height: 1.35,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),

                // Duress notice banner for setup mode
                if (isDuressSetup && _firstEnteredPin == null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.actionOrange.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      'Entering this PIN anywhere triggers a silent emergency and transforms Woman Guard into a calculator.',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: const Color(0xFFC2410C),
                        height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),

                // Animated PIN Dot Indicators
                AnimatedBuilder(
                  animation: _shakeAnimation,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(_shakeAnimation.value, 0),
                    child: child,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (index) {
                      final isFilled = index < _enteredPin.length;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isFilled
                              ? (isDuressSetup ? AppColors.sosRed : AppColors.primary)
                              : Colors.transparent,
                          border: Border.all(
                            color: isFilled
                                ? (isDuressSetup ? AppColors.sosRed : AppColors.primary)
                                : Colors.black.withValues(alpha: 0.25),
                            width: 2,
                          ),
                        ),
                      );
                    }),
                  ),
                ),

                const SizedBox(height: 8),

                // Error message
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      _errorMessage!,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.sosRed,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  const SizedBox(height: 18),

                // Numerical Keypad (1 to 9, empty, 0, backspace)
                _buildKeypad(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return Column(
      children: [
        _buildKeypadRow(['1', '2', '3']),
        const SizedBox(height: 10),
        _buildKeypadRow(['4', '5', '6']),
        const SizedBox(height: 10),
        _buildKeypadRow(['7', '8', '9']),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(child: SizedBox(height: 52)),
            Expanded(child: _buildKeypadButton('0', onTap: () => _onDigitPressed('0'))),
            Expanded(
              child: SizedBox(
                height: 52,
                child: IconButton(
                  icon: const Icon(Icons.backspace_outlined, size: 22, color: AppColors.textPrimary),
                  onPressed: _onBackspacePressed,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildKeypadRow(List<String> digits) {
    return Row(
      children: digits
          .map(
            (d) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _buildKeypadButton(d, onTap: () => _onDigitPressed(d)),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildKeypadButton(String digit, {required VoidCallback onTap}) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _isProcessing ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFF4F4F6),
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          digit,
          style: GoogleFonts.poppins(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
