import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../core/app_text.dart';
import '../core/app_tokens.dart';
import '../utils/duration_format.dart';
import '../utils/url_launcher_helper.dart';

/// How long an active SOS may go without a location update before guardians are told the
/// sender's phone has gone quiet. The sender writes at least every 2 minutes (heartbeat), so
/// 4 minutes leaves room for one missed write and network delay.
const Duration sosSignalLostAfter = Duration(minutes: 4);

/// When the sender's phone last reported: the last live location write, or the trigger time
/// when tracking never wrote. Null when neither is known yet (e.g. a pending server timestamp).
DateTime? sosLastSignalAt(Map<String, dynamic>? data) {
  if (data == null) return null;
  for (final key in const ['liveUpdatedAt', 'triggeredAt', 'timestamp']) {
    final raw = data[key];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// How long the sender's phone has been silent, or null while it is still reporting
/// (or the alert is no longer active).
Duration? sosSignalSilence(Map<String, dynamic>? data, {DateTime? now}) {
  if (data == null) return null;
  final status = (data['status'] ?? 'active').toString().toLowerCase();
  if (status != 'active') return null;
  final last = sosLastSignalAt(data);
  if (last == null) return null;
  final silence = (now ?? DateTime.now()).difference(last);
  return silence >= sosSignalLostAfter ? silence : null;
}

/// Guardian-side warning shown when an active SOS stops sending location updates
/// (phone switched off, taken, or out of network).
class SignalLostBanner extends StatelessWidget {
  final Duration silence;
  final String? lastAddress;
  final EdgeInsetsGeometry margin;

  const SignalLostBanner({
    super.key,
    required this.silence,
    this.lastAddress,
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final address = lastAddress?.trim() ?? '';
    final hasAddress = address.isNotEmpty &&
        address != 'Live Coordinates' &&
        address != 'Live GPS Coordinates Available';

    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.dangerSurface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.sosRed, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.signal_cellular_connected_no_internet_0_bar_rounded,
                  color: AppColors.sosRed, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Signal lost',
                      style: GoogleFonts.poppins(
                          fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.sosRed),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'No location update for ${formatMinutes(silence.inMinutes)}. '
                      'Their phone may be off or out of network.',
                      style: AppText.caption.copyWith(color: const Color(0xFF8B0000), height: 1.35),
                    ),
                    if (hasAddress) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Last location: $address',
                        style: AppText.caption.copyWith(
                            color: AppColors.textPrimary, fontWeight: FontWeight.w600, height: 1.35),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => UrlLauncherHelper.makePhoneCall('999'),
              icon: const Icon(Icons.local_police_rounded, size: 16, color: Colors.white),
              label: Text(
                'Call 999',
                style: GoogleFonts.poppins(
                    fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.sosRed,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
