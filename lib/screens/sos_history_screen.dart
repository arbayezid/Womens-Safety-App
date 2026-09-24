import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_colors.dart';
import '../services/notification_service.dart';

/// Screen displaying the complete chronological history of all SOS emergency alerts
/// (both received as a trusted guardian and dispatched by the current user).
class SosHistoryScreen extends StatefulWidget {
  const SosHistoryScreen({super.key});

  @override
  State<SosHistoryScreen> createState() => _SosHistoryScreenState();
}

class _SosHistoryScreenState extends State<SosHistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _formatClockTime(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  String _formatFullDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final month = months[dt.month - 1];
    return '$month ${dt.day}, ${dt.year} • ${_formatClockTime(dt)}';
  }

  String _formatTimeAgo(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inSeconds < 45) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[SosHistory] Error launching url: $e');
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
      debugPrint('[SosHistory] Error launching dialer: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final myUid = user?.uid ?? '';
    final myEmail = (user?.email ?? '').toLowerCase().trim();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'SOS Alert History',
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.textPrimary, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: AppColors.surface,
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppColors.sosRed,
              indicatorWeight: 3,
              labelColor: AppColors.sosRed,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
              tabs: const [
                Tab(text: 'All Alerts'),
                Tab(text: 'Received (Guardian)'),
                Tab(text: 'Sent by Me'),
              ],
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('sos_alerts')
            .orderBy('triggeredAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppColors.sosRed));
          }

          if (snapshot.hasError) {
            debugPrint('[SosHistory] Firestore stream error: ${snapshot.error}');
          }

          final allDocs = snapshot.data?.docs ?? [];

          // Map and filter alerts related to this user
          final List<Map<String, dynamic>> userAlerts = [];

          for (final doc in allDocs) {
            final data = doc.data();
            final alertId = doc.id;
            final senderId = (data['senderId'] ?? data['sender_uid'])?.toString() ?? '';
            final senderEmail = (data['senderEmail'] ?? data['sender_email'])?.toString().toLowerCase().trim() ?? '';
            final List<dynamic> recEmails = (data['recipientEmails'] as List<dynamic>?) ?? [];
            final List<dynamic> recUids = (data['recipientUids'] as List<dynamic>?) ?? [];

            final bool isSender = senderId == myUid || (myEmail.isNotEmpty && senderEmail == myEmail);
            final bool isRecipient = recUids.map((u) => u.toString()).contains(myUid) ||
                (myEmail.isNotEmpty && recEmails.map((e) => e.toString().toLowerCase().trim()).contains(myEmail));

            // Include if either sender, recipient, or if open testing broadcast
            if (isSender || isRecipient || (recEmails.isEmpty && recUids.isEmpty)) {
              // Parse timestamp
              final rawTime = data['triggeredAt'] ?? data['timestamp'];
              DateTime dt = DateTime.now();
              if (rawTime is Timestamp) {
                dt = rawTime.toDate();
              }

              userAlerts.add({
                'alertId': alertId,
                'data': data,
                'isSender': isSender,
                'dateTime': dt,
              });
            }
          }

          // Sort descending by timestamp
          userAlerts.sort((a, b) =>
              (b['dateTime'] as DateTime).compareTo(a['dateTime'] as DateTime));

          return TabBarView(
            controller: _tabController,
            children: [
              _buildAlertsList(userAlerts, 'all', myUid),
              _buildAlertsList(userAlerts.where((a) => a['isSender'] == false).toList(), 'received', myUid),
              _buildAlertsList(userAlerts.where((a) => a['isSender'] == true).toList(), 'sent', myUid),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAlertsList(List<Map<String, dynamic>> alerts, String tabType, String myUid) {
    if (alerts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  size: 36,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                tabType == 'sent'
                    ? 'No Dispatched SOS Alerts'
                    : tabType == 'received'
                        ? 'No Incoming Guardian Alerts'
                        : 'No SOS Alerts Recorded',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                tabType == 'sent'
                    ? 'When you activate emergency SOS, your dispatched GPS alerts will appear here.'
                    : 'When contacts in your guardian network trigger emergency SOS, their alerts with live GPS will appear here.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: alerts.length,
      itemBuilder: (context, index) {
        final alert = alerts[index];
        final data = alert['data'] as Map<String, dynamic>;
        final alertId = alert['alertId'] as String;
        final DateTime dt = alert['dateTime'] as DateTime;
        final bool isSender = alert['isSender'] as bool;

        final senderName = data['senderName'] ?? data['sender_name'] ?? 'Emergency Contact';
        final senderEmail = data['senderEmail'] ?? data['sender_email'] ?? '';
        final senderPhone = data['senderPhone'] ?? data['sender_phone'] ?? '';
        final address = data['location']?['address'] ?? data['address'] ?? 'Live GPS Coordinates Available';
        final mapsUrl = data['google_maps_url'] ?? data['location']?['googleMapsUrl'] ?? '';
        final status = (data['status'] ?? 'active').toString().toLowerCase();
        final List<dynamic> dismissedBy = (data['dismissedBy'] as List<dynamic>?) ?? [];
        final bool isAcknowledged = dismissedBy.map((e) => e.toString()).contains(myUid);

        return _buildAlertCard(
          alertId: alertId,
          senderName: senderName.toString(),
          senderEmail: senderEmail.toString(),
          senderPhone: senderPhone.toString(),
          address: address.toString(),
          mapsUrl: mapsUrl.toString(),
          status: status,
          isAcknowledged: isAcknowledged,
          isSender: isSender,
          dateTime: dt,
        );
      },
    );
  }

  Widget _buildAlertCard({
    required String alertId,
    required String senderName,
    required String senderEmail,
    required String senderPhone,
    required String address,
    required String mapsUrl,
    required String status,
    required bool isAcknowledged,
    required bool isSender,
    required DateTime dateTime,
  }) {
    final bool isActive = status == 'active' && !isAcknowledged;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isActive ? AppColors.sosRed.withValues(alpha: 0.35) : Colors.black.withValues(alpha: 0.06),
          width: isActive ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: isActive ? AppColors.sosRed.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Avatar, Name/Role, Status Badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFFFFE5E5) : const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    isActive ? Icons.warning_rounded : Icons.shield_rounded,
                    color: isActive ? AppColors.sosRed : AppColors.textSecondary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              isSender ? 'You (Dispatched SOS)' : senderName,
                              style: GoogleFonts.poppins(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (isSender)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEDE7F6),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'You',
                                style: GoogleFonts.poppins(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (senderEmail.isNotEmpty && !isSender) ...[
                        const SizedBox(height: 1),
                        Text(
                          senderEmail,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.primaryViolet,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                // Status Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFFFFE5E5)
                        : isAcknowledged
                            ? AppColors.successBackground
                            : const Color(0xFFEEF2F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isActive
                        ? '🚨 Active'
                        : isAcknowledged
                            ? '✅ Responded'
                            : 'Resolved',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: isActive
                          ? AppColors.sosRed
                          : isAcknowledged
                              ? AppColors.actionGreen
                              : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Timing row: clock time + relative time
            Row(
              children: [
                const Icon(Icons.access_time_rounded, size: 14, color: AppColors.textSecondary),
                const SizedBox(width: 5),
                Text(
                  _formatFullDate(dateTime),
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _formatTimeAgo(dateTime),
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Location Box
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black.withValues(alpha: 0.04)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on_rounded, size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      address,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Action Buttons
            Row(
              children: [
                if (!isSender && senderPhone.isNotEmpty) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _callSender(senderPhone),
                      icon: const Icon(Icons.call_rounded, size: 15, color: AppColors.actionGreen),
                      label: Text(
                        'Call',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.actionGreen,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.actionGreen),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (mapsUrl.isNotEmpty) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _launchUrl(mapsUrl),
                      icon: const Icon(Icons.map_rounded, size: 15, color: Colors.white),
                      label: Text(
                        'View Map',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
                if (!isSender && isActive) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Acknowledge / Dismiss Alert',
                    icon: const Icon(Icons.check_circle_outline_rounded, color: AppColors.textSecondary, size: 22),
                    onPressed: () async {
                      await NotificationService.instance.dismissAlert(alertId);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Alert acknowledged and dismissed',
                            style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
