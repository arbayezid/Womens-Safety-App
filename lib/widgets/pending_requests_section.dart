import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/contact_sync_service.dart';
import '../core/app_tokens.dart';
import '../core/app_text.dart';
import '../widgets/ui/app_snack.dart';
import '../widgets/ui/ui_tone.dart';

/// Real-time widget rendering incoming guardian requests (accepting makes the current user
/// the sender's guardian; it does not make the sender the current user's guardian)
/// directed to the active authenticated user.
class PendingRequestsSection extends StatelessWidget {
  const PendingRequestsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ContactSyncService.instance.incomingRequestsNotifier,
      builder: (context, requests, _) {
        if (requests.isEmpty) {
          return const SizedBox.shrink();
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.tintCream, // Soft amber background
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.amberBright, width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.tintButter,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.mark_email_unread_rounded,
                      color: AppColors.actionOrange,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Guardian requests (${requests.length})',
                          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textPrimary),
                        ),
                        Text(
                          'People who want you as their guardian',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...requests.map((req) => _RequestCard(request: req)),
            ],
          ),
        );
      },
    );
  }
}

class _RequestCard extends StatefulWidget {
  final Map<String, dynamic> request;
  const _RequestCard({required this.request});

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _isProcessing = false;

  Future<void> _handleAccept() async {
    setState(() => _isProcessing = true);
    try {
      await ContactSyncService.instance.acceptRequest(widget.request['docId']);
      if (mounted) {
        AppSnack.showBar(context,
          SnackBar(
            content: SnackContent(
              "You're now ${widget.request['senderName']}'s guardian and will get their SOS alerts.", tone: UiTone.success,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
            backgroundColor: AppColors.successForeground,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[PendingRequest] Error accepting: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleReject() async {
    setState(() => _isProcessing = true);
    try {
      await ContactSyncService.instance.rejectRequest(widget.request['docId']);
      if (mounted) {
        AppSnack.showBar(context,
          SnackBar(
            content: Text(
              'Declined request from ${widget.request['senderName']}',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
            backgroundColor: AppColors.textPrimary,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[PendingRequest] Error rejecting: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final senderName =
        (widget.request['sender_name'] ?? widget.request['senderName'])?.toString() ??
            'Emergency Contact';
    final senderEmail =
        (widget.request['sender_email'] ?? widget.request['senderEmail'])?.toString() ?? '';
    final relationship =
        widget.request['relationship']?.toString() ?? 'Guardian';
    final phone =
        (widget.request['optional_phone'] ?? widget.request['senderPhone'])?.toString() ?? '';
    final initial = senderName.isNotEmpty ? senderName[0].toUpperCase() : 'U';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: AppColors.primarySurface,
                child: Text(
                  initial,
                  style: GoogleFonts.poppins(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      senderName,
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textPrimary),
                    ),
                    if (senderEmail.isNotEmpty)
                      Text(
                        senderEmail,
                        style: AppText.caption.copyWith(color: AppColors.primary),
                      ),
                    Text(
                      '$relationship${phone.isNotEmpty ? " • $phone" : ""}',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _isProcessing ? null : _handleReject,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.red.shade700,
                ),
                child: Text(
                  'Decline',
                  style: AppText.label,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _isProcessing ? null : _handleAccept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.successForeground,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  elevation: 0,
                  visualDensity: VisualDensity.compact,
                ),
                child: _isProcessing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        'Accept',
                        style: AppText.label.copyWith(color: Colors.white),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
