import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../models/safe_zone_model.dart';

/// Central repository managing physical safe zones (police stations, hospitals, metro stations)
/// loaded from assets and providing consistent distance calculations across all app screens.
class SafeZoneRepository {
  SafeZoneRepository._internal();

  /// Central singleton instance
  static final SafeZoneRepository instance = SafeZoneRepository._internal();

  List<SafeZone>? _cachedSafeZones;
  bool _isLoading = false;

  // Distance cache to avoid redundant distance recalculation on micro-movements (< 50m)
  double? _lastCalcLat;
  double? _lastCalcLng;
  List<SafeZone> _lastSortedZones = [];

  /// In-memory catalog of all loaded safe zones, or default Dhaka fallback catalog
  /// if database loading has not finished yet.
  List<SafeZone> get allSafeZones => _cachedSafeZones ?? SafeZone.defaultDhakaSafeZones;

  /// Loads safe zones from `assets/data/safe_zones.json` into memory.
  Future<List<SafeZone>> loadSafeZones() async {
    if (_cachedSafeZones != null && _cachedSafeZones!.isNotEmpty) {
      return _cachedSafeZones!;
    }
    if (_isLoading) {
      return allSafeZones;
    }

    _isLoading = true;
    try {
      final jsonString = await rootBundle.loadString('assets/data/safe_zones.json');
      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;
      final List<SafeZone> loaded = jsonList
          .map((item) => SafeZone.fromJson(item as Map<String, dynamic>))
          .toList();

      if (loaded.isNotEmpty) {
        _cachedSafeZones = loaded;
        debugPrint('[SafeZoneRepo] Successfully loaded ${loaded.length} safe zones from database.');
      } else {
        _cachedSafeZones = SafeZone.defaultDhakaSafeZones;
      }
    } catch (e) {
      debugPrint('[SafeZoneRepo] Database load notice ($e). Using default catalog.');
      _cachedSafeZones = SafeZone.defaultDhakaSafeZones;
    } finally {
      _isLoading = false;
    }

    return _cachedSafeZones!;
  }

  /// Calculates distances and returns safe zones sorted ascending by distance from [curLat, curLng].
  ///
  /// Optionally filters by [filterType] (e.g. [SafeZoneType.police]).
  /// Uses a 50-meter movement threshold to prevent jitter and unnecessary recalculations.
  List<SafeZone> getSortedSafeZones({
    required double curLat,
    required double curLng,
    SafeZoneType? filterType,
  }) {
    final catalog = allSafeZones;

    // Check if previous calculation is within 50 meters
    final bool canReuse = _lastCalcLat != null &&
        _lastCalcLng != null &&
        _lastSortedZones.isNotEmpty &&
        Geolocator.distanceBetween(_lastCalcLat!, _lastCalcLng!, curLat, curLng) < 50.0;

    List<SafeZone> sorted;
    if (canReuse) {
      sorted = _lastSortedZones;
    } else {
      sorted = List<SafeZone>.from(catalog);
      sorted.sort((a, b) {
        final distA = Geolocator.distanceBetween(curLat, curLng, a.latitude, a.longitude);
        final distB = Geolocator.distanceBetween(curLat, curLng, b.latitude, b.longitude);
        return distA.compareTo(distB);
      });
      _lastCalcLat = curLat;
      _lastCalcLng = curLng;
      _lastSortedZones = sorted;
    }

    if (filterType != null) {
      return sorted.where((z) => z.type == filterType).toList();
    }
    return sorted;
  }

  /// Retrieves the single nearest Police Station or Checkpoint from [curLat, curLng].
  SafeZone? getNearestPoliceStation({
    required double curLat,
    required double curLng,
  }) {
    final sortedPolice = getSortedSafeZones(
      curLat: curLat,
      curLng: curLng,
      filterType: SafeZoneType.police,
    );
    return sortedPolice.isNotEmpty ? sortedPolice.first : null;
  }

  /// Retrieves the top [count] nearest safe zones of any type from [curLat, curLng].
  List<SafeZone> getNearestSafeZones({
    required double curLat,
    required double curLng,
    int count = 3,
    SafeZoneType? filterType,
  }) {
    final sorted = getSortedSafeZones(
      curLat: curLat,
      curLng: curLng,
      filterType: filterType,
    );
    return sorted.take(count).toList();
  }

  /// Determines whether user movement has exceeded the 50-meter threshold.
  bool shouldRecalculate(double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2) >= 50.0;
  }

  /// Injects safe zones into cache for unit testing.
  @visibleForTesting
  void setCachedSafeZonesForTesting(List<SafeZone> zones) {
    _cachedSafeZones = zones;
    _lastCalcLat = null;
    _lastCalcLng = null;
    _lastSortedZones = [];
  }
}
