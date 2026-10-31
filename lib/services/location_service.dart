import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// Represents the high-level status of location extraction.
enum LocationStateStatus {
  initial,
  loading,
  hasData,
  permissionDenied,
  serviceDisabled,
  error,
}

/// Structured location model holding geographical coordinates and
/// human-readable reverse-geocoded address segments.
class LocationModel {
  final double latitude;
  final double longitude;
  final String formattedAddress;
  final String formattedCoordinates;
  final Placemark? placemark;
  final DateTime timestamp;
  final bool isApproximate;

  const LocationModel({
    required this.latitude,
    required this.longitude,
    required this.formattedAddress,
    required this.formattedCoordinates,
    this.placemark,
    required this.timestamp,
    this.isApproximate = false,
  });

  /// Factory helper to build [LocationModel] from a [Position] and an optional [Placemark].
  factory LocationModel.fromPosition(
    Position position, {
    Placemark? placemark,
    bool isApproximate = false,
  }) {
    final coords = LocationService.formatCoordinates(position.latitude, position.longitude);
    final address = placemark != null
        ? LocationService.formatPlacemark(placemark)
        : 'Coordinates: $coords';

    return LocationModel(
      latitude: position.latitude,
      longitude: position.longitude,
      formattedAddress: address,
      formattedCoordinates: coords,
      placemark: placemark,
      timestamp: DateTime.now(),
      isApproximate: isApproximate,
    );
  }

  @override
  String toString() {
    return 'LocationModel(address: $formattedAddress, coords: $formattedCoordinates, lat: $latitude, lng: $longitude, approx: $isApproximate)';
  }
}

/// Result envelope returned by [LocationService.getCurrentLocation].
class LocationResult {
  final LocationStateStatus status;
  final LocationModel? data;
  final String? errorMessage;
  final bool isPermanentlyDenied;

  const LocationResult({
    required this.status,
    this.data,
    this.errorMessage,
    this.isPermanentlyDenied = false,
  });

  factory LocationResult.loading() => const LocationResult(status: LocationStateStatus.loading);

  factory LocationResult.success(LocationModel data) =>
      LocationResult(status: LocationStateStatus.hasData, data: data);

  factory LocationResult.permissionDenied({bool permanently = false, String? message}) =>
      LocationResult(
        status: LocationStateStatus.permissionDenied,
        isPermanentlyDenied: permanently,
        errorMessage: message ??
            (permanently
                ? 'Location permission is permanently denied. Please enable it in App Settings.'
                : 'Location permission was denied.'),
      );

  factory LocationResult.serviceDisabled({String? message}) => LocationResult(
        status: LocationStateStatus.serviceDisabled,
        errorMessage: message ?? 'Device GPS location service is turned off.',
      );

  factory LocationResult.error(String message) => LocationResult(
        status: LocationStateStatus.error,
        errorMessage: message,
      );

  bool get isSuccess => status == LocationStateStatus.hasData && data != null;
  bool get isLoading => status == LocationStateStatus.loading;
  bool get isPermissionDenied => status == LocationStateStatus.permissionDenied;
  bool get isServiceDisabled => status == LocationStateStatus.serviceDisabled;
}

/// Service dedicated to handling device GPS lifecycle, runtime permissions,
/// coordinate extraction, and reverse geocoding to human-readable addresses.
///
/// **Android 12+ / 13+ / 14+ Hardened:**
/// - Defensively supports Android 12 Approximate Location (`ACCESS_COARSE_LOCATION`)
///   by gracefully downgrading accuracy rather than crashing with `SecurityException`.
/// - Catches `IOException` and Google Play Services timeout errors during reverse-geocoding.
/// - Never crashes the UI thread with null dereferences when GPS returns `null`.
class LocationService {
  LocationService._internal();

  /// Central singleton instance
  static final LocationService instance = LocationService._internal();

  /// In-memory cached result of the most recent location check
  LocationModel? _cachedLocation;

  /// Observable notifier broadcasting the latest [LocationResult]
  final ValueNotifier<LocationResult> locationNotifier =
      ValueNotifier<LocationResult>(const LocationResult(status: LocationStateStatus.initial));

  /// Returns the latest cached [LocationModel], if any.
  LocationModel? get lastKnownLocation => _cachedLocation;

  /// Formats raw decimal coordinates into a human-readable string (e.g. 23.8103° N, 90.4125° E).
  static String formatCoordinates(double lat, double lng) {
    if (lat.isNaN || lng.isNaN) return 'Coordinates unavailable';
    final latDir = lat >= 0 ? 'N' : 'S';
    final lngDir = lng >= 0 ? 'E' : 'W';
    final latVal = lat.abs().toStringAsFixed(4);
    final lngVal = lng.abs().toStringAsFixed(4);
    return '$latVal° $latDir, $lngVal° $lngDir';
  }

  /// Extracts and formats human-readable address components cleanly:
  /// street, subLocality, locality / subAdministrativeArea (e.g. "Road 10, Mirpur, Dhaka").
  static String formatPlacemark(Placemark place) {
    final List<String> segments = [];

    // 1. Street or thoroughfare or name
    final street = place.street?.trim();
    final thoroughfare = place.thoroughfare?.trim();
    final subThoroughfare = place.subThoroughfare?.trim();
    final name = place.name?.trim();

    String? primaryRoad;
    // Discard plus-codes like "Q9XR+23"
    if (street != null && street.isNotEmpty && !street.contains('+')) {
      primaryRoad = street;
    } else if (thoroughfare != null && thoroughfare.isNotEmpty) {
      primaryRoad = (subThoroughfare != null && subThoroughfare.isNotEmpty)
          ? '$subThoroughfare $thoroughfare'
          : thoroughfare;
    } else if (name != null && name.isNotEmpty && !name.contains('+')) {
      primaryRoad = name;
    }

    if (primaryRoad != null && primaryRoad.isNotEmpty) {
      segments.add(primaryRoad);
    }

    // 2. SubLocality (e.g., Banani, Mirpur, Gulshan)
    final subLocality = place.subLocality?.trim();
    if (subLocality != null && subLocality.isNotEmpty) {
      final targetSubLocality = subLocality.toLowerCase();
      if (!segments.any((s) => s.toLowerCase() == targetSubLocality)) {
        segments.add(subLocality);
      }
    }

    // 3. Locality or SubAdministrativeArea (e.g., Dhaka)
    final locality = place.locality?.trim();
    final subAdmin = place.subAdministrativeArea?.trim();
    final admin = place.administrativeArea?.trim();

    String? city;
    if (locality != null && locality.isNotEmpty) {
      city = locality;
    } else if (subAdmin != null && subAdmin.isNotEmpty) {
      city = subAdmin;
    } else if (admin != null && admin.isNotEmpty) {
      city = admin;
    }

    if (city != null && city.isNotEmpty) {
      final targetCity = city.toLowerCase();
      if (!segments.any((s) => s.toLowerCase() == targetCity)) {
        segments.add(city);
      }
    }

    if (segments.isEmpty) {
      if (name != null && name.isNotEmpty) return name;
      return 'Unknown Location';
    }

    return segments.join(', ');
  }

  /// Complete, defensive GPS acquisition and reverse-geocoding lifecycle:
  ///
  /// - Step A: Check if device location services (GPS) are enabled.
  /// - Step B: Check and request runtime location permissions (handling Android 12+ Approximate location).
  /// - Step C: Fetch position with multi-tiered fallback (High Accuracy -> Balanced Accuracy -> Last Known Position).
  /// - Step D: Reverse-geocode coordinates with strict timeout and fallback to formatted coordinate string.
  /// - Step E: Build non-null [LocationModel] and update listeners safely.
  Future<LocationResult> getCurrentLocation({bool requestPermission = true}) async {
    locationNotifier.value = LocationResult.loading();

    // ── Step A: Verify if location services are enabled on device ──
    bool isServiceEnabled = false;
    try {
      isServiceEnabled = await Geolocator.isLocationServiceEnabled()
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    } catch (e) {
      debugPrint('[LocationService] isLocationServiceEnabled check notice: $e');
    }

    if (!isServiceEnabled) {
      final result = LocationResult.serviceDisabled();
      locationNotifier.value = result;
      return result;
    }

    // ── Step B: Check & request runtime location permissions ──
    LocationPermission permission = LocationPermission.denied;
    try {
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (requestPermission) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied) {
          final result = LocationResult.permissionDenied(permanently: false);
          locationNotifier.value = result;
          return result;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        final result = LocationResult.permissionDenied(permanently: true);
        locationNotifier.value = result;
        return result;
      }
    } catch (permErr) {
      debugPrint('[LocationService] Permission check error: $permErr');
    }

    // ── Step C: Multi-tier position acquisition (Safe for Android 12 Approximate Location) ──
    Position? position;
    bool isApproximate = false;

    // Attempt 1: High accuracy GPS
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (highAccErr) {
      debugPrint('[LocationService] High-accuracy GPS acquisition failed/restricted: $highAccErr');

      // Attempt 2: Medium/Balanced accuracy (crucial for Android 12 Approximate Location permission)
      try {
        isApproximate = true;
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 5),
          ),
        );
      } catch (mediumAccErr) {
        debugPrint('[LocationService] Medium accuracy fallback failed: $mediumAccErr');

        // Attempt 3: Cached last-known position
        try {
          position = await Geolocator.getLastKnownPosition();
        } catch (lastErr) {
          debugPrint('[LocationService] Last-known fallback failed: $lastErr');
        }
      }
    }

    // Defensive check: If position is still null, do not crash
    if (position == null) {
      final result = LocationResult.error(
        'GPS position currently unavailable. Please verify GPS signal or try again.',
      );
      locationNotifier.value = result;
      return result;
    }

    // ── Step D: Defensive Reverse Geocode with isolated timeout ──
    Placemark? placemark;
    try {
      final List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      ).timeout(const Duration(seconds: 3), onTimeout: () => <Placemark>[]);

      if (placemarks.isNotEmpty) {
        placemark = placemarks.first;
      }
    } catch (geoError) {
      // Graceful degradation: Coordinates are always safely available even if geocoding fails
      debugPrint('[LocationService] Reverse geocoding service notice: $geoError');
    }

    // ── Step E: Build complete non-null LocationModel ──
    final locationModel = LocationModel.fromPosition(
      position,
      placemark: placemark,
      isApproximate: isApproximate,
    );
    _cachedLocation = locationModel;

    final result = LocationResult.success(locationModel);
    locationNotifier.value = result;
    return result;
  }

  /// Continuous position stream for map and tracking screens with graceful error handling.
  Stream<Position> get positionStream => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).handleError((err) {
        debugPrint('[LocationService] Position stream error caught: $err');
      });

  final Map<String, String> _geocodeCache = {};

  /// Quickly fetches the device's current high-accuracy position with fallback
  /// to balanced accuracy and last-known position.
  Future<Position?> getCurrentPositionHighAccuracy() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      );
      return pos;
    } catch (_) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 3),
          ),
        );
        return pos;
      } catch (_) {
        try {
          return await Geolocator.getLastKnownPosition();
        } catch (_) {
          return null;
        }
      }
    }
  }

  /// Performs reverse-geocoding for [lat], [lng] using the project's [geocoding] package.
  /// Returns a clean human-readable address, or formatted coordinates if geocoding fails.
  Future<String> reverseGeocode(double lat, double lng) async {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    if (_geocodeCache.containsKey(key)) {
      return _geocodeCache[key]!;
    }

    try {
      final placemarks = await placemarkFromCoordinates(lat, lng)
          .timeout(const Duration(seconds: 3), onTimeout: () => <Placemark>[]);
      if (placemarks.isNotEmpty) {
        final address = formatPlacemark(placemarks.first);
        _geocodeCache[key] = address;
        return address;
      }
    } catch (e) {
      debugPrint('[LocationService] reverseGeocode fallback: $e');
    }

    final coordsFallback = formatCoordinates(lat, lng);
    _geocodeCache[key] = coordsFallback;
    return coordsFallback;
  }

  /// Opens the native device location settings screen (GPS toggle).
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (e) {
      debugPrint('[LocationService] Error opening location settings: $e');
      return false;
    }
  }

  /// Opens the native app settings page for permission management.
  Future<bool> openAppSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (e) {
      debugPrint('[LocationService] Error opening app settings: $e');
      return false;
    }
  }
}
