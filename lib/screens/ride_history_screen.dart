import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/ride_checkin.dart';
import 'active_ride_screen.dart';
import 'ride_details_screen.dart';
import 'sos_history_screen.dart';

/// Screen displaying the complete history of Ride Check-ins
/// (sent by current traveler, received as trusted guardian, and all).
class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _ridesStream;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    final user = FirebaseAuth.instance.currentUser;
    final myUid = user?.uid ?? '';
    final myEmail = (user?.email ?? '').toLowerCase().trim();
    _ridesStream = _buildHistoryStream(myUid, myEmail);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _buildHistoryStream(
    String myUid,
    String myEmail,
  ) {
    if (myUid.isEmpty) {
      return Stream.value([]);
    }

    final streams = <Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>>[
      // (a) Sent rides (where current user is sender)
      FirebaseFirestore.instance
          .collection('ride_checkins')
          .where('userId', isEqualTo: myUid)
          .snapshots()
          .map((snap) => snap.docs),

      // (b) Received rides (where current user is guardian UID)
      FirebaseFirestore.instance
          .collection('ride_checkins')
          .where('guardianIds', arrayContains: myUid)
          .snapshots()
          .map((snap) => snap.docs),
    ];

    if (myEmail.isNotEmpty) {
      streams.add(
        FirebaseFirestore.instance
            .collection('ride_checkins')
            .where('guardianEmails', arrayContains: myEmail)
            .snapshots()
            .map((snap) => snap.docs),
      );
    }

    return mergeAndDeduplicateStreams<QueryDocumentSnapshot<Map<String, dynamic>>, String>(
      streams: streams,
      idExtractor: (doc) => doc.id,
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final month = months[dt.month - 1];
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$month ${dt.day}, ${dt.year} • $hour:$minute $period';
  }

  Widget _buildStatusChip(RideStatus status) {
    Color bg;
    Color fg;
    String label;

    switch (status) {
      case RideStatus.active:
        bg = const Color(0xFFDFF5E3);
        fg = AppColors.actionGreen;
        label = 'ACTIVE';
        break;
      case RideStatus.arrived:
        bg = const Color(0xFFDFF5E3);
        fg = AppColors.actionGreen;
        label = 'ARRIVED';
        break;
      case RideStatus.overdue:
        bg = const Color(0xFFFFEEEE);
        fg = AppColors.sosRed;
        label = 'OVERDUE';
        break;
      case RideStatus.sos:
        bg = const Color(0xFFFFEEEE);
        fg = AppColors.sosRed;
        label = 'SOS';
        break;
      case RideStatus.cancelled:
        bg = const Color(0xFFEEEEF2);
        fg = AppColors.textSecondary;
        label = 'CANCELLED';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }

  Widget _buildRideList(List<RideCheckinModel> rides, String myUid) {
    if (rides.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: AppColors.primarySurface, shape: BoxShape.circle),
              child: const Icon(Icons.no_crash_rounded, size: 36, color: AppColors.primary),
            ),
            const SizedBox(height: 14),
            Text('No Ride Check-ins Found', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Recorded vehicle rides will appear here.', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: rides.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final ride = rides[i];
        final isSender = ride.userId == myUid;

        return GestureDetector(
          onTap: () {
            if (isSender && ride.isActive) {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ActiveRideScreen(rideId: ride.id)),
              );
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => RideDetailsScreen(rideId: ride.id)),
              );
            }
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.local_taxi_rounded, color: AppColors.primary, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              ride.plateFormatted,
                              style: GoogleFonts.poppins(fontSize: 14.5, fontWeight: FontWeight.w800),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          _buildStatusChip(ride.status),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${isSender ? "You" : ride.userName} • ${ride.rideType}',
                        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDate(ride.createdAt),
                        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Ride History',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 13),
          tabs: const [
            Tab(text: 'Sent'),
            Tab(text: 'Received'),
            Tab(text: 'All'),
          ],
        ),
      ),
      body: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
        stream: _ridesStream,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppColors.primary));
          }

          final allDocs = snapshot.data!;
          final List<RideCheckinModel> allRides = allDocs
              .map((d) => RideCheckinModel.fromMap(d.data(), d.id))
              .toList();

          allRides.sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final sentRides = allRides.where((r) => r.userId == myUid).toList();
          final receivedRides = allRides.where((r) => r.userId != myUid).toList();

          return TabBarView(
            controller: _tabController,
            children: [
              _buildRideList(sentRides, myUid),
              _buildRideList(receivedRides, myUid),
              _buildRideList(allRides, myUid),
            ],
          );
        },
      ),
    );
  }
}
