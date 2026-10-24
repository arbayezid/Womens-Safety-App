import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/journey_model.dart';
import '../screens/journey_tracking_screen.dart';
import '../services/journey_service.dart';
import '../services/pin_security_service.dart';
import 'pin_input_dialog.dart';

/// Card displayed on the home screen safety dashboard when a Safe Journey session is active.
class ActiveJourneyCard extends StatelessWidget {
  final JourneyModel journey;

  const ActiveJourneyCard({super.key, required this.journey});

  String _formatEta(DateTime eta) {
    final now = DateTime.now();
    final diff = eta.difference(now);
    final hour = eta.hour == 0 ? 12 : (eta.hour > 12 ? eta.hour - 12 : eta.hour);
    final minute = eta.minute.toString().padLeft(2, '0');
    final period = eta.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$minute $period';

    if (diff.isNegative) {
      return 'Delayed • $timeStr (${diff.inMinutes.abs()}m past ETA)';
    }
    return 'ETA in ${diff.inMinutes}m • $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final isDelayed = DateTime.now().isAfter(journey.expectedArrivalAt);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => JourneyTrackingScreen(journeyId: journey.id),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDelayed ? const Color(0xFFFFF7ED) : const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDelayed
                ? AppColors.actionOrange.withValues(alpha: 0.5)
                : AppColors.actionGreen.withValues(alpha: 0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: (isDelayed ? AppColors.actionOrange : AppColors.actionGreen)
                  .withValues(alpha: 0.08),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Walking icon, destination, and live indicator
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isDelayed ? AppColors.actionOrange : AppColors.actionGreen,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.directions_walk_rounded,
                    color: Colors.white,
                    size: 20,
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
                              'Safe Journey to ${journey.destinationLabel}',
                              style: GoogleFonts.poppins(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDelayed ? const Color(0xFFFFEDD5) : const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isDelayed ? 'Delayed' : 'Active',
                              style: GoogleFonts.poppins(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: isDelayed ? AppColors.actionOrange : AppColors.actionGreen,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatEta(journey.expectedArrivalAt),
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDelayed ? AppColors.actionOrange : AppColors.actionGreen,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
              ],
            ),
            const SizedBox(height: 12),

            // Action Buttons: I've Arrived, +15m, Cancel
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await JourneyService.instance.completeJourney();
                    },
                    icon: const Icon(Icons.check_circle_rounded, color: Colors.white, size: 16),
                    label: Text(
                      "I've Arrived",
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.actionGreen,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    onPressed: () async {
                      await JourneyService.instance.extendTime(15);
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.black.withValues(alpha: 0.15)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: Text(
                      '+15m',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Cancel Journey',
                  icon: const Icon(Icons.cancel_outlined, color: AppColors.textSecondary, size: 20),
                  onPressed: () async {
                    final pinEnabled = await PinSecurityService.instance.isPinEnabled();
                    final realConfigured = await PinSecurityService.instance.isRealPinConfigured();

                    if (pinEnabled && realConfigured) {
                      if (!context.mounted) return;
                      final verified = await PinInputDialog.show(
                        context,
                        mode: PinDialogMode.verify,
                        customTitle: 'Cancel Safe Journey',
                        customSubtitle: 'Enter your Security PIN to stop journey tracking',
                      );
                      if (verified == true) {
                        await JourneyService.instance.cancelJourney();
                      }
                      return;
                    }

                    if (!context.mounted) return;
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        title: Text('Cancel Safe Journey?', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                        content: Text('Are you sure you want to stop monitoring this safe journey?', style: GoogleFonts.poppins(fontSize: 13)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text('Keep Going', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            style: ElevatedButton.styleFrom(backgroundColor: AppColors.sosRed),
                            child: Text('Cancel Journey', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await JourneyService.instance.cancelJourney();
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
