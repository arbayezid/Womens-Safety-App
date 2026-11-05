import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_permission_service.dart';
import 'emergency_service.dart';

/// Represents connection lifecycle states for the ESP32 Smart Pendant.
enum Esp32ConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  permissionDenied,
  bluetoothDisabled,
}

/// Structured hardware state packet from ESP32 Smart Pendant.
class Esp32DeviceState {
  final String deviceName;
  final String deviceAddress;
  final int batteryLevel;
  final int rssi;
  final bool isButtonArmed;
  final DateTime lastSeen;

  const Esp32DeviceState({
    this.deviceName = 'ESP32 Smart Pendant',
    this.deviceAddress = 'Unknown',
    this.batteryLevel = 100,
    this.rssi = -60,
    this.isButtonArmed = true,
    required this.lastSeen,
  });

  Esp32DeviceState copyWith({
    String? deviceName,
    String? deviceAddress,
    int? batteryLevel,
    int? rssi,
    bool? isButtonArmed,
    DateTime? lastSeen,
  }) {
    return Esp32DeviceState(
      deviceName: deviceName ?? this.deviceName,
      deviceAddress: deviceAddress ?? this.deviceAddress,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      rssi: rssi ?? this.rssi,
      isButtonArmed: isButtonArmed ?? this.isButtonArmed,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

/// Central Service managing real Bluetooth Low Energy communication,
/// adapter monitoring, device discovery, GATT characteristic listeners,
/// and hardware SOS triggers from the ESP32 Women's Safety Smart Pendant.
class Esp32BleService {
  Esp32BleService._internal();

  /// Central singleton instance
  static final Esp32BleService instance = Esp32BleService._internal();

  // ── SharedPreferences Keys ───────────────────────────────────────────────
  static const String _prefKeySavedDeviceId = 'pref_saved_esp32_device_id';
  static const String _prefKeySavedDeviceName = 'pref_saved_esp32_device_name';

  // ── Standard ESP32 Woman Guard BLE UUIDs ──────────────────────────────────
  static const String serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const String sosCharacteristicUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const String batteryCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

  /// Reactive connection state notifier
  final ValueNotifier<Esp32ConnectionStatus> connectionStateNotifier =
      ValueNotifier<Esp32ConnectionStatus>(Esp32ConnectionStatus.disconnected);

  /// Reactive hardware device state notifier
  final ValueNotifier<Esp32DeviceState> deviceStateNotifier =
      ValueNotifier<Esp32DeviceState>(Esp32DeviceState(lastSeen: DateTime.now()));

  /// Reactive battery level notifier (0-100%)
  final ValueNotifier<int> batteryLevelNotifier = ValueNotifier<int>(100);

  /// Reactive signal strength RSSI notifier (dBm)
  final ValueNotifier<int> rssiNotifier = ValueNotifier<int>(-60);

  /// Active connected device
  BluetoothDevice? _connectedDevice;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  /// Stored device info for auto-reconnect
  String? _savedDeviceId;
  String? _savedDeviceName;
  String? get savedDeviceId => _savedDeviceId;
  String? get savedDeviceName => _savedDeviceName;

  bool _isInitialized = false;
  Timer? _telemetryTimer;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<BluetoothConnectionState>? _deviceConnSubscription;
  StreamSubscription<List<int>>? _sosCharSubscription;
  StreamSubscription<List<int>>? _batteryCharSubscription;

  /// Getter for current connection state
  Esp32ConnectionStatus get status => connectionStateNotifier.value;
  bool get isConnected => status == Esp32ConnectionStatus.connected;

  /// Current adapter state check
  bool get isBluetoothOn =>
      FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;

  /// Exposes the real-time scan results stream
  Stream<List<ScanResult>> get scanResultsStream => FlutterBluePlus.scanResults;

  /// Exposes scanning active state stream
  Stream<bool> get isScanningStream => FlutterBluePlus.isScanning;

  /// Initializes the ESP32 hardware service safely.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    debugPrint('[Esp32BleService] Initializing ESP32 BLE Service...');

    try {
      // 1. Load any previously paired device from persistent storage
      final prefs = await SharedPreferences.getInstance();
      _savedDeviceId = prefs.getString(_prefKeySavedDeviceId);
      _savedDeviceName = prefs.getString(_prefKeySavedDeviceName);

      if (_savedDeviceId != null) {
        debugPrint('[Esp32BleService] Found saved ESP32 device: $_savedDeviceName ($_savedDeviceId)');
      }

      // 2. Monitor Bluetooth adapter hardware state changes (On / Off)
      _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
        debugPrint('[Esp32BleService] Adapter state changed: $state');
        if (state != BluetoothAdapterState.on) {
          if (_connectedDevice != null) {
            disconnect();
          }
          _updateStateOnMainThread(Esp32ConnectionStatus.bluetoothDisabled);
        } else {
          // If Bluetooth was turned back on and we're currently marked disabled, reset to disconnected
          if (connectionStateNotifier.value == Esp32ConnectionStatus.bluetoothDisabled) {
            _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
          }
        }
      });

      // 3. Check current adapter status
      if (!isBluetoothOn) {
        _updateStateOnMainThread(Esp32ConnectionStatus.bluetoothDisabled);
        return;
      }

      // 4. If we have a previously saved device and Bluetooth permissions, attempt auto-reconnect
      final hasPermission = await AppPermissionService.instance.hasBluetoothPermission();
      if (hasPermission && _savedDeviceId != null) {
        debugPrint('[Esp32BleService] Attempting auto-reconnect to saved ESP32 device...');
        connectToDevice(targetId: _savedDeviceId);
      }
    } catch (e) {
      debugPrint('[Esp32BleService] Initialization notice: $e');
      _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
    }
  }

  /// Requests the system / user to turn on Bluetooth.
  /// On Android, this triggers the native "An app wants to turn on Bluetooth" prompt.
  Future<bool> turnOnBluetooth() async {
    try {
      if (isBluetoothOn) return true;
      if (Platform.isAndroid) {
        debugPrint('[Esp32BleService] Requesting Android system to turn on Bluetooth...');
        await FlutterBluePlus.turnOn();
        // Wait up to 3 seconds for the adapter state to transition to ON
        for (int i = 0; i < 6; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (isBluetoothOn) {
            _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
            return true;
          }
        }
      }
      return isBluetoothOn;
    } catch (e) {
      debugPrint('[Esp32BleService] Failed to turn on Bluetooth: $e');
      return false;
    }
  }

  /// Starts scanning for nearby Bluetooth devices.
  /// Validates runtime permissions and ensures the Bluetooth adapter is enabled first.
  Future<bool> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    try {
      // 1. Verify runtime permissions
      final hasPermission =
          await AppPermissionService.instance.checkAndRequestBluetoothPermissions();
      if (!hasPermission) {
        debugPrint('[Esp32BleService] Bluetooth permissions denied.');
        _updateStateOnMainThread(Esp32ConnectionStatus.permissionDenied);
        return false;
      }

      // 2. Verify Bluetooth hardware is ON
      if (!isBluetoothOn) {
        debugPrint('[Esp32BleService] Bluetooth is turned off.');
        _updateStateOnMainThread(Esp32ConnectionStatus.bluetoothDisabled);
        return false;
      }

      // 3. Stop any existing scan before starting fresh
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      _updateStateOnMainThread(Esp32ConnectionStatus.scanning);
      debugPrint('[Esp32BleService] Starting BLE device scan (timeout: ${timeout.inSeconds}s)...');

      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: true,
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );

      return true;
    } catch (e) {
      debugPrint('[Esp32BleService] Error starting scan: $e');
      _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
      return false;
    }
  }

  /// Stops an active BLE scan.
  Future<void> stopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      if (status == Esp32ConnectionStatus.scanning) {
        _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
      }
    } catch (e) {
      debugPrint('[Esp32BleService] Error stopping scan: $e');
    }
  }

  /// Connects to an ESP32 device, discovers GATT services, and registers SOS listeners.
  /// Accepts either a direct [BluetoothDevice] instance or a [targetId] MAC/UUID string.
  Future<bool> connectToDevice({
    BluetoothDevice? targetDevice,
    String? targetId,
  }) async {
    try {
      // 1. Check runtime permissions
      final hasPermission =
          await AppPermissionService.instance.checkAndRequestBluetoothPermissions();
      if (!hasPermission) {
        _updateStateOnMainThread(Esp32ConnectionStatus.permissionDenied);
        return false;
      }

      // 2. Check adapter power state
      if (!isBluetoothOn) {
        _updateStateOnMainThread(Esp32ConnectionStatus.bluetoothDisabled);
        return false;
      }

      // 3. Resolve target Bluetooth device
      BluetoothDevice? device = targetDevice;
      if (device == null) {
        final id = targetId ?? _savedDeviceId;
        if (id == null || id.isEmpty) {
          debugPrint('[Esp32BleService] No target device or saved ID provided for connect.');
          return false;
        }
        device = BluetoothDevice.fromId(id);
      }

      // Stop any scanning in progress
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      _updateStateOnMainThread(Esp32ConnectionStatus.connecting);
      debugPrint('[Esp32BleService] Connecting to device ${device.remoteId} (${device.platformName})...');

      // 4. Establish GATT connection
      await device.connect(
        timeout: const Duration(seconds: 12),
        autoConnect: false,
      );

      _connectedDevice = device;

      // 5. Save device ID for seamless auto-reconnect
      final name = device.platformName.isNotEmpty ? device.platformName : 'ESP32 Smart Device';
      await _savePairedDevice(device.remoteId.str, name);

      // 6. Listen to device connection state stream (detect unexpected disconnects)
      _deviceConnSubscription?.cancel();
      _deviceConnSubscription = device.connectionState.listen((connState) {
        debugPrint('[Esp32BleService] Connection state stream: $connState');
        if (connState == BluetoothConnectionState.disconnected) {
          _handleDeviceDisconnected();
        }
      });

      // 7. Discover GATT services and attach characteristic hooks
      await _discoverAndSubscribeServices(device);

      // 8. Update state and start background telemetry polling
      _updateStateOnMainThread(Esp32ConnectionStatus.connected);
      _startTelemetryMonitor();

      debugPrint('[Esp32BleService] ✅ ESP32 successfully connected and armed.');
      return true;
    } on PlatformException catch (e) {
      debugPrint('[Esp32BleService] ❌ Native platform error: ${e.code} - ${e.message}');
      _handleDeviceDisconnected();
      return false;
    } catch (e) {
      debugPrint('[Esp32BleService] ❌ Connection error: $e');
      _handleDeviceDisconnected();
      return false;
    }
  }

  /// Discovers GATT services and subscribes to SOS triggers and Battery telemetry.
  Future<void> _discoverAndSubscribeServices(BluetoothDevice device) async {
    try {
      debugPrint('[Esp32BleService] Discovering GATT services...');
      final services = await device.discoverServices();

      BluetoothCharacteristic? sosChar;
      BluetoothCharacteristic? batteryChar;

      for (final service in services) {
        // Check characteristics in discovered service
        for (final characteristic in service.characteristics) {
          final charUuid = characteristic.uuid.toString().toLowerCase();

          // Match SOS characteristic
          if (charUuid == sosCharacteristicUuid.toLowerCase() ||
              charUuid.contains('beb5483e')) {
            sosChar = characteristic;
          }

          // Match Battery characteristic (Standard 0x2A19 or within custom service)
          if (charUuid == batteryCharacteristicUuid.toLowerCase() ||
              charUuid.contains('2a19')) {
            batteryChar = characteristic;
          }
        }
      }

      // Subscribe to SOS characteristic notifications
      if (sosChar != null) {
        debugPrint('[Esp32BleService] Found SOS characteristic: ${sosChar.uuid}');
        await sosChar.setNotifyValue(true);
        _sosCharSubscription?.cancel();
        _sosCharSubscription = sosChar.onValueReceived.listen((data) {
          _processIncomingSosPacket(data);
        });
      } else {
        debugPrint('[Esp32BleService] ⚠️ SOS characteristic ($sosCharacteristicUuid) not found. Checking all characteristics...');
        // Fallback: subscribe to the first notify-capable characteristic found
        for (final service in services) {
          for (final char in service.characteristics) {
            if (char.properties.notify || char.properties.indicate) {
              debugPrint('[Esp32BleService] Subscribing to fallback notify characteristic: ${char.uuid}');
              await char.setNotifyValue(true);
              _sosCharSubscription?.cancel();
              _sosCharSubscription = char.onValueReceived.listen((data) {
                _processIncomingSosPacket(data);
              });
              break;
            }
          }
        }
      }

      // Read initial battery level if available
      if (batteryChar != null) {
        debugPrint('[Esp32BleService] Found Battery characteristic: ${batteryChar.uuid}');
        try {
          final val = await batteryChar.read();
          if (val.isNotEmpty) {
            final level = val[0].clamp(0, 100);
            _runOnMainThread(() => batteryLevelNotifier.value = level);
          }
          if (batteryChar.properties.notify) {
            await batteryChar.setNotifyValue(true);
            _batteryCharSubscription?.cancel();
            _batteryCharSubscription = batteryChar.onValueReceived.listen((data) {
              if (data.isNotEmpty) {
                final level = data[0].clamp(0, 100);
                _runOnMainThread(() => batteryLevelNotifier.value = level);
              }
            });
          }
        } catch (e) {
          debugPrint('[Esp32BleService] Notice reading battery characteristic: $e');
        }
      }

      // Read initial RSSI
      try {
        final rssi = await device.readRssi();
        _runOnMainThread(() => rssiNotifier.value = rssi);
      } catch (_) {}

      // Update local state snapshot
      _runOnMainThread(() {
        deviceStateNotifier.value = Esp32DeviceState(
          deviceName: device.platformName.isNotEmpty ? device.platformName : (_savedDeviceName ?? 'ESP32 Device'),
          deviceAddress: device.remoteId.str,
          batteryLevel: batteryLevelNotifier.value,
          rssi: rssiNotifier.value,
          isButtonArmed: true,
          lastSeen: DateTime.now(),
        );
      });
    } catch (e) {
      debugPrint('[Esp32BleService] Error during service discovery: $e');
    }
  }

  /// Processes raw byte payloads from the ESP32 hardware characteristic.
  void _processIncomingSosPacket(List<int> data) {
    if (data.isEmpty) return;

    try {
      // Decode as UTF-8 string or inspect raw bytes
      final rawString = utf8.decode(data, allowMalformed: true).trim();
      debugPrint('[Esp32BleService] 📥 Received hardware BLE packet: "$rawString" (bytes: $data)');

      // Triggers if: byte is 1 / 0x01, or text contains "SOS", "HELP", "1", "ALERT", "TRIGGER"
      final isSosTrigger = data.contains(1) ||
          data.first == 0x01 ||
          rawString.toUpperCase().contains('SOS') ||
          rawString.toUpperCase().contains('HELP') ||
          rawString.contains('1');

      if (isSosTrigger) {
        handleHardwareSosTrigger(reason: 'ESP32 Hardware Button ($rawString)');
      }
    } catch (e) {
      debugPrint('[Esp32BleService] Packet decode error: $e. Checking raw bytes...');
      if (data.isNotEmpty && (data.first == 1 || data.first == 0x01)) {
        handleHardwareSosTrigger(reason: 'ESP32 Hardware Button (Raw 0x01)');
      }
    }
  }

  /// Disconnects from the current ESP32 device cleanly.
  Future<void> disconnect() async {
    try {
      _telemetryTimer?.cancel();
      _telemetryTimer = null;
      await _sosCharSubscription?.cancel();
      _sosCharSubscription = null;
      await _batteryCharSubscription?.cancel();
      _batteryCharSubscription = null;
      await _deviceConnSubscription?.cancel();
      _deviceConnSubscription = null;

      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
        _connectedDevice = null;
      }

      _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
      debugPrint('[Esp32BleService] 🔌 ESP32 disconnected cleanly.');
    } catch (e) {
      debugPrint('[Esp32BleService] Error during disconnect: $e');
      _updateStateOnMainThread(Esp32ConnectionStatus.disconnected);
    }
  }

  /// Forgets the paired device and clears persistent storage.
  Future<void> forgetDevice() async {
    await disconnect();
    _savedDeviceId = null;
    _savedDeviceName = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeySavedDeviceId);
    await prefs.remove(_prefKeySavedDeviceName);
    debugPrint('[Esp32BleService] Paired device forgotten.');
  }

  /// Internal handler when physical link drops unexpectedly.
  void _handleDeviceDisconnected() {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _sosCharSubscription?.cancel();
    _sosCharSubscription = null;
    _batteryCharSubscription?.cancel();
    _batteryCharSubscription = null;
    _deviceConnSubscription?.cancel();
    _deviceConnSubscription = null;
    _connectedDevice = null;

    final nextStatus = isBluetoothOn
        ? Esp32ConnectionStatus.disconnected
        : Esp32ConnectionStatus.bluetoothDisabled;
    _updateStateOnMainThread(nextStatus);
    debugPrint('[Esp32BleService] Device disconnected.');
  }

  /// Saves paired device ID & name to local storage for auto-reconnect.
  Future<void> _savePairedDevice(String deviceId, String name) async {
    _savedDeviceId = deviceId;
    _savedDeviceName = name;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeySavedDeviceId, deviceId);
      await prefs.setString(_prefKeySavedDeviceName, name);
    } catch (e) {
      debugPrint('[Esp32BleService] Error saving device to prefs: $e');
    }
  }

  /// Simulates or processes an incoming hardware button press from the ESP32 Smart Pendant.
  /// Dispatches the emergency pipeline strictly on the UI thread.
  void handleHardwareSosTrigger({String reason = 'ESP32 Hardware Button'}) {
    debugPrint('[Esp32BleService] ⚡ HARDWARE SOS TRIGGER RECEIVED: $reason');

    _runOnMainThread(() async {
      try {
        HapticFeedback.heavyImpact();

        // Trigger the app's central Emergency SOS pipeline
        await EmergencyService.instance.triggerEmergency(
          source: 'ESP32 Hardware',
          playSiren: true,
        );
      } catch (e) {
        debugPrint('[Esp32BleService] Error executing hardware SOS pipeline: $e');
      }
    });
  }

  /// Periodic background heartbeat & telemetry reader (RSSI & Battery).
  void _startTelemetryMonitor() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!isConnected || _connectedDevice == null) return;
      try {
        final rssi = await _connectedDevice!.readRssi();
        _runOnMainThread(() {
          rssiNotifier.value = rssi;
          deviceStateNotifier.value = deviceStateNotifier.value.copyWith(
            rssi: rssi,
            lastSeen: DateTime.now(),
          );
        });
      } catch (_) {}
    });
  }

  /// Helper ensuring state transitions occur safely on the Main (UI) Thread.
  void _updateStateOnMainThread(Esp32ConnectionStatus newStatus) {
    _runOnMainThread(() {
      connectionStateNotifier.value = newStatus;
    });
  }

  /// Dispatches actions to the Flutter Main/UI Thread safely.
  void _runOnMainThread(VoidCallback action) {
    if (WidgetsBinding.instance.isRootWidgetAttached) {
      WidgetsBinding.instance.addPostFrameCallback((_) => action());
    } else {
      action();
    }
  }

  /// Clean up resources
  void dispose() {
    _telemetryTimer?.cancel();
    _adapterSubscription?.cancel();
    _deviceConnSubscription?.cancel();
    _sosCharSubscription?.cancel();
    _batteryCharSubscription?.cancel();
    connectionStateNotifier.dispose();
    deviceStateNotifier.dispose();
    batteryLevelNotifier.dispose();
    rssiNotifier.dispose();
  }
}
