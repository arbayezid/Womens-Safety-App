import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/safe_zone_model.dart';
import 'package:smart_safety/services/navigation_service.dart';
import 'package:smart_safety/services/safe_zone_repository.dart';

void main() {
  group('NavigationService URI Builder Tests', () {
    test('buildGoogleMapsDirUri formats origin and destination with travel mode', () {
      final uri = NavigationService.instance.buildGoogleMapsDirUri(
        curLat: 23.7806,
        curLng: 90.4267,
        destLat: 23.7925,
        destLng: 90.4078,
        mode: TravelMode.driving,
      );

      final url = uri.toString();
      expect(url, contains('api=1'));
      expect(url, contains('origin=23.7806,90.4267'));
      expect(url, contains('destination=23.7925,90.4078'));
      expect(url, contains('travelmode=driving'));
      expect(url, contains('dir_action=navigate'));
    });

    test('buildGoogleMapsDirUri handles null current location with destination only', () {
      final uri = NavigationService.instance.buildGoogleMapsDirUri(
        curLat: null,
        curLng: null,
        destLat: 23.7925,
        destLng: 90.4078,
        mode: TravelMode.walking,
      );

      final url = uri.toString();
      expect(url, isNot(contains('origin=')));
      expect(url, contains('destination=23.7925,90.4078'));
      expect(url, contains('travelmode=walking'));
    });

    test('buildAndroidNavigationUri formats native intent correctly', () {
      final uri = NavigationService.instance.buildAndroidNavigationUri(
        destLat: 23.7806,
        destLng: 90.4267,
        mode: TravelMode.driving,
      );

      expect(uri.scheme, equals('google.navigation'));
      expect(uri.toString(), equals('google.navigation:q=23.7806,90.4267&mode=d'));
    });

    test('buildGenericGeoUri formats geo intent with label correctly', () {
      final uri = NavigationService.instance.buildGenericGeoUri(
        destLat: 23.7806,
        destLng: 90.4267,
        label: 'Badda Police Station',
      );

      expect(uri.scheme, equals('geo'));
      expect(uri.toString(), contains('geo:23.7806,90.4267?q=23.7806,90.4267(Badda%20Police%20Station)'));
    });

    test('buildAppleMapsUri formats saddr and daddr correctly', () {
      final uri = NavigationService.instance.buildAppleMapsUri(
        curLat: 23.7806,
        curLng: 90.4267,
        destLat: 23.7925,
        destLng: 90.4078,
      );

      expect(uri.scheme, equals('https'));
      expect(uri.host, equals('maps.apple.com'));
      expect(uri.queryParameters['saddr'], equals('23.7806,90.4267'));
      expect(uri.queryParameters['daddr'], equals('23.7925,90.4078'));
    });

    test('buildWebSearchUri formats query correctly', () {
      final uri = NavigationService.instance.buildWebSearchUri(
        destLat: 23.7806,
        destLng: 90.4267,
      );

      expect(uri.scheme, equals('https'));
      expect(uri.host, equals('www.google.com'));
      expect(uri.path, equals('/maps/search/'));
      expect(uri.queryParameters['query'], equals('23.7806,90.4267'));
    });
  });

  group('SafeZoneRepository Sorting & Distance Tests', () {
    final sampleZones = [
      SafeZone.fromJson(const {
        'id': 'pol_gulshan',
        'name': 'Gulshan Model Police Station',
        'type': 'police',
        'latitude': 23.7925,
        'longitude': 90.4078,
        'address': 'Gulshan-2, Dhaka',
      }),
      SafeZone.fromJson(const {
        'id': 'pol_badda',
        'name': 'Badda Police Station',
        'type': 'police',
        'latitude': 23.7806,
        'longitude': 90.4267,
        'address': 'Badda, Dhaka',
      }),
      SafeZone.fromJson(const {
        'id': 'pol_banani',
        'name': 'Banani Police Station',
        'type': 'police',
        'latitude': 23.7940,
        'longitude': 90.4040,
        'address': 'Banani, Dhaka',
      }),
    ];

    setUp(() {
      SafeZoneRepository.instance.setCachedSafeZonesForTesting(sampleZones);
    });

    test('getSortedSafeZones returns nearest first from user coordinates', () {
      // User is at Rampura (23.7650, 90.4250) - Badda is closest (~1.7 km)
      final sorted = SafeZoneRepository.instance.getSortedSafeZones(
        curLat: 23.7650,
        curLng: 90.4250,
      );

      expect(sorted.first.id, equals('pol_badda'));
    });

    test('getNearestPoliceStation returns the closest police station correctly', () {
      final nearest = SafeZoneRepository.instance.getNearestPoliceStation(
        curLat: 23.7930,
        curLng: 90.4075, // Right next to Gulshan Model Police Station
      );

      expect(nearest, isNotNull);
      expect(nearest!.id, equals('pol_gulshan'));
    });

    test('Threshold caching detects movement >= 50 meters', () {
      final repo = SafeZoneRepository.instance;
      expect(repo.shouldRecalculate(23.7800, 90.4200, 23.7800, 90.4201), isFalse); // ~10m
      expect(repo.shouldRecalculate(23.7800, 90.4200, 23.7810, 90.4200), isTrue);  // ~111m
    });
  });
}
