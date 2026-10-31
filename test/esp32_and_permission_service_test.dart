import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/esp32_ble_service.dart';
import 'package:smart_safety/services/app_permission_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Esp32BleService Lifecycle & Fallback Tests', () {
    test('Initializes with disconnected status and default state', () {
      final service = Esp32BleService.instance;
      expect(service.status, isA<Esp32ConnectionStatus>());
      expect(service.batteryLevelNotifier.value, inInclusiveRange(0, 100));
      expect(service.rssiNotifier.value, lessThanOrEqualTo(0));
    });

    test('Esp32DeviceState copyWith updates fields correctly', () {
      final state = Esp32DeviceState(lastSeen: DateTime.now());
      final updated = state.copyWith(batteryLevel: 88, rssi: -62);
      expect(updated.batteryLevel, 88);
      expect(updated.rssi, -62);
      expect(updated.deviceName, 'ESP32 Smart Pendant');
    });

    test('Hardware SOS trigger does not throw unhandled exception', () {
      expect(
        () => Esp32BleService.instance.handleHardwareSosTrigger(reason: 'Test Suite Trigger'),
        returnsNormally,
      );
    });
  });

  group('AppPermissionService Diagnostic Tests', () {
    test('PermissionReport accurately reflects granted state', () {
      const report = PermissionReport(
        locationPrecise: true,
        locationCoarse: true,
        bluetoothConnect: true,
        bluetoothScan: true,
        notifications: true,
        sms: true,
      );

      expect(report.isLocationGranted, isTrue);
      expect(report.isBluetoothGranted, isTrue);
    });

    test('PermissionReport detects missing Bluetooth permissions', () {
      const report = PermissionReport(
        locationPrecise: true,
        locationCoarse: true,
        bluetoothConnect: false,
        bluetoothScan: true,
        notifications: true,
        sms: true,
      );

      expect(report.isLocationGranted, isTrue);
      expect(report.isBluetoothGranted, isFalse);
    });
  });
}
