import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:smart_safety/services/location_service.dart';

void main() {
  group('LocationService Formatting Tests', () {
    test('Formats positive coordinates into N and E', () {
      final formatted = LocationService.formatCoordinates(23.8103, 90.4125);
      expect(formatted, '23.8103° N, 90.4125° E');
    });

    test('Formats negative coordinates into S and W', () {
      final formatted = LocationService.formatCoordinates(-33.8688, -70.6693);
      expect(formatted, '33.8688° S, 70.6693° W');
    });

    test('formatPlacemark cleanly combines street, subLocality, and locality', () {
      const placemark = Placemark(
        street: 'Road 11',
        subLocality: 'Banani',
        locality: 'Dhaka',
        administrativeArea: 'Dhaka Division',
        country: 'Bangladesh',
      );

      final result = LocationService.formatPlacemark(placemark);
      expect(result, 'Road 11, Banani, Dhaka');
    });

    test('formatPlacemark filters out plus-code streets and deduplicates', () {
      const placemark = Placemark(
        street: 'Q9XR+23 Banani',
        thoroughfare: 'Kamal Ataturk Ave',
        subThoroughfare: '12',
        subLocality: 'Banani',
        locality: 'Dhaka',
      );

      final result = LocationService.formatPlacemark(placemark);
      expect(result, '12 Kamal Ataturk Ave, Banani, Dhaka');
    });

    test('formatPlacemark falls back gracefully when fields are sparse', () {
      const placemark = Placemark(
        subLocality: 'Mirpur',
        locality: 'Dhaka',
      );

      final result = LocationService.formatPlacemark(placemark);
      expect(result, 'Mirpur, Dhaka');
    });

    test('formatPlacemark returns Unknown Location when empty', () {
      const placemark = Placemark();
      final result = LocationService.formatPlacemark(placemark);
      expect(result, 'Unknown Location');
    });
  });

  group('LocationResult Status Tests', () {
    test('Loading status returns correct boolean flags', () {
      final result = LocationResult.loading();
      expect(result.isLoading, isTrue);
      expect(result.isSuccess, isFalse);
      expect(result.isPermissionDenied, isFalse);
      expect(result.isServiceDisabled, isFalse);
    });

    test('Service disabled returns correct flag', () {
      final result = LocationResult.serviceDisabled();
      expect(result.isServiceDisabled, isTrue);
      expect(result.isLoading, isFalse);
      expect(result.isSuccess, isFalse);
    });

    test('Permission denied returns correct flags', () {
      final denied = LocationResult.permissionDenied(permanently: false);
      expect(denied.isPermissionDenied, isTrue);
      expect(denied.isPermanentlyDenied, isFalse);

      final permDenied = LocationResult.permissionDenied(permanently: true);
      expect(permDenied.isPermissionDenied, isTrue);
      expect(permDenied.isPermanentlyDenied, isTrue);
    });
  });
}
