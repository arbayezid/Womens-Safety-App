import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Comprehensive Permission Status Report model.
class PermissionReport {
  final bool locationPrecise;
  final bool locationCoarse;
  final bool bluetoothConnect;
  final bool bluetoothScan;
  final bool notifications;
  final bool sms;

  const PermissionReport({
    required this.locationPrecise,
    required this.locationCoarse,
    required this.bluetoothConnect,
    required this.bluetoothScan,
    required this.notifications,
    required this.sms,
  });

  bool get isLocationGranted => locationPrecise || locationCoarse;
  bool get isBluetoothGranted => bluetoothConnect && bluetoothScan;

  @override
  String toString() {
    return 'PermissionReport(location: [precise: $locationPrecise, coarse: $locationCoarse], '
        'bluetooth: [connect: $bluetoothConnect, scan: $bluetoothScan], '
        'notifications: $notifications, sms: $sms)';
  }
}

/// Unified, cross-version runtime permission manager supporting Android 9 (API 28)
/// through Android 14+ (API 34+) and modern OEM skins (Samsung One UI, Xiaomi HyperOS, etc.).
///
/// Handles Android 12+ Bluetooth runtime permissions (BLUETOOTH_CONNECT, BLUETOOTH_SCAN),
/// Android 12+ Coarse vs Precise location, Android 13+ Notification permissions, and SMS dispatch.
class AppPermissionService {
  AppPermissionService._internal();

  /// Central singleton instance
  static final AppPermissionService instance = AppPermissionService._internal();

  /// Check whether the current platform is Android
  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// Requests all essential permissions needed by Woman Guard upon first launch
  /// or when triggered from onboarding / settings.
  Future<PermissionReport> requestEssentialPermissions() async {
    final List<Permission> permissionsToRequest = [
      Permission.location,
      Permission.sms,
    ];

    if (isAndroid) {
      // Android 13+ (API 33+) requires runtime notification permission
      permissionsToRequest.add(Permission.notification);

      // Android 12+ (API 31+) requires runtime Bluetooth Connect & Scan
      permissionsToRequest.add(Permission.bluetoothConnect);
      permissionsToRequest.add(Permission.bluetoothScan);
    }

    try {
      final Map<Permission, PermissionStatus> statuses =
          await permissionsToRequest.request();

      debugPrint('[AppPermissionService] Permission request results:');
      statuses.forEach((perm, status) {
        debugPrint('  - ${perm.toString()}: ${status.name}');
      });
    } catch (e) {
      debugPrint('[AppPermissionService] Error during batch permission request: $e');
    }

    return getPermissionReport();
  }

  /// Verifies and requests Bluetooth permissions safely across Android versions:
  /// - Android 12+ (API 31+): Requires BLUETOOTH_CONNECT and BLUETOOTH_SCAN.
  /// - Android 9 - 11 (API 28 - 30): Requires ACCESS_FINE_LOCATION or ACCESS_COARSE_LOCATION for BLE discovery.
  Future<bool> checkAndRequestBluetoothPermissions() async {
    if (!isAndroid) return true;

    try {
      // 1. Android 12+ check
      final connectStatus = await Permission.bluetoothConnect.status;
      final scanStatus = await Permission.bluetoothScan.status;

      if (connectStatus.isGranted && scanStatus.isGranted) {
        return true;
      }

      // Request Android 12+ permissions
      final results = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();

      final connectGranted = results[Permission.bluetoothConnect]?.isGranted ?? false;
      final scanGranted = results[Permission.bluetoothScan]?.isGranted ?? false;

      // If granted on Android 12+, we are good
      if (connectGranted && scanGranted) {
        return true;
      }

      // 2. On legacy Android (<= API 30), Permission.bluetoothConnect/scan may return
      // denied or not applicable; BLE discovery relies on Location permission instead.
      final locationStatus = await Permission.location.status;
      if (locationStatus.isGranted) {
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[AppPermissionService] Bluetooth permission check exception: $e');
      return false;
    }
  }

  /// Verifies whether Bluetooth permissions are currently granted without prompting.
  Future<bool> hasBluetoothPermission() async {
    if (!isAndroid) return true;

    try {
      final connect = await Permission.bluetoothConnect.isGranted;
      final scan = await Permission.bluetoothScan.isGranted;
      if (connect && scan) return true;

      // Legacy fallback
      final location = await Permission.location.isGranted;
      return location;
    } catch (_) {
      return false;
    }
  }

  /// Verifies and requests Location permissions (Fine & Coarse).
  Future<bool> checkAndRequestLocationPermission() async {
    try {
      final status = await Permission.location.status;
      if (status.isGranted) return true;

      final result = await Permission.location.request();
      return result.isGranted;
    } catch (e) {
      debugPrint('[AppPermissionService] Location permission request error: $e');
      return false;
    }
  }

  /// Verifies and requests Notification permission (Android 13+).
  Future<bool> checkAndRequestNotificationPermission() async {
    if (!isAndroid) return true;

    try {
      final status = await Permission.notification.status;
      if (status.isGranted) return true;

      final result = await Permission.notification.request();
      return result.isGranted;
    } catch (e) {
      debugPrint('[AppPermissionService] Notification permission request error: $e');
      return false;
    }
  }

  /// Verifies and requests direct SMS dispatch permission.
  Future<bool> checkAndRequestSmsPermission() async {
    try {
      final status = await Permission.sms.status;
      if (status.isGranted) return true;

      final result = await Permission.sms.request();
      return result.isGranted;
    } catch (e) {
      debugPrint('[AppPermissionService] SMS permission request error: $e');
      return false;
    }
  }

  /// Compiles a comprehensive diagnostic report of all permission states.
  Future<PermissionReport> getPermissionReport() async {
    bool locationPrecise = false;
    bool locationCoarse = false;
    bool bluetoothConnect = false;
    bool bluetoothScan = false;
    bool notifications = false;
    bool sms = false;

    try {
      locationPrecise = await Permission.location.isGranted;
      locationCoarse = await Permission.locationWhenInUse.isGranted || locationPrecise;

      if (isAndroid) {
        bluetoothConnect = await Permission.bluetoothConnect.isGranted;
        bluetoothScan = await Permission.bluetoothScan.isGranted;
        notifications = await Permission.notification.isGranted;
      } else {
        bluetoothConnect = true;
        bluetoothScan = true;
        notifications = true;
      }

      sms = await Permission.sms.isGranted;
    } catch (e) {
      debugPrint('[AppPermissionService] Error building permission report: $e');
    }

    return PermissionReport(
      locationPrecise: locationPrecise,
      locationCoarse: locationCoarse,
      bluetoothConnect: bluetoothConnect,
      bluetoothScan: bluetoothScan,
      notifications: notifications,
      sms: sms,
    );
  }

  /// Opens system app settings for manual permission granting.
  Future<bool> openSettings() async {
    return openAppSettings();
  }
}
