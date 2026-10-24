import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../models/incident_event_model.dart';
import '../models/safe_zone_model.dart';
import '../services/contact_service.dart';
import '../services/emergency_service.dart';
import '../services/incident_service.dart';
import '../services/notification_service.dart';
import '../services/pin_security_service.dart';
import '../services/siren_service.dart';
import '../widgets/pin_input_dialog.dart';

/// Comprehensive Emergency Incident Room screen coordinating real-time SOS tracking,
/// breadcrumb history, nearby physical safe zones, multi-guardian acknowledgment state,
/// automated escalation progression, and audit timeline for both senders and guardians.
class IncidentRoomScreen extends StatefulWidget {
  final String alertId;
  final Map<String, dynamic>? initialData;

  const IncidentRoomScreen({
    super.key,
    required this.alertId,
    this.initialData,
  });

  @override
  State<IncidentRoomScreen> createState() => _IncidentRoomScreenState();
}

class _IncidentRoomScreenState extends State<IncidentRoomScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  late AnimationController _pulseController;
  late Animation<double> _pulseScale;

  Timer? _tickerTimer;
  DateTime _screenLoadedAt = DateTime.now();

  List<ContactModel> _cachedContacts = [];
  bool _isRespondingLoading = false;
  bool _isResolving = false;

  @override
  void initState() {
    super.initState();
    // Silence any active alarm siren once inside the incident room
    SirenService.instance.stopSiren();
    _screenLoadedAt = DateTime.now();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Refresh every second for live elapsed and countdown timers
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    _loadContacts();
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final list = await ContactService.instance.getContacts();
      if (mounted) {
        setState(() => _cachedContacts = list);
      }
    } catch (_) {}
  }

  String _formatElapsed(DateTime fromTime, {DateTime? toTime}) {
    final end = toTime ?? DateTime.now();
    final diff = end.difference(fromTime);
    if (diff.isNegative) return '0s';

    final hours = diff.inHours;
    final minutes = diff.inMinutes % 60;
    final seconds = diff.inSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  Future<void> _launchExternalUrl(String url) async {
    if (url.isEmpty) return;
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[IncidentRoom] Error launching URL $url: $e');
    }
  }

  Future<void> _callPhone(String phone, {bool isDuress = false}) async {
    if (phone.isEmpty) return;

    if (isDuress) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: AppColors.sosRed, size: 28),
              const SizedBox(width: 8),
              Text(
                'Duress Alert Active',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ],
          ),
          content: Text(
            'The sender entered a Duress PIN indicating they are under threat. Calling their phone may alert attackers and put them in immediate danger.\n\nAre you sure you want to call?',
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
              child: Text('Call Anyway', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

      if (proceed != true) return;
    }

    final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
    await _launchExternalUrl('tel:$cleanPhone');
  }

  Future<void> _handleGuardianAcknowledge(String alertId) async {
    setState(() => _isRespondingLoading = true);
    HapticFeedback.heavyImpact();

    try {
      await NotificationService.instance.acknowledgeAlert(alertId);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '✅ You confirmed responding! Escalation timers have been paused.',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.actionGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ),
      );
    } finally {
      if (mounted) setState(() => _isRespondingLoading = false);
    }
  }

  Future<void> _handleSenderMarkSafe(String alertId) async {
    final isPinEnabled = await PinSecurityService.instance.isPinEnabled();
    final isRealConfigured = await PinSecurityService.instance.isRealPinConfigured();

    if (isPinEnabled && isRealConfigured) {
      if (!mounted) return;
      final verified = await PinInputDialog.show(
        context,
        mode: PinDialogMode.verify,
        customTitle: 'Confirm Safety',
        customSubtitle: 'Enter Security PIN to verify you are safe and resolve this alert',
      );
      if (verified != true || !mounted) return;
    } else {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.shield_rounded, color: AppColors.safeGreen, size: 28),
              const SizedBox(width: 10),
              Text(
                "Confirm I'm Safe",
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 17),
              ),
            ],
          ),
          content: Text(
            'Are you sure you are safe? This will resolve the alert, stop live GPS tracking, and notify all emergency contacts.',
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
                backgroundColor: AppColors.safeGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('I Am Safe', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;
    }

    setState(() => _isResolving = true);
    HapticFeedback.heavyImpact();

    try {
      await EmergencyService.instance.markSafe(alertId: alertId);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '✅ Alert resolved. Your guardians have been notified that you are safe.',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.safeGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ),
      );
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('sos_alerts').doc(widget.alertId).snapshots(),
      builder: (context, snapshot) {
        final docData = snapshot.data?.data() ?? widget.initialData ?? {};
        final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
        final currentEmail = (FirebaseAuth.instance.currentUser?.email ?? '').toLowerCase().trim();

        final senderId = (docData['senderId'] ?? docData['sender_uid'])?.toString() ?? '';
        final senderEmail = (docData['senderEmail'] ?? docData['sender_email'])?.toString().toLowerCase().trim() ?? '';
        final bool isSender = currentUid.isNotEmpty && senderId == currentUid ||
            (currentEmail.isNotEmpty && senderEmail == currentEmail);

        final status = (docData['status'] ?? 'active').toString().toLowerCase();
        final bool isActive = status == 'active';
        final bool isDuress = (docData['isDuress'] as bool?) ?? false;

        // Timing
        DateTime triggerTime = _screenLoadedAt;
        final rawTrigger = docData['triggeredAt'] ?? docData['timestamp'];
        if (rawTrigger is Timestamp) {
          triggerTime = rawTrigger.toDate();
        } else if (rawTrigger is String) {
          triggerTime = DateTime.tryParse(rawTrigger) ?? _screenLoadedAt;
        }

        DateTime? resolvedTime;
        final rawResolved = docData['resolvedAt'];
        if (rawResolved is Timestamp) {
          resolvedTime = rawResolved.toDate();
        }

        // Coordinates & Breadcrumb trail
        final liveLoc = docData['liveLocation'] as Map<String, dynamic>? ?? docData['location'] as Map<String, dynamic>?;
        final double lat = (liveLoc?['latitude'] as num?)?.toDouble() ??
            (docData['latitude'] as num?)?.toDouble() ??
            23.8103; // Dhaka fallback
        final double lng = (liveLoc?['longitude'] as num?)?.toDouble() ??
            (docData['longitude'] as num?)?.toDouble() ??
            90.4125;
        final currentLatLng = LatLng(lat, lng);

        final List<LatLng> trailPoints = [];
        final rawTrail = docData['recentTrail'];
        if (rawTrail is List) {
          for (final item in rawTrail) {
            if (item is Map) {
              final tLat = (item['latitude'] ?? item['lat'] as num?)?.toDouble();
              final tLng = (item['longitude'] ?? item['lng'] as num?)?.toDouble();
              if (tLat != null && tLng != null) {
                trailPoints.add(LatLng(tLat, tLng));
              }
            }
          }
        }
        if (trailPoints.isEmpty || trailPoints.last != currentLatLng) {
          trailPoints.add(currentLatLng);
        }
        final displayTrail = trailPoints.length > 50
            ? trailPoints.sublist(trailPoints.length - 50)
            : trailPoints;

        // Nearest 3 safe zones
        final nearestZones = IncidentService.instance.getNearestSafeZones(lat, lng, count: 3);

        // Guardians & Acknowledgment state
        final List<dynamic> rawRecipientEmails = (docData['recipientEmails'] as List<dynamic>?) ?? [];
        final List<dynamic> rawRecipientUids = (docData['recipientUids'] as List<dynamic>?) ?? [];
        final List<dynamic> rawDismissedBy = (docData['dismissedBy'] as List<dynamic>?) ?? [];
        final List<dynamic> rawAcknowledgedBy = (docData['acknowledgedBy'] as List<dynamic>?) ?? [];
        final Map<String, dynamic> rawAcknowledgedAt = (docData['acknowledgedAt'] as Map<String, dynamic>?) ?? {};

        final bool isCurrentGuardianAcknowledged = rawAcknowledgedBy.map((e) => e.toString()).contains(currentUid);
        final bool isAnyGuardianAcknowledged = rawAcknowledgedBy.isNotEmpty;

        // Escalation Level
        final int escalationLevel = (docData['escalationLevel'] as num?)?.toInt() ?? 0;

        // Audio Evidence URL
        final String audioUrl = (docData['audioUrl'] ?? docData['audio_url'] ?? docData['recordingUrl'])?.toString() ?? '';
        final bool hasAudio = (docData['hasAudio'] as bool?) ?? audioUrl.isNotEmpty;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0.5,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.textPrimary, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Emergency Incident Room',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  isActive ? 'Live Incident Command' : 'Archived Incident Record',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isActive ? AppColors.sosRed : AppColors.safeGreen,
                  ),
                ),
              ],
            ),
            actions: [
              Container(
                margin: const EdgeInsets.only(right: 14, top: 12, bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isActive ? const Color(0xFFFFE5E5) : const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isActive ? AppColors.sosRed.withValues(alpha: 0.4) : AppColors.safeGreen.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isActive)
                      ScaleTransition(
                        scale: _pulseScale,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.sosRed,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    else
                      const Icon(Icons.check_circle_rounded, color: AppColors.safeGreen, size: 12),
                    const SizedBox(width: 6),
                    Text(
                      isActive ? 'ACTIVE' : 'RESOLVED',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: isActive ? AppColors.sosRed : AppColors.safeGreen,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    // 1. Silent Duress Banner (Guardian view only)
                    if (!isSender && isDuress)
                      _buildDuressWarningBanner(),

                    // 2. Incident Status Header Card
                    _buildStatusHeaderCard(
                      docData: docData,
                      isActive: isActive,
                      isSender: isSender,
                      triggerTime: triggerTime,
                      resolvedTime: resolvedTime,
                    ),

                    const SizedBox(height: 16),

                    // 3. Escalation Progress Bar (Stepper)
                    _buildEscalationStepperCard(
                      escalationLevel: escalationLevel,
                      isActive: isActive,
                      isAnyGuardianAcknowledged: isAnyGuardianAcknowledged,
                      triggerTime: triggerTime,
                    ),

                    const SizedBox(height: 16),

                    // 4. Interactive Map with Breadcrumbs & Nearest Safe Zones
                    _buildInteractiveMapSection(
                      currentLatLng: currentLatLng,
                      trailPoints: displayTrail,
                      nearestZones: nearestZones,
                      isActive: isActive,
                    ),

                    const SizedBox(height: 16),

                    // 5. Guardian Status Panel
                    _buildGuardianStatusPanel(
                      recipientUids: rawRecipientUids.map((e) => e.toString()).toList(),
                      recipientEmails: rawRecipientEmails.map((e) => e.toString()).toList(),
                      dismissedBy: rawDismissedBy.map((e) => e.toString()).toList(),
                      acknowledgedBy: rawAcknowledgedBy.map((e) => e.toString()).toList(),
                      acknowledgedAt: rawAcknowledgedAt,
                    ),

                    if (hasAudio) ...[
                      const SizedBox(height: 16),
                      // 6. Audio Evidence Player
                      _buildAudioEvidenceCard(audioUrl: audioUrl),
                    ],

                    const SizedBox(height: 16),

                    // 7. Incident Timeline Stream
                    _buildTimelineSection(
                      alertId: widget.alertId,
                      alertData: docData,
                    ),
                  ],
                ),
              ),

              // 8. Bottom Action Command Bar
              _buildBottomActionBar(
                alertId: widget.alertId,
                docData: docData,
                isSender: isSender,
                isActive: isActive,
                isCurrentGuardianAcknowledged: isCurrentGuardianAcknowledged,
                isDuress: isDuress,
                currentLatLng: currentLatLng,
              ),
            ],
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────
  // UI WIDGET COMPONENTS
  // ─────────────────────────────────────────────────────────────

  Widget _buildDuressWarningBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.sosRed, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.sosRed.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(
              color: AppColors.sosRed,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '⚠️ SILENT DURESS ALERT ACTIVE',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.sosRed,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Sender entered a discreet Duress PIN under coercion. DO NOT call them or send noisy messages that could alert an aggressor. Alert 999 or proceed silently.',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    color: const Color(0xFF8B0000),
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusHeaderCard({
    required Map<String, dynamic> docData,
    required bool isActive,
    required bool isSender,
    required DateTime triggerTime,
    DateTime? resolvedTime,
  }) {
    final senderName = docData['senderName'] ?? docData['sender_name'] ?? 'User in Distress';
    final source = docData['source']?.toString() ?? 'SOS Button';
    final batteryLevel = (docData['batteryLevel'] as num?)?.toInt();
    final address = docData['liveLocation']?['address'] ??
        docData['location']?['address'] ??
        docData['address'] ??
        'Live GPS Tracking Active';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? AppColors.sosRed.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: isActive ? AppColors.sosRed.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bolt_rounded, size: 14, color: AppColors.actionBlue),
                    const SizedBox(width: 4),
                    Text(
                      source,
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.actionBlue,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (batteryLevel != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: batteryLevel <= 10 ? const Color(0xFFFFE5E5) : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        batteryLevel <= 10 ? Icons.battery_alert_rounded : Icons.battery_std_rounded,
                        size: 13,
                        color: batteryLevel <= 10 ? AppColors.sosRed : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$batteryLevel%${batteryLevel <= 10 ? ' (Critical)' : ''}',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: batteryLevel <= 10 ? AppColors.sosRed : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isSender ? 'You triggered an Emergency SOS' : '$senderName is in an Emergency',
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.pin_drop_rounded, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  address.toString(),
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            children: [
              Icon(
                isActive ? Icons.timer_outlined : Icons.check_circle_outline_rounded,
                size: 15,
                color: isActive ? AppColors.sosRed : AppColors.safeGreen,
              ),
              const SizedBox(width: 6),
              Text(
                isActive
                    ? 'Active for: ${_formatElapsed(triggerTime)}'
                    : 'Resolved after: ${_formatElapsed(triggerTime, toTime: resolvedTime)}',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isActive ? AppColors.sosRed : AppColors.safeGreen,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEscalationStepperCard({
    required int escalationLevel,
    required bool isActive,
    required bool isAnyGuardianAcknowledged,
    required DateTime triggerTime,
  }) {
    final elapsedSeconds = DateTime.now().difference(triggerTime).inSeconds;

    String countdownText = '';
    if (isActive) {
      if (isAnyGuardianAcknowledged) {
        countdownText = 'PAUSED • Guardian is responding';
      } else if (escalationLevel == 0) {
        final remaining = 180 - elapsedSeconds;
        countdownText = remaining > 0 ? 'Next stage in ${remaining ~/ 60}m ${remaining % 60}s' : 'Escalating to Stage 1...';
      } else if (escalationLevel == 1) {
        final remaining = 480 - elapsedSeconds;
        countdownText = remaining > 0 ? 'Next stage in ${remaining ~/ 60}m ${remaining % 60}s' : 'Escalating to Stage 2...';
      } else {
        countdownText = 'Stage 2 Maximum Escalation Active';
      }
    } else {
      countdownText = 'Escalation sequence complete (Resolved)';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Escalation Progression',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isAnyGuardianAcknowledged
                      ? const Color(0xFFE8F5E9)
                      : (isActive ? const Color(0xFFFFF3CD) : const Color(0xFFF1F5F9)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  countdownText,
                  style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: isAnyGuardianAcknowledged
                        ? AppColors.actionGreen
                        : (isActive ? Colors.orange.shade800 : AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 3-step Stepper Row
          Row(
            children: [
              _buildStepNode(
                stepIndex: 0,
                label: 'Direct',
                sublabel: 'Guardians',
                isActive: true,
                isCompleted: escalationLevel > 0 || isAnyGuardianAcknowledged || !isActive,
              ),
              _buildStepConnector(isCompleted: escalationLevel >= 1 || isAnyGuardianAcknowledged),
              _buildStepNode(
                stepIndex: 1,
                label: 'Stage 1',
                sublabel: 'Backups',
                isActive: escalationLevel >= 1,
                isCompleted: escalationLevel > 1,
              ),
              _buildStepConnector(isCompleted: escalationLevel >= 2),
              _buildStepNode(
                stepIndex: 2,
                label: 'Stage 2',
                sublabel: '999 Services',
                isActive: escalationLevel >= 2,
                isCompleted: escalationLevel >= 2,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepNode({
    required int stepIndex,
    required String label,
    required String sublabel,
    required bool isActive,
    required bool isCompleted,
  }) {
    final color = isCompleted
        ? AppColors.safeGreen
        : (isActive ? AppColors.actionOrange : AppColors.textSecondary.withValues(alpha: 0.4));

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Icon(
              isCompleted ? Icons.check_rounded : (isActive ? Icons.bolt_rounded : Icons.circle_outlined),
              size: 16,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
        Text(
          sublabel,
          style: GoogleFonts.poppins(
            fontSize: 9.5,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildStepConnector({required bool isCompleted}) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 24, left: 4, right: 4),
        color: isCompleted ? AppColors.safeGreen : Colors.black.withValues(alpha: 0.1),
      ),
    );
  }

  Widget _buildInteractiveMapSection({
    required LatLng currentLatLng,
    required List<LatLng> trailPoints,
    required List<SafeZone> nearestZones,
    required bool isActive,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                const Icon(Icons.explore_rounded, color: AppColors.primary, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Live Incident Radar',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${trailPoints.length} trail pts',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.my_location_rounded, size: 18, color: AppColors.primary),
                  tooltip: 'Center on sender',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    _mapController.move(currentLatLng, 15.5);
                  },
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 260,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: currentLatLng,
                  initialZoom: 15.0,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.smart_safety.app',
                  ),
                  // Trail Polyline
                  if (trailPoints.length >= 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: trailPoints,
                          strokeWidth: 4.0,
                          color: AppColors.sosRed.withValues(alpha: 0.75),
                        ),
                      ],
                    ),
                  // Safe Zone and Sender Markers
                  MarkerLayer(
                    markers: [
                      // Safe Zones
                      ...nearestZones.map((zone) {
                        return Marker(
                          point: zone.latLng,
                          width: 40,
                          height: 40,
                          child: GestureDetector(
                            onTap: () => _launchExternalUrl(zone.navigationUrl),
                            child: Container(
                              decoration: BoxDecoration(
                                color: zone.bgColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: zone.iconColor, width: 1.5),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: Icon(zone.icon, color: zone.iconColor, size: 20),
                            ),
                          ),
                        );
                      }),
                      // Current Sender Marker
                      Marker(
                        point: currentLatLng,
                        width: 50,
                        height: 50,
                        child: Center(
                          child: ScaleTransition(
                            scale: isActive ? _pulseScale : const AlwaysStoppedAnimation(1.0),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: isActive ? AppColors.sosRed : AppColors.safeGreen,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    color: (isActive ? AppColors.sosRed : AppColors.safeGreen).withValues(alpha: 0.4),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.person_pin_circle_rounded, color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 3 Nearest Safe Zones Quick Action Cards
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nearest Physical Safe Zones:',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                ...nearestZones.map((zone) {
                  final dist = zone.calculateDistanceKm(currentLatLng.latitude, currentLatLng.longitude);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
                    ),
                    child: Row(
                      children: [
                        Icon(zone.icon, size: 16, color: zone.iconColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            zone.name,
                            style: GoogleFonts.poppins(fontSize: 11.5, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          SafeZone.formatDistance(dist),
                          style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _launchExternalUrl(zone.navigationUrl),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.navigation_rounded, size: 10, color: Colors.white),
                                const SizedBox(width: 4),
                                Text(
                                  'Navigate',
                                  style: GoogleFonts.poppins(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuardianStatusPanel({
    required List<String> recipientUids,
    required List<String> recipientEmails,
    required List<String> dismissedBy,
    required List<String> acknowledgedBy,
    required Map<String, dynamic> acknowledgedAt,
  }) {
    // Collect all contacts
    final Set<String> allIdentities = {...recipientEmails, ...recipientUids};

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Guardians Dispatched (${allIdentities.length})',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (allIdentities.isEmpty)
            Text(
              'No guardian contacts attached to this alert.',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
            )
          else
            ...allIdentities.map((identity) {
              final isUid = !identity.contains('@');
              ContactModel? match;
              try {
                match = _cachedContacts.firstWhere(
                  (c) => isUid ? (c.contactUid == identity) : (c.email.toLowerCase() == identity.toLowerCase()),
                );
              } catch (_) {}

              final displayName = match?.name ?? (isUid ? 'Guardian ($identity)' : identity);
              final bool isBackup = match?.isBackup ?? false;
              final bool isAcknowledged = isUid && acknowledgedBy.contains(identity);
              final bool isSeen = isUid && dismissedBy.contains(identity);

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: isAcknowledged
                          ? const Color(0xFFE8F5E9)
                          : const Color(0xFFF1F5F9),
                      child: Icon(
                        isAcknowledged
                            ? Icons.handshake_rounded
                            : (isSeen ? Icons.visibility_rounded : Icons.person_rounded),
                        size: 15,
                        color: isAcknowledged
                            ? AppColors.actionGreen
                            : (isSeen ? AppColors.actionBlue : AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        displayName,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isBackup) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '🛡️ Backup',
                          style: GoogleFonts.poppins(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.deepOrange,
                          ),
                        ),
                      ),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isAcknowledged
                            ? const Color(0xFFE8F5E9)
                            : (isSeen ? const Color(0xFFEBF5FF) : const Color(0xFFF1F5F9)),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isAcknowledged ? 'Responding' : (isSeen ? 'Seen' : 'Notified'),
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: isAcknowledged
                              ? AppColors.actionGreen
                              : (isSeen ? AppColors.actionBlue : AppColors.textSecondary),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildAudioEvidenceCard({required String audioUrl}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Colors.orange,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Emergency Audio Evidence',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  'Audio recording captured at emergency dispatch',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _launchExternalUrl(audioUrl),
            icon: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
            label: Text(
              'Play',
              style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineSection({
    required String alertId,
    required Map<String, dynamic> alertData,
  }) {
    return StreamBuilder<List<IncidentEvent>>(
      stream: IncidentService.instance.streamEvents(alertId),
      builder: (context, snapshot) {
        final subcollectionEvents = snapshot.data ?? [];
        final unifiedTimeline = IncidentService.instance.synthesizeTimeline(
          alertId: alertId,
          alertData: alertData,
          subcollectionEvents: subcollectionEvents,
        );

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.history_rounded, color: AppColors.primary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Incident Timeline (${unifiedTimeline.length})',
                    style: GoogleFonts.poppins(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (unifiedTimeline.isEmpty)
                Text(
                  'No timeline events logged yet.',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                )
              else
                ...List.generate(unifiedTimeline.length, (index) {
                  final evt = unifiedTimeline[index];
                  final isLast = index == unifiedTimeline.length - 1;

                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Vertical line and node icon
                        Column(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: evt.color.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                                border: Border.all(color: evt.color, width: 2),
                              ),
                              child: Icon(evt.icon, size: 14, color: evt.color),
                            ),
                            if (!isLast)
                              Expanded(
                                child: Container(
                                  width: 2,
                                  color: Colors.black.withValues(alpha: 0.08),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        // Event Text & Time
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        evt.title,
                                        style: GoogleFonts.poppins(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _formatClockTime(evt.timestamp),
                                      style: GoogleFonts.poppins(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                                if (evt.description.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    evt.description,
                                    style: GoogleFonts.poppins(
                                      fontSize: 11.5,
                                      color: AppColors.textSecondary,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  String _formatClockTime(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$min $period';
  }

  Widget _buildBottomActionBar({
    required String alertId,
    required Map<String, dynamic> docData,
    required bool isSender,
    required bool isActive,
    required bool isCurrentGuardianAcknowledged,
    required bool isDuress,
    required LatLng currentLatLng,
  }) {
    final senderPhone = docData['senderPhone'] ?? docData['sender_phone'] ?? '';
    final mapsUrl = 'https://www.google.com/maps/dir/?api=1&destination=${currentLatLng.latitude},${currentLatLng.longitude}&travelmode=driving';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: Colors.black.withValues(alpha: 0.08))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: isSender
            ? Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: (!isActive || _isResolving) ? null : () => _handleSenderMarkSafe(alertId),
                      icon: _isResolving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                      label: Text(
                        isActive ? "I'M SAFE NOW" : 'ALERT RESOLVED',
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.3,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.safeGreen,
                        disabledBackgroundColor: AppColors.textSecondary.withValues(alpha: 0.3),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: ElevatedButton.icon(
                      onPressed: () => _callPhone('999'),
                      icon: const Icon(Icons.call_rounded, color: Colors.white, size: 18),
                      label: Text(
                        'CALL 999',
                        style: GoogleFonts.poppins(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.sosRed,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isActive && !isCurrentGuardianAcknowledged) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: _isRespondingLoading ? null : () => _handleGuardianAcknowledge(alertId),
                        icon: _isRespondingLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.handshake_rounded, color: Colors.white, size: 20),
                        label: Text(
                          "I'M RESPONDING",
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
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
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      if (senderPhone.toString().isNotEmpty) ...[
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _callPhone(senderPhone.toString(), isDuress: isDuress),
                            icon: Icon(
                              Icons.call_rounded,
                              size: 16,
                              color: isDuress ? AppColors.sosRed : AppColors.actionGreen,
                            ),
                            label: Text(
                              isDuress ? 'Call (Duress)' : 'Call Sender',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isDuress ? AppColors.sosRed : AppColors.actionGreen,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: isDuress ? AppColors.sosRed : AppColors.actionGreen),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _launchExternalUrl(mapsUrl),
                          icon: const Icon(Icons.directions_rounded, size: 16, color: Colors.white),
                          label: Text(
                            'Get Directions',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
