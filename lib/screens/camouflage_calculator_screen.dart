import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/emergency_service.dart';
import '../services/pin_security_service.dart';
import '../widgets/pin_input_dialog.dart';

/// Full-screen working calculator that serves as the camouflage disguise
/// during active Duress Mode or when Camouflage Mode is manually engaged.
///
/// **Secret Exit:**
/// Typing the user's secret [Real PIN] followed by the `=` button exits camouflage.
/// Typing the [Duress PIN] followed by `=` keeps the app in camouflage without revealing anything.
class CamouflageCalculatorScreen extends StatefulWidget {
  const CamouflageCalculatorScreen({super.key});

  @override
  State<CamouflageCalculatorScreen> createState() => _CamouflageCalculatorScreenState();
}

class _CamouflageCalculatorScreenState extends State<CamouflageCalculatorScreen> {
  String _display = '0';
  String _expression = '';
  String _secretBuffer = '';
  double? _firstOperand;
  String? _operator;
  bool _shouldResetDisplay = false;

  void _onDigit(String digit) {
    HapticFeedback.lightImpact();
    setState(() {
      _secretBuffer += digit;
      if (_secretBuffer.length > 12) {
        _secretBuffer = _secretBuffer.substring(_secretBuffer.length - 12);
      }

      if (_shouldResetDisplay || _display == '0') {
        _display = digit;
        _shouldResetDisplay = false;
      } else {
        _display += digit;
      }
    });
  }

  void _onDecimal() {
    HapticFeedback.lightImpact();
    setState(() {
      if (!_display.contains('.')) {
        _display += '.';
        _shouldResetDisplay = false;
      }
    });
  }

  void _onOperator(String op) {
    HapticFeedback.selectionClick();
    setState(() {
      _secretBuffer = ''; // Operators clear secret PIN buffer
      final val = double.tryParse(_display) ?? 0.0;
      if (_firstOperand != null && _operator != null && !_shouldResetDisplay) {
        _calculateIntermediate();
      } else {
        _firstOperand = val;
      }
      _operator = op;
      _expression = '${_formatNumber(_firstOperand!)} $op';
      _shouldResetDisplay = true;
    });
  }

  void _calculateIntermediate() {
    if (_firstOperand == null || _operator == null) return;
    final second = double.tryParse(_display) ?? 0.0;
    double result = 0.0;
    switch (_operator) {
      case '+':
        result = _firstOperand! + second;
        break;
      case '−':
        result = _firstOperand! - second;
        break;
      case '×':
        result = _firstOperand! * second;
        break;
      case '÷':
        result = second != 0 ? _firstOperand! / second : 0.0;
        break;
    }
    _firstOperand = result;
    _display = _formatNumber(result);
  }

  Future<void> _onEquals() async {
    HapticFeedback.selectionClick();

    final isConfigured = await PinSecurityService.instance.isRealPinConfigured();
    if (!isConfigured) {
      // If no PIN is configured yet, pressing '=' exits camouflage cleanly
      await PinSecurityService.instance.exitCamouflage();
      return;
    }

    // 1. Evaluate secret buffer against PIN security hashes
    final buffer = _secretBuffer.trim();
    if (buffer.isNotEmpty) {
      final candidates = <String>{buffer};
      for (int len = 4; len <= 6; len++) {
        if (buffer.length >= len) {
          candidates.add(buffer.substring(buffer.length - len));
        }
      }

      for (final candidate in candidates) {
        final wasDuress = PinSecurityService.instance.isDuressActive;
        final pinResult = await PinSecurityService.instance.verifyPin(candidate);
        if (pinResult == PinVerificationResult.real) {
          if (!mounted) return;
          if (wasDuress) {
            _showExitDisclosureDialog();
          }
          return;
        } else if (pinResult == PinVerificationResult.duress) {
          _secretBuffer = '';
        }
      }
    }

    // 2. Normal arithmetic evaluation
    setState(() {
      if (_firstOperand != null && _operator != null) {
        final second = double.tryParse(_display) ?? 0.0;
        _calculateIntermediate();
        _expression = '${_formatNumber(_firstOperand!)} $_operator ${_formatNumber(second)} =';
        _operator = null;
        _shouldResetDisplay = true;
      }
      _secretBuffer = '';
    });
  }

  void _onClear() {
    HapticFeedback.lightImpact();
    setState(() {
      _display = '0';
      _expression = '';
      _firstOperand = null;
      _operator = null;
      _shouldResetDisplay = false;
      _secretBuffer = '';
    });
  }

  void _onToggleSign() {
    HapticFeedback.lightImpact();
    setState(() {
      if (_display != '0') {
        if (_display.startsWith('-')) {
          _display = _display.substring(1);
        } else {
          _display = '-$_display';
        }
      }
    });
  }

  void _onPercent() {
    HapticFeedback.lightImpact();
    setState(() {
      final val = (double.tryParse(_display) ?? 0.0) / 100.0;
      _display = _formatNumber(val);
      _shouldResetDisplay = true;
    });
  }

  String _formatNumber(double val) {
    if (val == val.roundToDouble()) {
      return val.toInt().toString();
    }
    return val.toStringAsFixed(4).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  void _showExitDisclosureDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.shield_rounded, color: AppColors.actionGreen, size: 28),
            const SizedBox(width: 10),
            Text(
              'Security Restored',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 18),
            ),
          ],
        ),
        content: Text(
          'Real PIN verified. Camouflage mode has been exited.\n\nA silent emergency duress alert was previously triggered. Would you like to confirm you are safe now?',
          style: GoogleFonts.poppins(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Keep Alert Active', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await EmergencyService.instance.markSafe();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.actionGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(
              "I'm Safe Now",
              style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSecretExit() async {
    HapticFeedback.heavyImpact();
    final isConfigured = await PinSecurityService.instance.isRealPinConfigured();
    if (!isConfigured) {
      await PinSecurityService.instance.exitCamouflage();
      return;
    }
    if (!mounted) return;
    final verified = await PinInputDialog.show(
      context,
      mode: PinDialogMode.verify,
      customTitle: 'Exit Camouflage',
      customSubtitle: 'Enter your Security PIN to return to the app',
    );
    if (verified == true) {
      await PinSecurityService.instance.exitCamouflage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              const Spacer(),
              // Expression & Calculation Result Screen (Long-press to escape)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: _handleSecretExit,
                child: Container(
                  alignment: Alignment.bottomRight,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _expression,
                        style: GoogleFonts.robotoMono(
                          fontSize: 20,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          _display,
                          style: GoogleFonts.roboto(
                            fontSize: 64,
                            fontWeight: FontWeight.w300,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Keypad Buttons
              _buildKeypadRow(['C', '+/-', '%', '÷'], isTop: true),
              const SizedBox(height: 12),
              _buildKeypadRow(['7', '8', '9', '×']),
              const SizedBox(height: 12),
              _buildKeypadRow(['4', '5', '6', '−']),
              const SizedBox(height: 12),
              _buildKeypadRow(['1', '2', '3', '+']),
              const SizedBox(height: 12),
              _buildBottomKeypadRow(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeypadRow(List<String> labels, {bool isTop = false}) {
    return Row(
      children: labels.map((label) {
        final isOp = ['÷', '×', '−', '+'].contains(label);
        final bg = isOp
            ? const Color(0xFFFF9F0A)
            : isTop
                ? const Color(0xFFA5A5A5)
                : const Color(0xFF333333);
        final fg = isTop ? Colors.black : Colors.white;

        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _buildCalculatorButton(
              label: label,
              bgColor: bg,
              fgColor: fg,
              onLongPress: label == 'C' ? _handleSecretExit : null,
              onTap: () {
                if (label == 'C') {
                  _onClear();
                } else if (label == '+/-') {
                  _onToggleSign();
                } else if (label == '%') {
                  _onPercent();
                } else if (isOp) {
                  _onOperator(label);
                } else {
                  _onDigit(label);
                }
              },
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBottomKeypadRow() {
    return Row(
      children: [
        // '0' button spanning 2 columns
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SizedBox(
              height: 72,
              child: ElevatedButton(
                onPressed: () => _onDigit('0'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF333333),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(36)),
                  padding: const EdgeInsets.only(left: 28),
                  alignment: Alignment.centerLeft,
                  elevation: 0,
                ),
                child: Text(
                  '0',
                  style: GoogleFonts.roboto(fontSize: 28, color: Colors.white, fontWeight: FontWeight.w400),
                ),
              ),
            ),
          ),
        ),
        // '.' decimal button
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _buildCalculatorButton(
              label: '.',
              bgColor: const Color(0xFF333333),
              fgColor: Colors.white,
              onTap: _onDecimal,
            ),
          ),
        ),
        // '=' equals button
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _buildCalculatorButton(
              label: '=',
              bgColor: const Color(0xFFFF9F0A),
              fgColor: Colors.white,
              onTap: _onEquals,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCalculatorButton({
    required String label,
    required Color bgColor,
    required Color fgColor,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return SizedBox(
      height: 72,
      child: ElevatedButton(
        onPressed: onTap,
        onLongPress: onLongPress,
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          elevation: 0,
        ),
        child: Text(
          label,
          style: GoogleFonts.roboto(
            fontSize: 28,
            fontWeight: FontWeight.w400,
            color: fgColor,
          ),
        ),
      ),
    );
  }
}
