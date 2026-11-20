import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

/// Keeps GPS warm while the app is on screen, so an SOS can text an accurate location the
/// moment the button is pressed instead of waiting for GPS to lock on.
///
/// Runs only while the app is in the foreground (battery), and only once location permission
/// has been granted: it never asks for permission itself.
class SosLocationWarmer with WidgetsBindingObserver {
  SosLocationWarmer._internal();
  static final SosLocationWarmer instance = SosLocationWarmer._internal();

  StreamSubscription<Position>? _sub;
  Position? _latest;
  bool _initialized = false;

  /// Most accurate recent fix: a newer fix replaces it unless it is much less accurate.
  Position? get latestFix => _latest;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _stop();
    }
  }

  Future<void> _start() async {
    if (_sub != null) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) {
        return;
      }
      if (_sub != null) return;
      _sub = Geolocator.getPositionStream(locationSettings: _settings()).listen(
        _onFix,
        onError: (Object e) {
          debugPrint('[SosLocationWarmer] GPS stream stopped: $e');
          _stop();
        },
      );
      debugPrint('[SosLocationWarmer] GPS warm-up started');
    } catch (e) {
      debugPrint('[SosLocationWarmer] Could not start GPS warm-up: $e');
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
  }

  void _onFix(Position p) {
    final current = _latest;
    final currentAge = current == null ? null : DateTime.now().difference(current.timestamp);
    // Take the new fix if there is none, the old one is getting stale, or it is not worse
    // than ~1.5x the old accuracy (a GPS fix should not be replaced by a Wi-Fi guess).
    if (current == null ||
        currentAge! > const Duration(seconds: 20) ||
        p.accuracy <= current.accuracy * 1.5) {
      _latest = p;
    }
  }

  static const MethodChannel _deviceChannel = MethodChannel('com.smartsafety.smart_safety/device');

  /// The phone's last fix from the real GPS chip (Android), however old, or null.
  Future<Position?> lastGpsFix() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _deviceChannel.invokeMapMethod<String, dynamic>('lastGpsFix');
      if (raw == null) return null;
      final ageMs = (raw['ageMs'] as num).toInt();
      return Position(
        latitude: (raw['latitude'] as num).toDouble(),
        longitude: (raw['longitude'] as num).toDouble(),
        accuracy: (raw['accuracy'] as num).toDouble(),
        timestamp: DateTime.now().subtract(Duration(milliseconds: ageMs)),
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        hasAccuracy: true,
      );
    } catch (e) {
      debugPrint('[SosLocationWarmer] Last GPS fix unavailable: $e');
      return null;
    }
  }

  LocationSettings _settings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        intervalDuration: const Duration(seconds: 5),
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }
}
