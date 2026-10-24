import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_colors.dart';
import '../models/journey_model.dart';
import '../services/journey_service.dart';

/// Screen allowing travelers and trusted guardians to track an active Safe Journey in real-time.
class JourneyTrackingScreen extends StatefulWidget {
  final String journeyId;

  const JourneyTrackingScreen({super.key, required this.journeyId});

  @override
  State<JourneyTrackingScreen> createState() => _JourneyTrackingScreenState();
}

class _JourneyTrackingScreenState extends State<JourneyTrackingScreen> {
  final MapController _mapController = MapController();

  Future<void> _openGoogleMaps(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _callPhone(String phone) async {
    if (phone.isEmpty) return;
    final clean = phone.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  String _formatClockTime(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Safe Journey Tracking',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('journeys')
            .doc(widget.journeyId)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data?.data() == null) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final journey = JourneyModel.fromMap(snapshot.data!.data()!, snapshot.data!.id);
          final isOwner = journey.ownerId == currentUid;

          final curPos = LatLng(journey.currentLat, journey.currentLng);
          final startPos = LatLng(journey.startLat, journey.startLng);
          final destPos = LatLng(journey.destinationLat, journey.destinationLng);

          final distanceToDest = JourneyService.haversineDistance(
            journey.currentLat,
            journey.currentLng,
            journey.destinationLat,
            journey.destinationLng,
          );

          final now = DateTime.now();
          final isDelayed = now.isAfter(journey.expectedArrivalAt) && journey.isActive;

          return Column(
            children: [
              // ── Map View ──────────────────────────────────────────
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: curPos,
                        initialZoom: 14.5,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.smart_safety.app',
                        ),
                        // Route polyline from start to destination
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: [startPos, destPos],
                              strokeWidth: 4.0,
                              color: AppColors.primary.withValues(alpha: 0.6),
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: [
                            // Start marker
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
                            // Destination marker
                            Marker(
                              point: destPos,
                              width: 36,
                              height: 36,
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: AppColors.actionGreen,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.flag_rounded, color: Colors.white, size: 20),
                              ),
                            ),
                            // Current live traveler position
                            Marker(
                              point: curPos,
                              width: 44,
                              height: 44,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: journey.status == JourneyStatus.alert
                                      ? AppColors.sosRed
                                      : AppColors.primary,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: (journey.status == JourneyStatus.alert
                                              ? AppColors.sosRed
                                              : AppColors.primary)
                                          .withValues(alpha: 0.4),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.directions_walk_rounded, color: Colors.white, size: 24),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Top Status Badge Overlay
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
                                    color: journey.isActive
                                        ? AppColors.actionGreen
                                        : journey.status == JourneyStatus.alert
                                            ? AppColors.sosRed
                                            : AppColors.textSecondary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  journey.status == JourneyStatus.arrived
                                      ? '✅ Arrived Safely'
                                      : journey.status == JourneyStatus.alert
                                          ? '🚨 SOS Alert Active'
                                          : isDelayed
                                              ? '⚠️ Delayed'
                                              : '🚶 Live Route Active',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: journey.status == JourneyStatus.alert
                                        ? AppColors.sosRed
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            if (journey.batteryLevel != null)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '🔋 ${journey.batteryLevel}%',
                                  style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Bottom Information Card ───────────────────────────
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
                    // Traveler & Destination
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.primarySurface,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.place_rounded, color: AppColors.primary, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                journey.destinationLabel,
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                '${journey.ownerName} • ${distanceToDest.round()}m remaining',
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
                    const SizedBox(height: 14),

                    // Timing Chips: Started · Expected Arrival
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
                                Text('Started At', style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
                                Text(_formatClockTime(journey.startedAt), style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isDelayed ? const Color(0xFFFFEDD5) : AppColors.background,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(isDelayed ? 'Delayed Past' : 'Expected Arrival', style: GoogleFonts.poppins(fontSize: 10, color: isDelayed ? AppColors.actionOrange : AppColors.textSecondary)),
                                Text(_formatClockTime(journey.expectedArrivalAt), style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: isDelayed ? AppColors.actionOrange : AppColors.textPrimary)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Actions
                    if (isOwner && journey.isActive) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                await JourneyService.instance.completeJourney();
                                if (context.mounted) Navigator.of(context).pop();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.actionGreen,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: Text("I'VE ARRIVED", style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: Colors.white)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                await JourneyService.instance.extendTime(15);
                              },
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: AppColors.primary),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: Text('+15m EXTEND', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: AppColors.primary)),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      Row(
                        children: [
                          if (journey.ownerPhone != null && journey.ownerPhone!.isNotEmpty)
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _callPhone(journey.ownerPhone!),
                                icon: const Icon(Icons.call_rounded, color: AppColors.actionGreen, size: 18),
                                label: Text('Call', style: GoogleFonts.poppins(color: AppColors.actionGreen, fontWeight: FontWeight.w700)),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: AppColors.actionGreen),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          if (journey.ownerPhone != null && journey.ownerPhone!.isNotEmpty)
                            const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _openGoogleMaps(journey.currentLat, journey.currentLng),
                              icon: const Icon(Icons.map_rounded, color: Colors.white, size: 18),
                              label: Text('Google Maps', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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
