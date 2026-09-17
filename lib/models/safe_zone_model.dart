import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../core/app_colors.dart';

/// Categories of safe zones available in the app.
enum SafeZoneType {
  hospital,
  police,
  metro;

  String get label {
    switch (this) {
      case SafeZoneType.hospital:
        return 'Hospital';
      case SafeZoneType.police:
        return 'Police';
      case SafeZoneType.metro:
        return 'Metro';
    }
  }
}

/// Represents a verified nearby physical safe zone (Hospital, Police Station, Metro).
class SafeZone {
  final String id;
  final String name;
  final SafeZoneType type;
  final double latitude;
  final double longitude;
  final IconData icon;
  final Color iconColor;
  final Color bgColor;
  final String? address;
  final bool isVerifiedCheckpoint;

  const SafeZone({
    required this.id,
    required this.name,
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    this.address,
    this.isVerifiedCheckpoint = true,
  });

  /// Creates a [SafeZone] from a database or JSON map representation.
  factory SafeZone.fromJson(Map<String, dynamic> json) {
    final typeStr = (json['type'] as String? ?? 'police').toLowerCase();
    SafeZoneType type;
    IconData icon;
    Color iconColor;
    Color bgColor;

    switch (typeStr) {
      case 'hospital':
        type = SafeZoneType.hospital;
        icon = Icons.local_hospital_rounded;
        iconColor = AppColors.sosRed;
        bgColor = const Color(0xFFFFE5E5);
        break;
      case 'metro':
        type = SafeZoneType.metro;
        icon = Icons.train_rounded;
        iconColor = AppColors.actionPurple;
        bgColor = const Color(0xFFF0E6F9);
        break;
      case 'checkpoint':
      case 'police':
      default:
        type = SafeZoneType.police;
        icon = Icons.local_police_rounded;
        iconColor = AppColors.actionBlue;
        bgColor = const Color(0xFFDDEEFD);
        break;
    }

    final isVerifiedVal = json['is_verified'];
    final bool isVerified = isVerifiedVal == true ||
        isVerifiedVal == 'TRUE' ||
        isVerifiedVal == 'true' ||
        isVerifiedVal == 1;

    return SafeZone(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: type,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      icon: icon,
      iconColor: iconColor,
      bgColor: bgColor,
      address: json['address'] as String?,
      isVerifiedCheckpoint: isVerified,
    );
  }

  /// Returns [LatLng] coordinate for flutter_map integration.
  LatLng get latLng => LatLng(latitude, longitude);

  /// Calculates real-time distance in kilometers between [userLat, userLng] and this zone.
  double calculateDistanceKm(double userLat, double userLng) {
    return Geolocator.distanceBetween(userLat, userLng, latitude, longitude) / 1000.0;
  }

  /// Formats raw kilometer distance into a friendly display string (e.g. '450 m' or '1.2 km').
  static String formatDistance(double km) {
    if (km < 1.0) {
      final meters = (km * 1000).round();
      return '$meters m';
    }
    return '${km.toStringAsFixed(1)} km';
  }

  /// Direct Google Maps navigation URL with driving travel mode.
  String get navigationUrl =>
      'https://www.google.com/maps/dir/?api=1&destination=$latitude,$longitude&travelmode=driving';

  /// Realistic, verified reference catalog of safe zones across Dhaka, Bangladesh.
  static const List<SafeZone> defaultDhakaSafeZones = [
    // --- Hospitals ---
    SafeZone(
      id: 'hosp_united',
      name: 'United Hospital',
      type: SafeZoneType.hospital,
      latitude: 23.8052,
      longitude: 90.4158,
      icon: Icons.local_hospital_rounded,
      iconColor: AppColors.sosRed,
      bgColor: Color(0xFFFFE5E5),
      address: 'Plot 15, Road 71, Gulshan-2, Dhaka',
    ),
    SafeZone(
      id: 'hosp_kurmitola',
      name: 'Kurmitola General Hospital',
      type: SafeZoneType.hospital,
      latitude: 23.8223,
      longitude: 90.4124,
      icon: Icons.local_hospital_rounded,
      iconColor: AppColors.sosRed,
      bgColor: Color(0xFFFFE5E5),
      address: 'Dhaka Cantonment, Airport Road, Dhaka',
    ),
    SafeZone(
      id: 'hosp_square',
      name: 'Square Hospital',
      type: SafeZoneType.hospital,
      latitude: 23.7531,
      longitude: 90.3817,
      icon: Icons.local_hospital_rounded,
      iconColor: AppColors.sosRed,
      bgColor: Color(0xFFFFE5E5),
      address: '18/F Bir Uttam Qazi Nuruzzaman Sarak, Panthapath, Dhaka',
    ),
    SafeZone(
      id: 'hosp_dmc',
      name: 'Dhaka Medical College Hospital',
      type: SafeZoneType.hospital,
      latitude: 23.7258,
      longitude: 90.3976,
      icon: Icons.local_hospital_rounded,
      iconColor: AppColors.sosRed,
      bgColor: Color(0xFFFFE5E5),
      address: 'Secretariat Road, Bakshibazar, Dhaka',
    ),
    SafeZone(
      id: 'hosp_evercare',
      name: 'Evercare Hospital Dhaka',
      type: SafeZoneType.hospital,
      latitude: 23.8101,
      longitude: 90.4312,
      icon: Icons.local_hospital_rounded,
      iconColor: AppColors.sosRed,
      bgColor: Color(0xFFFFE5E5),
      address: 'Plot 81, Block E, Bashundhara R/A, Dhaka',
    ),

    // --- Police Stations & Checkpoints ---
    SafeZone(
      id: 'pol_banani',
      name: 'Banani Police Station',
      type: SafeZoneType.police,
      latitude: 23.7925,
      longitude: 90.4078,
      icon: Icons.local_police_rounded,
      iconColor: AppColors.actionBlue,
      bgColor: Color(0xFFDDEEFD),
      address: 'Road 11, Block D, Banani, Dhaka',
      isVerifiedCheckpoint: true,
    ),
    SafeZone(
      id: 'pol_gulshan',
      name: 'Gulshan Model Police Station',
      type: SafeZoneType.police,
      latitude: 23.7892,
      longitude: 90.4178,
      icon: Icons.local_police_rounded,
      iconColor: AppColors.actionBlue,
      bgColor: Color(0xFFDDEEFD),
      address: 'Gulshan-2, Circle 2, Dhaka',
      isVerifiedCheckpoint: true,
    ),
    SafeZone(
      id: 'pol_tejgaon',
      name: 'Tejgaon Police Station',
      type: SafeZoneType.police,
      latitude: 23.7598,
      longitude: 90.3905,
      icon: Icons.local_police_rounded,
      iconColor: AppColors.actionBlue,
      bgColor: Color(0xFFDDEEFD),
      address: 'Tejgaon Industrial Area, Dhaka',
      isVerifiedCheckpoint: true,
    ),
    SafeZone(
      id: 'pol_dhanmondi',
      name: 'Dhanmondi Police Station',
      type: SafeZoneType.police,
      latitude: 23.7465,
      longitude: 90.3760,
      icon: Icons.local_police_rounded,
      iconColor: AppColors.actionBlue,
      bgColor: Color(0xFFDDEEFD),
      address: 'Road 27, Dhanmondi, Dhaka',
      isVerifiedCheckpoint: true,
    ),
    SafeZone(
      id: 'pol_uttara',
      name: 'Uttara East Police Station',
      type: SafeZoneType.police,
      latitude: 23.8728,
      longitude: 90.3984,
      icon: Icons.local_police_rounded,
      iconColor: AppColors.actionBlue,
      bgColor: Color(0xFFDDEEFD),
      address: 'Sector 3, Uttara, Dhaka',
      isVerifiedCheckpoint: true,
    ),
    SafeZone(
      id: 'pol_mirpur',
      name: 'Mirpur Model Police Station',
      type: SafeZoneType.police,
      latitude: 23.8071,
      longitude: 90.3686,
      icon: Icons.local_police_rounded,
      iconColor: AppColors.actionBlue,
      bgColor: Color(0xFFDDEEFD),
      address: 'Mirpur-2, Section 2, Dhaka',
      isVerifiedCheckpoint: true,
    ),

    // --- Metro Stations (MRT Line 6) ---
    SafeZone(
      id: 'metro_banani_shewra',
      name: 'Shewrapara Metro Station',
      type: SafeZoneType.metro,
      latitude: 23.7937,
      longitude: 90.3735,
      icon: Icons.train_rounded,
      iconColor: AppColors.actionPurple,
      bgColor: Color(0xFFF0E6F9),
      address: 'Rokeya Sarani, Mirpur, Dhaka',
    ),
    SafeZone(
      id: 'metro_agargaon',
      name: 'Agargaon Metro Station',
      type: SafeZoneType.metro,
      latitude: 23.7785,
      longitude: 90.3789,
      icon: Icons.train_rounded,
      iconColor: AppColors.actionPurple,
      bgColor: Color(0xFFF0E6F9),
      address: 'Sher-e-Bangla Nagar, Agargaon, Dhaka',
    ),
    SafeZone(
      id: 'metro_farmgate',
      name: 'Farmgate Metro Station',
      type: SafeZoneType.metro,
      latitude: 23.7570,
      longitude: 90.3880,
      icon: Icons.train_rounded,
      iconColor: AppColors.actionPurple,
      bgColor: Color(0xFFF0E6F9),
      address: 'Farmgate, Tejgaon, Dhaka',
    ),
    SafeZone(
      id: 'metro_du',
      name: 'Dhaka University Metro Station',
      type: SafeZoneType.metro,
      latitude: 23.7314,
      longitude: 90.3962,
      icon: Icons.train_rounded,
      iconColor: AppColors.actionPurple,
      bgColor: Color(0xFFF0E6F9),
      address: 'Dhaka University Campus, Nilkhet Road, Dhaka',
    ),
    SafeZone(
      id: 'metro_mirpur10',
      name: 'Mirpur 10 Metro Station',
      type: SafeZoneType.metro,
      latitude: 23.8069,
      longitude: 90.3687,
      icon: Icons.train_rounded,
      iconColor: AppColors.actionPurple,
      bgColor: Color(0xFFF0E6F9),
      address: 'Mirpur 10 Roundabout, Dhaka',
    ),
  ];
}
