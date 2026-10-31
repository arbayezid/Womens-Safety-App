import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../core/app_colors.dart';
import '../models/ride_checkin.dart';
import '../services/emergency_service.dart';
import '../services/ride_checkin_service.dart';

/// Active Ride tracking screen for the traveler.
/// Displays live GPS location, elapsed duration vs expected ETA, plate card with zoomable photo,
/// "Arrived Safely" button, cancel option, and emergency SOS trigger.
class ActiveRideScreen extends StatefulWidget {
  final String rideId;

  const ActiveRideScreen({super.key, required this.rideId});

  @override
  State<ActiveRideScreen> createState() => _ActiveRideScreenState();
}

class _ActiveRideScreenState extends State<ActiveRideScreen> {
  final MapController _mapController = MapController();
  Timer? _tickerTimer;
  bool _isArriving = false;

  @override
  void initState() {
    super.initState();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final mins = d.inMinutes % 60;
    final secs = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${mins}m ${secs}s';
    }
    return '${mins}m ${secs.toString().padLeft(2, '0')}s';
  }

  void _showZoomableImage(String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.network(imageUrl, fit: BoxFit.contain),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleArrivedSafely() async {
    HapticFeedback.heavyImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.actionGreen, size: 28),
            const SizedBox(width: 10),
            Text('Arrived Safely?', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 17)),
          ],
        ),
        content: Text(
          'This will complete your ride session, stop live GPS tracking, and notify your guardians that you arrived safely.',
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
              backgroundColor: AppColors.actionGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('Confirm Arrival', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isArriving = true);
    try {
      await RideCheckinService.instance.arriveSafely(rideId: widget.rideId);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text('✅ Guardians notified: You arrived safely!', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          backgroundColor: AppColors.actionGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isArriving = false);
    }
  }

  Future<void> _handleCancelRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Cancel Ride?', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 17)),
        content: Text(
          'Are you sure you want to cancel this ride check-in session?',
          style: GoogleFonts.poppins(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('No', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.sosRed),
            child: Text('Yes, Cancel', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await RideCheckinService.instance.cancelRide(rideId: widget.rideId);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _handleEmergencySos() async {
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🚨 Triggering Emergency SOS...', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
        backgroundColor: AppColors.sosRed,
      ),
    );
    await EmergencyService.instance.triggerEmergency(source: 'Active Ride SOS');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Active Ride Tracking',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_time_rounded, color: AppColors.primary),
            tooltip: 'Extend ride time (+15m)',
            onPressed: () async {
              await RideCheckinService.instance.extendRideTime(15);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Added 15 minutes to expected ride duration.', style: GoogleFonts.poppins()),
                    backgroundColor: AppColors.primary,
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('ride_checkins')
            .doc(widget.rideId)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data?.data() == null) {
            return const Center(child: CircularProgressIndicator(color: AppColors.primary));
          }

          final ride = RideCheckinModel.fromMap(snapshot.data!.data()!, snapshot.data!.id);

          final now = DateTime.now();
          final elapsed = now.difference(ride.createdAt);
          final expectedDuration = Duration(minutes: ride.expectedMinutes ?? 30);
          final isOverdue = now.isAfter(ride.createdAt.add(expectedDuration + const Duration(minutes: 10)));

          final startPos = LatLng(ride.startLat, ride.startLng);
          final currentPos = LatLng(ride.currentLat, ride.currentLng);

          final trailPoints = ride.recentTrail
              .map((t) => LatLng(
                    (t['latitude'] as num).toDouble(),
                    (t['longitude'] as num).toDouble(),
                  ))
              .toList();

          if (trailPoints.isEmpty) {
            trailPoints.add(startPos);
            trailPoints.add(currentPos);
          }

          return Column(
            children: [
              // ── LIVE MAP VIEW ──────────────────────────────────────
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: currentPos,
                        initialZoom: 15.0,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.smart_safety.app',
                        ),
                        // Trail polyline
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: trailPoints,
                              strokeWidth: 4.5,
                              color: isOverdue ? AppColors.sosRed : AppColors.primary,
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: [
                            // Start Location Marker
                            Marker(
                              point: startPos,
                              width: 32,
                              height: 32,
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: AppColors.actionBlue,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.trip_origin_rounded, color: Colors.white, size: 18),
                              ),
                            ),
                            // Current Live Position Marker
                            Marker(
                              point: currentPos,
                              width: 44,
                              height: 44,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isOverdue ? AppColors.sosRed : AppColors.primary,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: (isOverdue ? AppColors.sosRed : AppColors.primary).withValues(alpha: 0.4),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.local_taxi_rounded, color: Colors.white, size: 24),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Top Status Overlay Pill
                    Positioned(
                      top: 12,
                      left: 16,
                      right: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: isOverdue ? AppColors.sosRed : AppColors.actionGreen,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  isOverdue
                                      ? '⚠️ RIDE OVERDUE (Dead-Man Active)'
                                      : '🚗 Live Ride Tracking Active',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isOverdue ? AppColors.sosRed : AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            if (ride.batteryLevel != null)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text('🔋 ${ride.batteryLevel}%', style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700)),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // SOS Emergency Button Floating Quick Access
                    Positioned(
                      bottom: 14,
                      right: 16,
                      child: FloatingActionButton.extended(
                        heroTag: 'active_ride_sos',
                        onPressed: _handleEmergencySos,
                        backgroundColor: AppColors.sosRed,
                        icon: const Icon(Icons.warning_amber_rounded, color: Colors.white),
                        label: Text('SOS', style: GoogleFonts.poppins(fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1)),
                      ),
                    ),
                  ],
                ),
              ),

              // ── BOTTOM VEHICLE & CONTROL PANEL ──────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x0F000000),
                      blurRadius: 16,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Vehicle Plate Header Row
                    Row(
                      children: [
                        // Zoomable Plate photo thumbnail
                        if (ride.platePhotoUrl != null)
                          GestureDetector(
                            onTap: () => _showZoomableImage(ride.platePhotoUrl!),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(
                                    ride.platePhotoUrl!,
                                    width: 54,
                                    height: 54,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  bottom: 2,
                                  right: 2,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.6),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.zoom_in_rounded, size: 12, color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: AppColors.primarySurface,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.local_taxi_rounded, color: AppColors.primary, size: 26),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ride.plateFormatted,
                                style: GoogleFonts.poppins(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                '${ride.rideType}${ride.appName != null ? " • ${ride.appName}" : ""}',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    if (ride.driverName != null || ride.driverPhone != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (ride.driverName != null) ...[
                            const Icon(Icons.person_rounded, size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 4),
                            Text(ride.driverName!, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                          if (ride.driverName != null && ride.driverPhone != null)
                            const Text(' • ', style: TextStyle(color: Colors.grey)),
                          if (ride.driverPhone != null) ...[
                            const Icon(Icons.phone_rounded, size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 4),
                            Text(ride.driverPhone!, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ],
                      ),
                    ],

                    const SizedBox(height: 14),

                    // Elapsed & Expected Duration Chips
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Elapsed Time', style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
                                Text(_formatDuration(elapsed), style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isOverdue ? const Color(0xFFFFEEEE) : AppColors.background,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Expected Duration', style: GoogleFonts.poppins(fontSize: 10, color: isOverdue ? AppColors.sosRed : AppColors.textSecondary)),
                                Text('${ride.expectedMinutes ?? 30} mins', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: isOverdue ? AppColors.sosRed : AppColors.textPrimary)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Large "Arrived Safely" Primary Action
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _isArriving ? null : _handleArrivedSafely,
                        icon: _isArriving
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 22),
                        label: Text(
                          _isArriving ? 'NOTIFYING GUARDIANS...' : 'ARRIVED SAFELY',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
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
                    const SizedBox(height: 8),

                    // Secondary Action: Cancel Ride
                    Center(
                      child: TextButton(
                        onPressed: _handleCancelRide,
                        child: Text(
                          'Cancel Ride',
                          style: GoogleFonts.poppins(
                            color: AppColors.textSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
