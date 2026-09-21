import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/contact_sync_service.dart';

/// Real-time widget rendering incoming mutual consent emergency contact requests
/// directed to the active authenticated user.
class PendingRequestsSection extends StatelessWidget {
  const PendingRequestsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: ContactSyncService.instance.streamIncomingRequests(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }

        final requests = snapshot.data!;

        return Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF9E6), // Soft amber background
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFFFD56B), width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEDBA),
                      borderRadius: BorderRadius.circular(8),
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
                          'Consent Requests (${requests.length})',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          'Users requesting you as an emergency guardian',
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Added ${widget.request['senderName']} to your Emergency Network!',
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
        ScaffoldMessenger.of(context).showSnackBar(
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
        borderRadius: BorderRadius.circular(14),
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
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (senderEmail.isNotEmpty)
                      Text(
                        senderEmail,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          color: AppColors.primaryViolet,
                          fontWeight: FontWeight.w500,
                        ),
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
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _isProcessing ? null : _handleAccept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.successForeground,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                        'Accept & Sync',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
