import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// How the user is travelling on a Safe Journey.
enum JourneyTravelMode {
  walking,
  vehicle;

  static JourneyTravelMode fromName(String? name) =>
      name == JourneyTravelMode.vehicle.name ? JourneyTravelMode.vehicle : JourneyTravelMode.walking;
}

/// A road route between two points.
class JourneyRoute {
  /// Encoded polyline (precision 5), the compact form stored in Firestore.
  final String polyline;
  final double distanceMeters;

  /// Expected travel time, including the traffic buffer for vehicles.
  final int durationSeconds;
  final JourneyTravelMode mode;

  const JourneyRoute({
    required this.polyline,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.mode,
  });

  List<LatLng> get points => RouteService.decodePolyline(polyline);

  /// Whole minutes, rounded up, never below 1.
  int get durationMinutes => math.max(1, (durationSeconds / 60).ceil());

  Map<String, dynamic> toMap() => {
        'polyline': polyline,
        'distanceMeters': distanceMeters,
        'durationSeconds': durationSeconds,
        'mode': mode.name,
        'provider': RouteService.providerName,
      };

  static JourneyRoute? fromMap(Map<String, dynamic>? map) {
    final polyline = map?['polyline'];
    if (polyline is! String || polyline.isEmpty) return null;
    return JourneyRoute(
      polyline: polyline,
      distanceMeters: (map!['distanceMeters'] as num?)?.toDouble() ?? 0,
      durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
      mode: JourneyTravelMode.fromName(map['mode']?.toString()),
    );
  }
}

/// Road routing and travel-time estimates for Safe Journey.
///
/// Uses the free OpenStreetMap routing service (OSRM, run by FOSSGIS), which matches the
/// OpenStreetMap tiles the app already shows. Google's Directions/Routes API would need a
/// billed Google Cloud project, which this project does not have.
class RouteService {
  RouteService._();
  static final RouteService instance = RouteService._();

  static const String providerName = 'osrm';
  static const String _baseUrl = 'https://routing.openstreetmap.de';
  static const Duration _timeout = Duration(seconds: 8);

  /// OSRM car times assume empty roads. Dhaka traffic is far slower; an ETA that is too short
  /// sets off the "are you safe?" check (and auto-SOS) while the user is still on the way.
  static const double vehicleTrafficFactor = 2.0;

  /// Road route from [from] to [to], or null when offline or no route was found.
  Future<JourneyRoute?> fetchRoute({
    required LatLng from,
    required LatLng to,
    required JourneyTravelMode mode,
  }) async {
    final profile = mode == JourneyTravelMode.vehicle ? 'routed-car' : 'routed-foot';
    final uri = Uri.parse(
      '$_baseUrl/$profile/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
      '?overview=full&geometries=polyline&steps=false&alternatives=false',
    );

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'WomanGuard-SafeJourney/1.0');
      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('[RouteService] HTTP ${response.statusCode} for $profile route');
        return null;
      }
      return parseOsrmResponse(body, mode);
    } catch (e) {
      debugPrint('[RouteService] Route request failed: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Parses an OSRM `route` response. Pure, for tests.
  static JourneyRoute? parseOsrmResponse(String body, JourneyTravelMode mode) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') return null;
      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;
      final route = routes.first as Map<String, dynamic>;
      final geometry = route['geometry'];
      if (geometry is! String || geometry.isEmpty) return null;
      final rawSeconds = (route['duration'] as num?)?.toDouble() ?? 0;
      final factor = mode == JourneyTravelMode.vehicle ? vehicleTrafficFactor : 1.0;
      return JourneyRoute(
        polyline: geometry,
        distanceMeters: (route['distance'] as num?)?.toDouble() ?? 0,
        durationSeconds: (rawSeconds * factor).round(),
        mode: mode,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Pure geometry helpers (unit-tested) ─────────────────────────────────────

  /// Decodes a Google/OSRM encoded polyline (precision 5).
  static List<LatLng> decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int shift = 0, result = 0, b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      shift = 0;
      result = 0;
      if (index >= encoded.length) break;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  /// Shortest distance in meters from a point to the route line.
  static double distanceToRouteMeters(double lat, double lng, List<LatLng> route) {
    return _nearestOnRoute(lat, lng, route).distance;
  }

  /// Distance left to travel along the route from the point's nearest position on it.
  /// Includes the gap between the point and the route.
  static double remainingRouteMeters(double lat, double lng, List<LatLng> route) {
    if (route.isEmpty) return 0;
    if (route.length == 1) return _meters(lat, lng, route.first.latitude, route.first.longitude);
    final nearest = _nearestOnRoute(lat, lng, route);
    final seg = nearest.segment;
    final a = route[seg], b = route[seg + 1];
    final segLen = _meters(a.latitude, a.longitude, b.latitude, b.longitude);
    double remaining = nearest.distance + segLen * (1 - nearest.t);
    for (int i = seg + 1; i < route.length - 1; i++) {
      remaining += _meters(route[i].latitude, route[i].longitude, route[i + 1].latitude, route[i + 1].longitude);
    }
    return remaining;
  }

  static ({double distance, int segment, double t}) _nearestOnRoute(double lat, double lng, List<LatLng> route) {
    if (route.isEmpty) return (distance: double.infinity, segment: 0, t: 0);
    if (route.length == 1) {
      return (distance: _meters(lat, lng, route.first.latitude, route.first.longitude), segment: 0, t: 0);
    }
    // Local flat projection around the point: accurate to well under 1% at city scale.
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(lat * math.pi / 180);
    double best = double.infinity;
    int bestSeg = 0;
    double bestT = 0;
    for (int i = 0; i < route.length - 1; i++) {
      final ax = (route[i].longitude - lng) * mPerDegLng, ay = (route[i].latitude - lat) * mPerDegLat;
      final bx = (route[i + 1].longitude - lng) * mPerDegLng, by = (route[i + 1].latitude - lat) * mPerDegLat;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
      final px = ax + t * dx, py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      if (d < best) {
        best = d;
        bestSeg = i;
        bestT = t;
      }
    }
    return (distance: best, segment: bestSeg, t: bestT);
  }

  static double _meters(double lat1, double lng1, double lat2, double lng2) =>
      const Distance().as(LengthUnit.Meter, LatLng(lat1, lng1), LatLng(lat2, lng2));
}
