import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/app_colors.dart';
import '../models/journey_model.dart';
import '../screens/journey_tracking_screen.dart';
import '../utils/duration_format.dart';
import '../utils/url_launcher_helper.dart';

/// Home-screen card for a guardian: a contact they protect is on a Safe Journey (or in
/// Followed Mode) right now. It stays until the journey ends, so the live map is always one tap
/// away, even after the "started a Safe Journey" notification was dismissed.
class IncomingJourneyCard extends StatelessWidget {
  final JourneyModel journey;

  const IncomingJourneyCard({super.key, required this.journey});

  static String _clock(DateTime t) {
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$hour:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _ago(DateTime t, DateTime now) {
    final minutes = now.difference(t).inMinutes;
    if (minutes < 1) return 'just now';
    return '${formatMinutes(minutes, suffix: 'm')} ago';
  }

  void _openTracking(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => JourneyTrackingScreen(journeyId: journey.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isAlert = journey.status == JourneyStatus.alert;
    final isFollowed = journey.isFollowedMode;
    final isDelayed = !isAlert && !isFollowed && now.isAfter(journey.expectedArrivalAt);

    final Color accent;
    final Color background;
    final Color chipBackground;
    final IconData icon;
    final String label;
    final String chip;
    final String headline;
    final String detail;

    if (isAlert) {
      accent = AppColors.sosRed;
      background = const Color(0xFFFFF1F0);
      chipBackground = const Color(0xFFFFDDDB);
      icon = Icons.warning_amber_rounded;
      label = 'PROTECTED CONTACT NEEDS CHECKING';
      chip = 'Alert';
      headline = isFollowed ? 'Followed Mode check-in missed' : 'Missed a safety check';
      detail = 'Track their live location now';
    } else if (isFollowed) {
      accent = AppColors.actionOrange;
      background = const Color(0xFFFFF7ED);
      chipBackground = const Color(0xFFFFEDD5);
      icon = Icons.radar_rounded;
      label = 'PROTECTED CONTACT FEELS FOLLOWED';
      chip = 'Followed';
      headline = 'Thinks they are being followed';
      detail = 'Live location shared since ${_clock(journey.startedAt)}';
    } else {
      accent = isDelayed ? AppColors.actionOrange : AppColors.actionGreen;
      background = isDelayed ? const Color(0xFFFFF7ED) : const Color(0xFFF0FDF4);
      chipBackground = isDelayed ? const Color(0xFFFFEDD5) : const Color(0xFFDCFCE7);
      icon = Icons.directions_walk_rounded;
      label = 'PROTECTED CONTACT ON A SAFE JOURNEY';
      chip = isDelayed ? 'Delayed' : 'Live';
      headline = 'Heading to ${journey.destinationLabel}';
      final eta = journey.expectedArrivalAt;
      final diff = eta.difference(now);
      detail = diff.isNegative
          ? '${formatMinutes(diff.inMinutes.abs(), suffix: 'm')} past ETA • ${_clock(eta)}'
          : 'ETA in ${formatMinutes(diff.inMinutes, suffix: 'm')} • ${_clock(eta)}';
    }

    final phone = journey.ownerPhone?.trim() ?? '';
    final status = [
      if (journey.batteryLevel != null) '🔋 ${journey.batteryLevel}%',
      'Updated ${_ago(journey.lastUpdatedAt, now)}',
    ].join('  •  ');

    return GestureDetector(
      onTap: () => _openTracking(context),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isAlert || isFollowed ? accent : accent.withValues(alpha: 0.5),
            width: isAlert || isFollowed ? 1.8 : 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.08),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── "PROTECTED CONTACT …" label with live dot ──
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: accent,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Icon, name + chip, headline, ETA ──
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 20),
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
                              journey.ownerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: chipBackground,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              chip,
                              style: GoogleFonts.poppins(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 48),
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: 12),

            // ── Actions: Track Live, Call ──
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () => _openTracking(context),
                    icon: const Icon(Icons.map_rounded, color: Colors.white, size: 16),
                    label: Text(
                      'Track Live',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      elevation: 0,
                    ),
                  ),
                ),
                if (phone.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: OutlinedButton.icon(
                      onPressed: () => UrlLauncherHelper.makePhoneCall(phone),
                      icon: const Icon(Icons.call_rounded, size: 15, color: AppColors.textPrimary),
                      label: Text(
                        'Call',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.black.withValues(alpha: 0.15)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
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
