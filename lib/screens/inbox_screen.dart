import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/app_colors.dart';
import '../services/inbox_service.dart';
import 'contacts_screen.dart';
import 'incident_room_screen.dart';
import 'journey_tracking_screen.dart';
import 'ride_details_screen.dart';

/// Notification inbox (bell): every SOS alert, Safe Journey update, ride check-in and guardian
/// request from the people this user protects. Opening it clears the bell badge; an entry stays
/// highlighted until it is tapped.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  @override
  void initState() {
    super.initState();
    InboxService.instance.markAllSeen();
  }

  void _open(InboxItem item) {
    InboxService.instance.markRead(item);
    final Widget screen = switch (item.type) {
      InboxItemType.sos => IncidentRoomScreen(alertId: item.id),
      InboxItemType.journey => JourneyTrackingScreen(journeyId: item.id),
      InboxItemType.ride => RideDetailsScreen(rideId: item.id),
      InboxItemType.request => const ContactsScreen(),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text(
          'Notifications',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.textPrimary),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          TextButton(
            onPressed: () => InboxService.instance.markAllRead(),
            child: Text('Mark all read', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.primary)),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<InboxItem>>(
        valueListenable: InboxService.instance.itemsNotifier,
        builder: (context, items, _) {
          if (items.isEmpty) return const _EmptyInbox();
          final service = InboxService.instance;
          final fresh = items.where(service.isUnread).toList();
          final earlier = items.where((i) => !service.isUnread(i)).toList();
          final now = DateTime.now();
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (fresh.isNotEmpty) ...[
                const _SectionHeader('New'),
                for (final i in fresh) _InboxTile(item: i, unread: true, now: now, onTap: () => _open(i)),
              ],
              if (earlier.isNotEmpty) ...[
                const _SectionHeader('Earlier'),
                for (final i in earlier) _InboxTile(item: i, unread: false, now: now, onTap: () => _open(i)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        label,
        style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
      ),
    );
  }
}

class _InboxTile extends StatelessWidget {
  final InboxItem item;
  final bool unread;
  final DateTime now;
  final VoidCallback onTap;

  const _InboxTile({required this.item, required this.unread, required this.now, required this.onTap});

  (IconData, Color) get _icon => switch (item.type) {
        InboxItemType.sos => (Icons.sos_rounded, AppColors.sosRed),
        InboxItemType.journey => (Icons.directions_walk_rounded, AppColors.primary),
        InboxItemType.ride => (Icons.local_taxi_rounded, AppColors.actionBlue),
        InboxItemType.request => (Icons.person_add_alt_1_rounded, AppColors.actionOrange),
      };

  (Color, Color) get _chipColors => switch (item.tone) {
        InboxTone.live => (AppColors.sosRed, Colors.white),
        InboxTone.warning => (const Color(0xFFFFF1DC), const Color(0xFFB86E00)),
        InboxTone.ok => (AppColors.successBackground, AppColors.successForeground),
        InboxTone.neutral => (const Color(0xFFEFEFF4), AppColors.textSecondary),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _icon;
    final (chipBg, chipFg) = _chipColors;
    return Material(
      color: unread ? AppColors.primarySurface.withValues(alpha: 0.55) : AppColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.divider, width: 0.6)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (item.body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, height: 1.35),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            item.status,
                            style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: chipFg),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            InboxService.formatTime(item.time, now),
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: unread ? AppColors.primary : AppColors.textSecondary,
                              fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (unread)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 18),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notifications_none_rounded, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              'No notifications yet',
              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              'SOS alerts, journeys, rides and guardian requests from the people you protect will appear here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
