import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/phone_verification_service.dart';

/// Modal bottom sheet enforcing phone verification before accessing
/// sensitive contact additions or guardian synchronization.
class PhoneVerificationModal extends StatefulWidget {
  const PhoneVerificationModal({super.key});

  /// Static helper ensuring the user's phone is verified before proceeding with an action.
  static Future<bool> ensureVerified(BuildContext context) async {
    final bool isVerified = await PhoneVerificationService.instance.isUserPhoneVerified();
    if (isVerified) return true;

    if (!context.mounted) return false;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const PhoneVerificationModal(),
    );

    return result == true;
  }

  @override
  State<PhoneVerificationModal> createState() => _PhoneVerificationModalState();
}

class _PhoneVerificationModalState extends State<PhoneVerificationModal> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();

  PhoneVerificationStep _step = PhoneVerificationStep.enterPhone;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  String get _fullPhoneNumber {
    String raw = _phoneController.text.trim();
    if (raw.startsWith('+880')) return raw;
    if (raw.startsWith('880')) return '+$raw';
    if (raw.startsWith('0')) raw = raw.substring(1);
    return '+880$raw';
  }

  Future<void> _handleSendOtp() async {
    final raw = _phoneController.text.trim();
    if (raw.length < 9) {
      setState(() => _errorMessage = 'Please enter a valid mobile number.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    await PhoneVerificationService.instance.sendOtp(
      phoneNumber: _fullPhoneNumber,
      onCodeSent: (verificationId) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _step = PhoneVerificationStep.enterOtp;
          });
        }
      },
      onError: (msg) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = msg;
          });
        }
      },
      onAutoVerified: () {
        if (mounted) {
          Navigator.of(context).pop(true);
        }
      },
    );
  }

  Future<void> _handleVerifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      setState(() => _errorMessage = 'Please enter the full 6-digit OTP code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final success = await PhoneVerificationService.instance.verifyOtp(
      smsCode: otp,
      phoneNumber: _fullPhoneNumber,
      onError: (err) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = err;
          });
        }
      },
    );

    if (success && mounted) {
      Navigator.of(context).pop(true);
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag Handle
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.verified_user_rounded, color: AppColors.primary, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Verify Phone Number',
                      style: GoogleFonts.poppins(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      'Required for mutual emergency guardian consent',
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Error Alert Box
          if (_errorMessage != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.sosOuterRing,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.sosRed, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: GoogleFonts.poppins(color: AppColors.sosRed, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (_step == PhoneVerificationStep.enterPhone) ...[
            Text(
              'Enter your personal mobile phone number to receive a verification SMS:',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),

            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                prefixIcon: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.centerLeft,
                  width: 75,
                  child: Text(
                    '+880',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                hintText: '17XXXXXXXX',
                hintStyle: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _handleSendOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : Text(
                        'Send OTP Code',
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ] else ...[
            Text(
              'Enter the 6-digit OTP code sent to $_fullPhoneNumber:',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),

            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 8,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: '000000',
                hintStyle: GoogleFonts.poppins(
                  fontSize: 20,
                  letterSpacing: 6,
                  color: AppColors.textSecondary.withValues(alpha: 0.4),
                ),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _step = PhoneVerificationStep.enterPhone),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      side: const BorderSide(color: AppColors.primary),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      'Change',
                      style: GoogleFonts.poppins(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleVerifyOtp,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          )
                        : Text(
                            'Verify & Save',
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
