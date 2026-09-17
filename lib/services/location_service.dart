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

  const LocationModel({
    required this.latitude,
    required this.longitude,
    required this.formattedAddress,
    required this.formattedCoordinates,
    this.placemark,
    required this.timestamp,
  });

  /// Factory helper to build [LocationModel] from a [Position] and an optional [Placemark].
  factory LocationModel.fromPosition(Position position, {Placemark? placemark}) {
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
    );
  }

  @override
  String toString() {
    return 'LocationModel(address: $formattedAddress, coords: $formattedCoordinates, lat: $latitude, lng: $longitude)';
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

  /// Complete GPS acquisition and reverse-geocoding lifecycle:
  ///
  /// - Step A: Check if device location services (GPS) are enabled.
  /// - Step B: Check and request runtime location permissions.
  /// - Step C: Fetch high accuracy [Position] with fallback to [Geolocator.getLastKnownPosition].
  /// - Step D: Reverse-geocode coordinates via [placemarkFromCoordinates].
  /// - Step E: Build cleanly formatted [LocationModel] and update listeners.
  Future<LocationResult> getCurrentLocation({bool requestPermission = true}) async {
    locationNotifier.value = LocationResult.loading();

    // ── Step A: Verify if location services are enabled on device ──
    final bool isServiceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isServiceEnabled) {
      final result = LocationResult.serviceDisabled();
      locationNotifier.value = result;
      return result;
    }

    // ── Step B: Check & request runtime location permissions ──
    LocationPermission permission = await Geolocator.checkPermission();
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

    // ── Step C: Fetch high accuracy position (with last-known fallback) ──
    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (e) {
      debugPrint('[LocationService] Live location fetch error: $e. Attempting last known fallback.');
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (lastErr) {
        debugPrint('[LocationService] Fallback position also failed: $lastErr');
      }
    }

    if (position == null) {
      final result = LocationResult.error(
        'Unable to detect GPS position. Please ensure GPS signal is available.',
      );
      locationNotifier.value = result;
      return result;
    }

    // ── Step D & E: Reverse Geocode & Format Result ──
    Placemark? placemark;
    try {
      final List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty) {
        placemark = placemarks.first;
      }
    } catch (geoError) {
      debugPrint('[LocationService] Reverse geocoding failed: $geoError');
      // Graceful degradation: Coordinates are still available even if geocoding service is offline
    }

    final locationModel = LocationModel.fromPosition(position, placemark: placemark);
    _cachedLocation = locationModel;

    final result = LocationResult.success(locationModel);
    locationNotifier.value = result;
    return result;
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
