import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/contact_sync_service.dart';

/// Modal dialog for adding emergency contacts via Email-based sync
/// with optional mobile phone number for offline SMS fallback.
class AddContactDialog extends StatefulWidget {
  const AddContactDialog({super.key});

  /// Displays the modal bottom sheet directly without requiring phone verification.
  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddContactDialog(),
    );
  }

  @override
  State<AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<AddContactDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();

  String _selectedRelation = 'Parent';
  bool _isPrimary = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  final List<String> _relations = [
    'Parent',
    'Sibling',
    'Spouse',
    'Friend',
    'Guardian',
    'Colleague',
    'Other'
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final String name = _nameCtrl.text.trim();
    final String email = _emailCtrl.text.trim().toLowerCase();
    final String phone = _phoneCtrl.text.trim();

    try {
      // 1. Search if target email is a registered app user
      final targetUser = await ContactSyncService.instance.searchUserByEmail(email);

      if (targetUser != null) {
        // Auto-fill phone from registered user's profile if left blank
        final resolvedPhone = phone.isNotEmpty
            ? phone
            : (targetUser['phoneNumber'] ?? targetUser['phone'] ?? '').toString().trim();

        // --- CASE A: Registered App User -> Send Connection Request ---
        await ContactSyncService.instance.sendConnectionRequest(
          receiverUid: targetUser['uid'] as String,
          receiverEmail: email,
          receiverName: name,
          relationship: _selectedRelation,
          optionalPhone: resolvedPhone.isNotEmpty ? resolvedPhone : null,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Connection request sent to $email! They will be notified to accept.',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w500, fontSize: 13),
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.actionGreen,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
          Navigator.pop(context, true);
        }
      } else {
        // --- CASE B: Profile not in Firestore yet -> Dispatch Email-Based Guardian Request! ---
        await ContactSyncService.instance.sendConnectionRequest(
          receiverUid: null,
          receiverEmail: email,
          receiverName: name,
          relationship: _selectedRelation,
          optionalPhone: phone.isNotEmpty ? phone : null,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.mark_email_read_rounded, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Guardian request sent to $email! Once they open the app and accept, live sync will activate.',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w500, fontSize: 13),
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.actionGreen,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      final errorStr = e.toString().replaceAll('Exception: ', '');
      if (errorStr.contains('cannot add your own') || errorStr.contains('already in your verified')) {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _errorMessage = errorStr;
          });
        }
        return;
      }

      // For any network/Firestore unavailable condition, gracefully save offline so safety is never blocked
      try {
        await ContactSyncService.instance.saveOfflineContact(
          name: name,
          email: email,
          relationship: _selectedRelation,
          optionalPhone: phone.isNotEmpty ? phone : null,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.cloud_off_rounded, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Contact saved! (Offline SMS alerts active; sync will retry when online).',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w500, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.primaryViolet,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
          Navigator.pop(context, true);
          return;
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = errorStr;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        top: 14,
        left: 24,
        right: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Grab Handle
              Center(
                child: Container(
                  width: 44,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primaryViolet.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_add_alt_1_rounded,
                        color: AppColors.primaryViolet, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Emergency Contact',
                          style: GoogleFonts.poppins(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          'Sync via email & set offline SMS backup',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Error banner if any
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEEEE),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFC0C0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: GoogleFonts.poppins(
                            color: Colors.red.shade900,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 1. Full Name Field (Required)
              Text(
                'Full Name *',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'e.g. Fatima Rahman',
                  prefixIcon: const Icon(Icons.person_outline_rounded, color: AppColors.primaryViolet),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter contact name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),

              // 2. Email Field (REQUIRED for app sync)
              Row(
                children: [
                  Text(
                    'Email Address *',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primaryViolet.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'App Sync',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryViolet,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'e.g. fatima@example.com',
                  prefixIcon: const Icon(Icons.email_outlined, color: AppColors.primaryViolet),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Email is required for in-app sync';
                  }
                  final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                  if (!emailRegex.hasMatch(val.trim())) {
                    return 'Please enter a valid email address';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),

              // 3. Mobile Number Field (OPTIONAL for offline SMS)
              Row(
                children: [
                  Text(
                    'Mobile Number (Optional)',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.actionGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Offline SMS Fallback',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.actionGreen,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: 'e.g. +88017XXXXXXXX',
                  helperText: 'No OTP verification required. Used for direct offline SMS.',
                  helperStyle: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                  prefixIcon: const Icon(Icons.phone_outlined, color: AppColors.actionGreen),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 4. Relationship Dropdown
              Text(
                'Relationship *',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _selectedRelation,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.people_outline_rounded, color: AppColors.primary),
                ),
                items: _relations.map((rel) {
                  return DropdownMenuItem<String>(
                    value: rel,
                    child: Text(rel, style: GoogleFonts.poppins(fontSize: 14)),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedRelation = val);
                },
              ),
              const SizedBox(height: 14),

              // 5. Priority SOS toggle
              SwitchListTile(
                value: _isPrimary,
                contentPadding: EdgeInsets.zero,
                activeThumbColor: AppColors.primary,
                title: Text(
                  'Mark as Primary Emergency Contact',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  'Receives highest priority in the SOS broadcast list',
                  style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                ),
                onChanged: (val) => setState(() => _isPrimary = val),
              ),
              const SizedBox(height: 20),

              // Submit Button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _handleSubmit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryViolet,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 2,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'Save & Send Request',
                              style: GoogleFonts.poppins(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
