import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/core/app_colors.dart';
import 'package:smart_safety/models/safe_zone_model.dart';
import 'package:smart_safety/screens/map_screen.dart';

void main() {
  group('SafeZone Model Tests', () {
    test('Constructs SafeZone with correct parameters', () {
      const zone = SafeZone(
        id: 'test_zone',
        name: 'Test Police Station',
        type: SafeZoneType.police,
        latitude: 23.7925,
        longitude: 90.4078,
        icon: Icons.local_police_rounded,
        iconColor: AppColors.actionBlue,
        bgColor: Color(0xFFDDEEFD),
        address: 'Test Address',
      );

      expect(zone.id, 'test_zone');
      expect(zone.name, 'Test Police Station');
      expect(zone.type, SafeZoneType.police);
      expect(zone.type.label, 'Police');
      expect(zone.latitude, 23.7925);
      expect(zone.longitude, 90.4078);
      expect(zone.latLng.latitude, 23.7925);
      expect(zone.latLng.longitude, 90.4078);
      expect(
        zone.navigationUrl,
        'https://www.google.com/maps/dir/?api=1&destination=23.7925,90.4078&travelmode=driving',
      );
    });

    test('formatDistance formats meters when under 1 km', () {
      expect(SafeZone.formatDistance(0.45), '450 m');
      expect(SafeZone.formatDistance(0.05), '50 m');
      expect(SafeZone.formatDistance(0.999), '999 m');
    });

    test('formatDistance formats kilometers with 1 decimal when >= 1 km', () {
      expect(SafeZone.formatDistance(1.0), '1.0 km');
      expect(SafeZone.formatDistance(2.45), '2.5 km');
      expect(SafeZone.formatDistance(12.34), '12.3 km');
    });

    test('calculateDistanceKm returns accurate distance between points', () {
      // Banani: ~23.7937, 90.4066
      // Banani Police: 23.7925, 90.4078
      const zone = SafeZone(
        id: 'pol_banani',
        name: 'Banani Police',
        type: SafeZoneType.police,
        latitude: 23.7925,
        longitude: 90.4078,
        icon: Icons.local_police_rounded,
        iconColor: AppColors.actionBlue,
        bgColor: Color(0xFFDDEEFD),
      );

      final distKm = zone.calculateDistanceKm(23.7937, 90.4066);
      expect(distKm, isPositive);
      expect(distKm, lessThan(1.0)); // Less than 1km away in Banani
    });

    test('Default catalog contains realistic safe zones across Dhaka', () {
      const zones = SafeZone.defaultDhakaSafeZones;
      expect(zones, isNotEmpty);
      expect(zones.any((z) => z.type == SafeZoneType.police), isTrue);
      expect(zones.any((z) => z.type == SafeZoneType.hospital), isTrue);
      expect(zones.any((z) => z.type == SafeZoneType.metro), isTrue);
    });

    test('Sorting orders safe zones by proximity to user', () {
      // Reference user location in Banani
      const userLat = 23.7937;
      const userLng = 90.4066;

      final zones = List<SafeZone>.from(SafeZone.defaultDhakaSafeZones);
      zones.sort((a, b) {
        final distA = a.calculateDistanceKm(userLat, userLng);
        final distB = b.calculateDistanceKm(userLat, userLng);
        return distA.compareTo(distB);
      });

      // The first zone should be closer than the last zone
      final firstDist = zones.first.calculateDistanceKm(userLat, userLng);
      final lastDist = zones.last.calculateDistanceKm(userLat, userLng);
      expect(firstDist, lessThan(lastDist));
    });

    test('MapScreen formatDegreeMinutes formats coordinates cleanly', () {
      final formatted = MapScreen.formatDegreeMinutes(23.7925, 90.4078);
      expect(formatted, contains('23°'));
      expect(formatted, contains('N'));
      expect(formatted, contains('90°'));
      expect(formatted, contains('E'));
    });
  });
}
