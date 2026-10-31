import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'location_service.dart';

/// Supported travel modes for turn-by-turn navigation.
enum TravelMode {
  driving,
  walking,
  transit;

  String get googleMapsValue {
    switch (this) {
      case TravelMode.driving:
        return 'driving';
      case TravelMode.walking:
        return 'walking';
      case TravelMode.transit:
        return 'transit';
    }
  }

  String get appleMapsFlag {
    switch (this) {
      case TravelMode.driving:
        return 'd';
      case TravelMode.walking:
        return 'w';
      case TravelMode.transit:
        return 'r';
    }
  }

  String get androidNavMode {
    switch (this) {
      case TravelMode.driving:
        return 'd';
      case TravelMode.walking:
        return 'w';
      case TravelMode.transit:
        return 'd';
    }
  }
}

/// Centralized, production-grade navigation service that initiates turn-by-turn
/// navigation using free native device map deep links without requiring Google Directions
/// or Places API keys.
class NavigationService {
  NavigationService._internal();

  /// Central singleton instance
  static final NavigationService instance = NavigationService._internal();

  /// Automatically retrieves current GPS location and launches turn-by-turn
  /// directions to [destLat], [destLng] with multiple tiered fallbacks.
  ///
  /// Fallback cascade:
  /// 1. Primary (Android & iOS): Google Maps directions URL with origin & destination
  /// 2. Android fallback: `google.navigation:q=<destLat>,<destLng>&mode=<mode>`
  /// 3. Generic fallback: `geo:<destLat>,<destLng>?q=<destLat>,<destLng>(<label>)`
  /// 4. iOS fallback: `comgooglemaps://` or Apple Maps with origin & destination
  /// 5. Last fallback: Google Maps web URL in browser
  ///
  /// If current user location is unavailable (permission denied or GPS off), directions
  /// will still open with destination only (the map app uses its own device location).
  Future<bool> navigateTo({
    required double destLat,
    required double destLng,
    String? destLabel,
    TravelMode mode = TravelMode.driving,
  }) async {
    // 1. Attempt to obtain current user location
    double? curLat;
    double? curLng;

    try {
      final cached = LocationService.instance.lastKnownLocation;
      if (cached != null) {
        curLat = cached.latitude;
        curLng = cached.longitude;
      } else {
        final pos = await Geolocator.getLastKnownPosition()
            .timeout(const Duration(seconds: 1), onTimeout: () => null);
        if (pos != null) {
          curLat = pos.latitude;
          curLng = pos.longitude;
        } else {
          final live = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 2),
            ),
          ).timeout(const Duration(seconds: 2), onTimeout: () => throw Exception('Timeout'));
          curLat = live.latitude;
          curLng = live.longitude;
        }
      }
    } catch (e) {
      debugPrint('[NavigationService] Current location acquisition notice: $e (proceeding with destination only)');
    }

    // 2. Cascade through deep link options in order
    final List<Uri> candidateUris = [];

    // Option A: Primary Google Maps Turn-by-Turn Directions URL
    candidateUris.add(
      buildGoogleMapsDirUri(
        curLat: curLat,
        curLng: curLng,
        destLat: destLat,
        destLng: destLng,
        mode: mode,
      ),
    );

    // Option B: Android Google Navigation native scheme
    if (!kIsWeb && Platform.isAndroid) {
      candidateUris.add(
        buildAndroidNavigationUri(
          destLat: destLat,
          destLng: destLng,
          mode: mode,
        ),
      );
    }

    // Option C: Generic geo scheme supported by Android & open map clients
    candidateUris.add(
      buildGenericGeoUri(
        destLat: destLat,
        destLng: destLng,
        label: destLabel,
      ),
    );

    // Option D: iOS specific schemes (Google Maps App or Apple Maps)
    if (!kIsWeb && Platform.isIOS) {
      candidateUris.add(
        Uri.parse('comgooglemaps://?daddr=$destLat,$destLng&directionsmode=${mode.googleMapsValue}'),
      );
      candidateUris.add(
        buildAppleMapsUri(
          curLat: curLat,
          curLng: curLng,
          destLat: destLat,
          destLng: destLng,
          mode: mode,
        ),
      );
    }

    // Option E: Last fallback - Google Maps web search link in browser
    candidateUris.add(
      buildWebSearchUri(
        destLat: destLat,
        destLng: destLng,
      ),
    );

    // Attempt each candidate URI with LaunchMode.externalApplication
    for (final uri in candidateUris) {
      try {
        debugPrint('[NavigationService] Trying candidate URI: $uri');
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) {
          debugPrint('[NavigationService] Successfully launched navigation via: $uri');
          return true;
        }
      } catch (e) {
        debugPrint('[NavigationService] Candidate failed: $uri ($e)');
      }
    }

    debugPrint('[NavigationService] All navigation deep link candidates exhausted.');
    return false;
  }

  /// Builds the primary Google Maps directions URI.
  Uri buildGoogleMapsDirUri({
    double? curLat,
    double? curLng,
    required double destLat,
    required double destLng,
    TravelMode mode = TravelMode.driving,
  }) {
    if (curLat != null && curLng != null) {
      return Uri.parse(
        'https://www.google.com/maps/dir/?api=1&origin=$curLat,$curLng&destination=$destLat,$destLng&travelmode=${mode.googleMapsValue}&dir_action=navigate',
      );
    }
    return Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$destLat,$destLng&travelmode=${mode.googleMapsValue}&dir_action=navigate',
    );
  }

  /// Builds the native Android Google Navigation scheme URI.
  Uri buildAndroidNavigationUri({
    required double destLat,
    required double destLng,
    TravelMode mode = TravelMode.driving,
  }) {
    return Uri.parse('google.navigation:q=$destLat,$destLng&mode=${mode.androidNavMode}');
  }

  /// Builds the generic geo: URI supported across multiple map providers.
  Uri buildGenericGeoUri({
    required double destLat,
    required double destLng,
    String? label,
  }) {
    final encodedLabel = Uri.encodeComponent(label ?? 'Destination');
    return Uri.parse('geo:$destLat,$destLng?q=$destLat,$destLng($encodedLabel)');
  }

  /// Builds the Apple Maps URI for iOS.
  Uri buildAppleMapsUri({
    double? curLat,
    double? curLng,
    required double destLat,
    required double destLng,
    TravelMode mode = TravelMode.driving,
  }) {
    if (curLat != null && curLng != null) {
      return Uri.parse(
        'https://maps.apple.com/?saddr=$curLat,$curLng&daddr=$destLat,$destLng&dirflg=${mode.appleMapsFlag}',
      );
    }
    return Uri.parse(
      'https://maps.apple.com/?daddr=$destLat,$destLng&dirflg=${mode.appleMapsFlag}',
    );
  }

  /// Builds the fallback web search URI.
  Uri buildWebSearchUri({
    required double destLat,
    required double destLng,
  }) {
    return Uri.parse('https://www.google.com/maps/search/?api=1&query=$destLat,$destLng');
  }
}
