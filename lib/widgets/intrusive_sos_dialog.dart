import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_colors.dart';
import '../screens/sos_history_screen.dart';
import '../screens/incident_room_screen.dart';
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

  Future<void> _handleCallSender(String phone, bool isDuress) async {
    if (phone.isEmpty) return;
    if (isDuress) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: AppColors.sosRed, size: 26),
              const SizedBox(width: 8),
              Text(
                'Duress Warning',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ],
          ),
          content: Text(
            'This is a silent duress emergency. The sender may be under direct threat. Calling her phone could alert an aggressor. Do you still want to place this call?',
            style: GoogleFonts.poppins(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.sosRed,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(
                'Call Anyway',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    await _callSender(phone);
  }

  @override
  Widget build(BuildContext context) {
    final alertId = widget.data['alertId']?.toString() ?? '';

    if (alertId.isNotEmpty) {
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('sos_alerts').doc(alertId).snapshots(),
        builder: (context, snapshot) {
          final liveDoc = snapshot.data?.data();
          return _buildDialogContent(liveDoc);
        },
      );
    }

    return _buildDialogContent(null);
  }

  Widget _buildDialogContent(Map<String, dynamic>? liveDoc) {
    final senderName = liveDoc?['senderName']?.toString() ??
        widget.data['senderName']?.toString() ??
        'Emergency Ward';
    final senderEmail = liveDoc?['senderEmail']?.toString() ??
        widget.data['senderEmail']?.toString() ??
        '';
    final senderPhone = liveDoc?['senderPhone']?.toString() ??
        widget.data['senderPhone']?.toString() ??
        '';
    final message = liveDoc?['message']?.toString() ??
        widget.data['message']?.toString() ??
        '';

    final isResolved = liveDoc?['status'] == 'resolved';
    final isDuress = (liveDoc?['isDuress'] as bool?) ??
        (widget.data['isDuress'] as bool? ?? false);
    final isTrackingActive = (liveDoc?['isTrackingActive'] as bool?) ??
        (widget.data['isTrackingActive'] as bool? ?? false);
    final batteryLevel = (liveDoc?['batteryLevel'] as num?)?.toInt() ??
        (widget.data['batteryLevel'] as num?)?.toInt();

    // Determine address and maps link (prioritizing live updates)
    String address = widget.data['address']?.toString() ?? 'Live GPS Coordinates Available';
    String mapsUrl = widget.data['googleMapsUrl']?.toString() ?? '';
    String? liveUpdatedText;

    if (liveDoc != null) {
      final liveLoc = liveDoc['liveLocation'] as Map<String, dynamic>?;
      if (liveLoc != null) {
        if (liveLoc['address'] != null && liveLoc['address'].toString().isNotEmpty) {
          address = liveLoc['address'].toString();
        }
        if (liveLoc['googleMapsUrl'] != null && liveLoc['googleMapsUrl'].toString().isNotEmpty) {
          mapsUrl = liveLoc['googleMapsUrl'].toString();
        } else if (liveLoc['latitude'] != null && liveLoc['longitude'] != null) {
          mapsUrl = 'https://maps.google.com/?q=${liveLoc['latitude']},${liveLoc['longitude']}';
        }
      } else if (liveDoc['address'] != null && liveDoc['address'].toString().isNotEmpty) {
        address = liveDoc['address'].toString();
      }

      final dynamic liveTimestamp = liveDoc['liveUpdatedAt'] ?? liveDoc['lastUpdatedAt'];
      if (liveTimestamp is Timestamp) {
        final diff = DateTime.now().difference(liveTimestamp.toDate());
        if (diff.inSeconds < 60) {
          liveUpdatedText = '${diff.inSeconds}s ago';
        } else {
          liveUpdatedText = '${diff.inMinutes}m ago';
        }
      }
    }

    // Timing calculation
    final rawDate = liveDoc?['alertDate'] ?? widget.data['alertDate'];
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

    final int totalPresses = (liveDoc?['totalPresses'] as int?) ??
        (widget.data['totalPresses'] as int?) ??
        1;

    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Flashing SOS Alert Beacon or Resolved Shield
              ScaleTransition(
                scale: isResolved ? const AlwaysStoppedAnimation(1.0) : _pulseAnim,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: isResolved
                        ? AppColors.safeGreen.withValues(alpha: 0.15)
                        : AppColors.sosRed.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: isResolved ? AppColors.safeGreen : AppColors.sosRed,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: isResolved
                                ? const Color(0x664CD964)
                                : const Color(0x66FF3B30),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: Icon(
                        isResolved ? Icons.shield_rounded : Icons.warning_rounded,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              Text(
                isResolved
                    ? '🛡️ MARKED SAFE'
                    : isDuress
                        ? '🚨 SILENT SOS ALERT'
                        : '🚨 INCOMING SOS ALERT',
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isResolved ? AppColors.safeGreen : AppColors.sosRed,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 6),

              Text(
                isResolved
                    ? '$senderName has marked themselves safe.'
                    : '$senderName has triggered an emergency alarm!',
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

              // Badges row: Timing + Battery + Live indicator
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isResolved ? const Color(0xFFE8F8EE) : const Color(0xFFFFEEEE),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: (isResolved ? AppColors.safeGreen : AppColors.sosRed)
                            .withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.access_time_filled_rounded,
                          size: 13,
                          color: isResolved ? AppColors.safeGreen : AppColors.sosRed,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          timeFormatted,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isResolved ? AppColors.safeGreen : AppColors.sosRed,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (batteryLevel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: batteryLevel <= 10
                            ? const Color(0xFFFFE5E5)
                            : batteryLevel <= 20
                                ? const Color(0xFFFFF3CD)
                                : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            batteryLevel <= 10
                                ? Icons.battery_alert_rounded
                                : Icons.battery_std_rounded,
                            size: 13,
                            color: batteryLevel <= 10
                                ? AppColors.sosRed
                                : batteryLevel <= 20
                                    ? Colors.orange.shade800
                                    : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$batteryLevel%${batteryLevel <= 10 ? ' (Critical)' : ''}',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: batteryLevel <= 10
                                  ? AppColors.sosRed
                                  : batteryLevel <= 20
                                      ? Colors.orange.shade800
                                      : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!isResolved && (isTrackingActive || liveUpdatedText != null))
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEAEA),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.radar_rounded, size: 13, color: AppColors.sosRed),
                          const SizedBox(width: 3),
                          Text(
                            liveUpdatedText != null ? 'Live • $liveUpdatedText' : 'Live Tracking',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.sosRed,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (totalPresses > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
              ),

              // Duress Warning Banner
              if (isDuress && !isResolved) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFC107), width: 1.2),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFF856404), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Silent duress alert — do NOT call. Use location tracking.',
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF856404),
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

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
                          isTrackingActive ? 'Current Live Location:' : 'Reported GPS Location:',
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
                      onPressed: senderPhone.isNotEmpty && !isResolved
                          ? () => _handleCallSender(senderPhone, isDuress)
                          : null,
                      icon: Icon(
                        isDuress ? Icons.phone_locked_rounded : Icons.call_rounded,
                        color: isDuress ? AppColors.actionOrange : AppColors.successForeground,
                        size: 18,
                      ),
                      label: Text(
                        isDuress ? 'Call (Duress)' : 'Call',
                        style: GoogleFonts.poppins(
                          color: isDuress ? AppColors.actionOrange : AppColors.successForeground,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: isDuress ? AppColors.actionOrange : AppColors.successForeground,
                          width: 1.5,
                        ),
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
                        backgroundColor: isResolved ? AppColors.safeGreen : AppColors.sosRed,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Guardian Action Buttons
              if (!isResolved) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      final alertId = widget.data['alertId']?.toString() ?? '';
                      if (alertId.isNotEmpty) {
                        await NotificationService.instance.acknowledgeAlert(alertId);
                      }
                      if (widget.onDismissed != null) {
                        widget.onDismissed!();
                      }
                      if (mounted && Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                      messenger?.showSnackBar(
                        SnackBar(
                          content: Row(
                              children: [
                                const Icon(Icons.check_circle_rounded, color: Colors.white),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'You confirmed responding to $senderName\'s SOS alert!',
                                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            backgroundColor: AppColors.actionGreen,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        );
                      },
                      icon: const Icon(Icons.handshake_rounded, color: Colors.white, size: 20),
                    label: Text(
                      "I'M RESPONDING",
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        letterSpacing: 0.5,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.actionGreen,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // Open Incident Room Button
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: () {
                    final alertId = widget.data['alertId']?.toString() ?? '';
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                    if (alertId.isNotEmpty) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => IncidentRoomScreen(
                            alertId: alertId,
                            initialData: liveDoc ?? widget.data,
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.meeting_room_rounded, size: 18, color: AppColors.sosRed),
                  label: Text(
                    'Open Incident Room',
                    style: GoogleFonts.poppins(
                      color: AppColors.sosRed,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.sosRed, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(height: 4),

              // Dismiss / Close Button
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
                    if (mounted && Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: Text(
                    isResolved ? 'Close Alert' : 'Dismiss (Not Responding)',
                    style: GoogleFonts.poppins(
                      color: isResolved ? AppColors.safeGreen : AppColors.textSecondary,
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
