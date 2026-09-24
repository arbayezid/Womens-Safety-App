import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_colors.dart';
import '../screens/sos_history_screen.dart';
import '../services/notification_service.dart';

/// Fullscreen-style intrusive dialog displayed when an incoming high-priority
/// SOS Alert push notification is received while the app is active.
class IntrusiveSosDialog extends StatefulWidget {
  final Map<String, dynamic> data;
  final VoidCallback? onDismissed;

  const IntrusiveSosDialog({
    super.key,
    required this.data,
    this.onDismissed,
  });

  @override
  State<IntrusiveSosDialog> createState() => _IntrusiveSosDialogState();
}

class _IntrusiveSosDialogState extends State<IntrusiveSosDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _openGoogleMaps(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[SOS Dialog] Failed to launch maps: $e');
    }
  }

  Future<void> _callSender(String phone) async {
    if (phone.isEmpty) return;
    final clean = phone.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[SOS Dialog] Failed to launch phone dialer: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final senderName = widget.data['senderName']?.toString() ?? 'Emergency Ward';
    final senderEmail = widget.data['senderEmail']?.toString() ?? '';
    final senderPhone = widget.data['senderPhone']?.toString() ?? '';
    final address = widget.data['address']?.toString() ?? 'Live GPS Coordinates Available';
    final mapsUrl = widget.data['googleMapsUrl']?.toString() ?? '';
    final message = widget.data['message']?.toString() ?? '';

    // Calculate formatted timing & relative elapsed time
    final rawDate = widget.data['alertDate'];
    DateTime? alertDate;
    if (rawDate is DateTime) {
      alertDate = rawDate;
    } else if (rawDate is String) {
      alertDate = DateTime.tryParse(rawDate);
    } else if (widget.data['triggeredAt'] != null) {
      alertDate = DateTime.tryParse(widget.data['triggeredAt'].toString());
    }

    String timeFormatted = 'Just now';
    if (alertDate != null) {
      final hour = alertDate.hour == 0 ? 12 : (alertDate.hour > 12 ? alertDate.hour - 12 : alertDate.hour);
      final minute = alertDate.minute.toString().padLeft(2, '0');
      final period = alertDate.hour >= 12 ? 'PM' : 'AM';
      final diff = DateTime.now().difference(alertDate);
      final relative = diff.inMinutes < 1 ? 'Just now' : '${diff.inMinutes}m ago';
      timeFormatted = '$hour:$minute $period • $relative';
    }

    final int totalPresses = (widget.data['totalPresses'] as int?) ?? 1;

    return PopScope(
      canPop: false, // Disallow dismissing via back button without explicit action
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Flashing SOS Alert Beacon
              ScaleTransition(
                scale: _pulseAnim,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.sosRed.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: const BoxDecoration(
                        color: AppColors.sosRed,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x66FF3B30),
                            blurRadius: 16,
                            offset: Offset(0, 4),
                          )
                        ],
                      ),
                      child: const Icon(Icons.warning_rounded, color: Colors.white, size: 36),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              Text(
                '🚨 INCOMING SOS ALERT',
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.sosRed,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 6),

              Text(
                '$senderName has triggered an emergency alarm!',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (senderEmail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  senderEmail,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: AppColors.primaryViolet,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const SizedBox(height: 8),

              // Timing Badge (Clock Time + Relative Elapsed + Multi-press Indicator)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEEEE),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.sosRed.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.access_time_filled_rounded, size: 13, color: AppColors.sosRed),
                    const SizedBox(width: 5),
                    Text(
                      timeFormatted,
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.sosRed,
                      ),
                    ),
                    if (totalPresses > 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.sosRed,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Update #$totalPresses',
                          style: GoogleFonts.poppins(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              if (message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '"$message"',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontStyle: FontStyle.italic,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // Location Information Box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.location_on_rounded, color: AppColors.primary, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'Reported GPS Location:',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      address,
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Action Buttons: Call & View Map
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: senderPhone.isNotEmpty ? () => _callSender(senderPhone) : null,
                      icon: const Icon(Icons.call_rounded, color: AppColors.successForeground, size: 18),
                      label: Text(
                        'Call',
                        style: GoogleFonts.poppins(
                          color: AppColors.successForeground,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.successForeground, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: mapsUrl.isNotEmpty ? () => _openGoogleMaps(mapsUrl) : null,
                      icon: const Icon(Icons.map_rounded, color: Colors.white, size: 18),
                      label: Text(
                        'View Map',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.sosRed,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Dismiss / Responding Button
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () async {
                    final alertId = widget.data['alertId']?.toString() ?? '';
                    if (alertId.isNotEmpty) {
                      await NotificationService.instance.dismissAlert(alertId);
                    }
                    if (widget.onDismissed != null) {
                      widget.onDismissed!();
                    }
                    if (context.mounted && Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: Text(
                    'I am Responding / Dismiss',
                    style: GoogleFonts.poppins(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),

              // View Alert History Link
              GestureDetector(
                onTap: () {
                  final alertId = widget.data['alertId']?.toString() ?? '';
                  if (alertId.isNotEmpty) {
                    NotificationService.instance.dismissAlert(alertId);
                  }
                  if (widget.onDismissed != null) {
                    widget.onDismissed!();
                  }
                  if (context.mounted && Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                  if (context.mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SosHistoryScreen()),
                    );
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.history_rounded, size: 14, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(
                        'View Alert History',
                        style: GoogleFonts.poppins(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          decoration: TextDecoration.underline,
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
