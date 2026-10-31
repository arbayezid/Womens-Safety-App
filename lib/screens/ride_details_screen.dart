import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_colors.dart';
import '../models/ride_checkin.dart';
import '../services/navigation_service.dart';

/// Guardian View screen showing real-time vehicle details, live GPS map tracking,
/// zoomable plate photo evidence, "Call", and "Navigate" actions.
class RideDetailsScreen extends StatefulWidget {
  final String rideId;

  const RideDetailsScreen({super.key, required this.rideId});

  @override
  State<RideDetailsScreen> createState() => _RideDetailsScreenState();
}

class _RideDetailsScreenState extends State<RideDetailsScreen> {
  final MapController _mapController = MapController();

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

  Future<void> _callNumber(String phone) async {
    final clean = phone.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Widget _buildStatusBadge(RideStatus status) {
    Color bg;
    Color fg;
    String label;
    IconData icon;

    switch (status) {
      case RideStatus.active:
        bg = const Color(0xFFDFF5E3);
        fg = AppColors.actionGreen;
        label = 'ACTIVE RIDE';
        icon = Icons.directions_car_rounded;
        break;
      case RideStatus.arrived:
        bg = const Color(0xFFDFF5E3);
        fg = AppColors.actionGreen;
        label = 'ARRIVED SAFELY';
        icon = Icons.check_circle_rounded;
        break;
      case RideStatus.overdue:
        bg = const Color(0xFFFFEEEE);
        fg = AppColors.sosRed;
        label = 'OVERDUE';
        icon = Icons.warning_rounded;
        break;
      case RideStatus.sos:
        bg = const Color(0xFFFFEEEE);
        fg = AppColors.sosRed;
        label = 'EMERGENCY SOS';
        icon = Icons.notifications_active_rounded;
        break;
      case RideStatus.cancelled:
        bg = const Color(0xFFEEEEF2);
        fg = AppColors.textSecondary;
        label = 'CANCELLED';
        icon = Icons.cancel_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Ride Details (Guardian View)',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
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

          final currentPos = LatLng(ride.currentLat, ride.currentLng);
          final startPos = LatLng(ride.startLat, ride.startLng);

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
              // ── REAL-TIME MAP VIEW ─────────────────────────────────
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
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: trailPoints,
                              strokeWidth: 4.5,
                              color: ride.status == RideStatus.overdue || ride.status == RideStatus.sos
                                  ? AppColors.sosRed
                                  : AppColors.primary,
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: [
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
                            Marker(
                              point: currentPos,
                              width: 44,
                              height: 44,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: ride.status == RideStatus.sos || ride.status == RideStatus.overdue
                                      ? AppColors.sosRed
                                      : AppColors.primary,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primary.withValues(alpha: 0.35),
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

                    // Top status badge
                    Positioned(
                      top: 12,
                      left: 16,
                      child: _buildStatusBadge(ride.status),
                    ),

                    if (ride.batteryLevel != null)
                      Positioned(
                        top: 12,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surface.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '🔋 ${ride.batteryLevel}% Battery',
                            style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── BOTTOM VEHICLE EVIDENCE & ACTION CARD ───────────────
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
                    // Traveler & Plate Information
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (ride.platePhotoUrl != null)
                          GestureDetector(
                            onTap: () => _showZoomableImage(ride.platePhotoUrl!),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(
                                    ride.platePhotoUrl!,
                                    width: 60,
                                    height: 60,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  bottom: 2,
                                  right: 2,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
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
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: AppColors.primarySurface,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.local_taxi_rounded, color: AppColors.primary, size: 28),
                          ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ride.plateFormatted,
                                style: GoogleFonts.poppins(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                '${ride.userName} • ${ride.rideType}${ride.appName != null ? " (${ride.appName})" : ""}',
                                style: GoogleFonts.poppins(
                                  fontSize: 12.5,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (ride.destination != null && ride.destination!['label'] != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.place_rounded, size: 12, color: AppColors.primary),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          'To: ${ride.destination!['label']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    if (ride.driverName != null || ride.driverPhone != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.badge_outlined, size: 16, color: AppColors.textSecondary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Driver: ${ride.driverName ?? "Driver"} ${ride.driverPhone != null ? "(${ride.driverPhone})" : ""}',
                                style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (ride.driverPhone != null)
                              IconButton(
                                icon: const Icon(Icons.call_rounded, color: AppColors.actionGreen, size: 18),
                                onPressed: () => _callNumber(ride.driverPhone!),
                                tooltip: 'Call Driver',
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ),
                    ],

                    if (ride.screenshotUrl != null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _showZoomableImage(ride.screenshotUrl!),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDDEEFD),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.image_rounded, size: 16, color: AppColors.actionBlue),
                              const SizedBox(width: 8),
                              Text('View Shared Ride App Screenshot', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.actionBlue, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              const Icon(Icons.open_in_new_rounded, size: 14, color: AppColors.actionBlue),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 18),

                    // Primary Guardian Action Buttons: Call Traveler & Navigate
                    Row(
                      children: [
                        if (ride.userPhone != null && ride.userPhone!.isNotEmpty) ...[
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _callNumber(ride.userPhone!),
                              icon: const Icon(Icons.call_rounded, color: AppColors.actionGreen, size: 18),
                              label: Text('Call', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: AppColors.actionGreen)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: AppColors.actionGreen),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              NavigationService.instance.navigateTo(
                                destLat: ride.currentLat,
                                destLng: ride.currentLng,
                                destLabel: '${ride.userName}\'s Ride (${ride.plateFormatted})',
                              );
                            },
                            icon: const Icon(Icons.navigation_rounded, color: Colors.white, size: 18),
                            label: Text('Navigate', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              elevation: 0,
                            ),
                          ),
                        ),
                      ],
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
