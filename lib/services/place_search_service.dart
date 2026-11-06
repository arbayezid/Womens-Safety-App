import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// One place offered while the user types a destination.
class PlaceSuggestion {
  final String name;

  /// Area / city line under the name, e.g. "Shah Ali Bagh, Dhaka".
  final String subtitle;
  final double latitude;
  final double longitude;

  /// OpenStreetMap category (e.g. "amenity:hospital", "place:quarter"); picks the list icon.
  final String category;

  /// True for the app's own safe zones (hospitals, police stations) rather than map search.
  final bool isSafeZone;

  const PlaceSuggestion({
    required this.name,
    required this.subtitle,
    required this.latitude,
    required this.longitude,
    this.category = '',
    this.isSafeZone = false,
  });

  LatLng get point => LatLng(latitude, longitude);
}

/// Search-as-you-type for destinations.
///
/// Uses Photon (photon.komoot.io), a free OpenStreetMap search built for autocomplete. The
/// Android geocoder gave wrong places for Dhaka names (e.g. "Mirpur-1" landed near the airport)
/// and Nominatim's usage policy forbids autocomplete. Google Places would need a billed
/// Google Cloud project.
class PlaceSearchService {
  PlaceSearchService._();
  static final PlaceSearchService instance = PlaceSearchService._();

  static const String _endpoint = 'https://photon.komoot.io/api/';
  static const Duration _timeout = Duration(seconds: 6);

  /// Bangladesh, so a short query never jumps to another country.
  static const String _bangladeshBbox = '88.0,20.5,92.7,26.7';

  /// Places matching [query], closest to [near] first in Photon's ranking. Empty when offline.
  Future<List<PlaceSuggestion>> search(String query, {LatLng? near, int limit = 8}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final params = <String, String>{
      'q': q,
      'limit': '$limit',
      'lang': 'en',
      'bbox': _bangladeshBbox,
      if (near != null) 'lat': near.latitude.toStringAsFixed(5),
      if (near != null) 'lon': near.longitude.toStringAsFixed(5),
    };
    final uri = Uri.parse(_endpoint).replace(queryParameters: params);

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'WomanGuard-SafeJourney/1.0');
      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('[PlaceSearch] HTTP ${response.statusCode}');
        return const [];
      }
      return parsePhotonResponse(body);
    } catch (e) {
      debugPrint('[PlaceSearch] Search failed: $e');
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// Parses a Photon GeoJSON response into suggestions, dropping duplicates. Pure, for tests.
  static List<PlaceSuggestion> parsePhotonResponse(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final features = json['features'] as List? ?? const [];
      final seen = <String>{};
      final results = <PlaceSuggestion>[];
      for (final f in features) {
        if (f is! Map) continue;
        final props = (f['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
        final coords = (f['geometry'] as Map?)?['coordinates'] as List?;
        if (coords == null || coords.length < 2) continue;
        final lng = (coords[0] as num).toDouble();
        final lat = (coords[1] as num).toDouble();

        final street = props['street']?.toString();
        final houseNumber = props['housenumber']?.toString();
        final name = props['name']?.toString() ??
            (street != null ? [houseNumber, street].whereType<String>().join(' ') : null);
        if (name == null || name.trim().isEmpty) continue;

        final subtitle = _subtitle(props, name);
        if (!seen.add('${name.toLowerCase()}|${subtitle.toLowerCase()}')) continue;

        results.add(PlaceSuggestion(
          name: name.trim(),
          subtitle: subtitle,
          latitude: lat,
          longitude: lng,
          category: '${props['osm_key'] ?? ''}:${props['osm_value'] ?? ''}',
        ));
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  /// "Street, Area, City" without repeating the place's own name.
  static String _subtitle(Map<String, dynamic> props, String name) {
    final parts = <String>[];
    for (final key in ['street', 'district', 'locality', 'city', 'county', 'state']) {
      final v = props[key]?.toString().trim();
      if (v == null || v.isEmpty) continue;
      if (name.toLowerCase().contains(v.toLowerCase())) continue; // already in the name
      if (parts.any((p) => p.toLowerCase() == v.toLowerCase())) continue;
      parts.add(v);
      if (parts.length == 3) break;
    }
    return parts.join(', ');
  }
}
