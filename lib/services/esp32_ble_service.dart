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

/// Outcome of checking a connected device's GATT table.
enum _PendantCheck { supported, notPendant, unsupportedFirmware, discoveryFailed }

/// Strict filter for packets on the pendant's SOS characteristic.
///
/// Accepts only the exact packet `SOS` or `SOS:<sequence>`. Ignores packets in the first
/// [connectSettle] after connecting, a repeated sequence number, and anything within
/// [hwCooldown] of the last accepted trigger.
@visibleForTesting
class SosPacketFilter {
  static final RegExp _sosPacket = RegExp(r'^SOS(?::(\d+))?$');
  static const Duration hwCooldown = Duration(seconds: 30);
  static const Duration connectSettle = Duration(seconds: 3);
  static const int maxPacketLength = 32;

  DateTime? _connectedAt; // set at the end of service discovery; null on disconnect
  DateTime? _lastHwTriggerAt;
  int? _lastHwSeq; // reset to null on every connect

  /// Called at the end of service discovery.
  void onConnected(DateTime at) {
    _connectedAt = at;
    _lastHwSeq = null;
  }

  void onDisconnected() {
    _connectedAt = null;
  }

  /// Parses [data] without any timing state: true only for `SOS` or `SOS:<n>`.
  static bool isSosPacket(List<int> data) => _match(data) != null;

  static RegExpMatch? _match(List<int> data) {
    if (data.isEmpty || data.length > maxPacketLength) return null;
    final text = utf8.decode(data, allowMalformed: true).trim().toUpperCase();
    return _sosPacket.firstMatch(text);
  }

  /// Returns true when [data] received at [now] is a hardware SOS press.
  bool accept(List<int> data, DateTime now) {
    if (data.isEmpty || data.length > maxPacketLength) return false;
    final connectedAt = _connectedAt;
    if (connectedAt == null || now.difference(connectedAt) < connectSettle) return false;
    final match = _match(data);
    if (match == null) {
      debugPrint(
          '[Esp32BleService] Ignored non-SOS packet: "${utf8.decode(data, allowMalformed: true).trim()}"');
      return false;
    }
    final seq = int.tryParse(match.group(1) ?? '');
    if (seq != null && seq == _lastHwSeq) return false;
    if (_lastHwTriggerAt != null && now.difference(_lastHwTriggerAt!) < hwCooldown) return false;
    _lastHwSeq = seq;
    _lastHwTriggerAt = now;
    return true;
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

  // Nordic UART Service (NUS) TX characteristic (ESP32 -> app). Firmware that
  // uses NUS instead of the custom service above sends its SOS packet here.
  static const String nusTxCharacteristicUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static const String nusServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

  /// True when a device's advertised or discovered service UUIDs include the custom safety
  /// service or the Nordic UART Service (the pendant firmware sends `SOS` over NUS TX).
  /// Only such a device may be paired as the pendant; the strict packet parser still guards
  /// against anything that is not an exact `SOS` packet.
  static bool exposesSafetyService(Iterable<String> serviceUuids) {
    final targets = {serviceUuid.toLowerCase(), nusServiceUuid.toLowerCase()};
    return serviceUuids.any((u) => targets.contains(u.toLowerCase()));
  }

  /// Dry run for the setup sheet's test button: runs a synthetic `SOS` packet through the
  /// parser and never calls [EmergencyService.triggerEmergency].
  bool runHardwareTestDryRun() {
    final recognised = SosPacketFilter.isSosPacket(utf8.encode('SOS'));
    debugPrint('[Esp32BleService] Test trigger dry run: parser recognised SOS = $recognised');
    return recognised;
  }

  final SosPacketFilter _packetFilter = SosPacketFilter();

  /// True when the last connect attempt was refused because the device is not a pendant
  /// (no safety service) or its firmware exposes no supported SOS characteristic.
  bool _lastConnectUnsupported = false;
  bool get lastConnectWasUnsupported => _lastConnectUnsupported;

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

      _lastConnectUnsupported = false;
      _updateStateOnMainThread(Esp32ConnectionStatus.connecting);
      debugPrint('[Esp32BleService] Connecting to device ${device.remoteId} (${device.platformName})...');

      // 4. Establish GATT connection
      await device.connect(
        timeout: const Duration(seconds: 12),
        autoConnect: false,
      );

      _connectedDevice = device;

      // 5. Discover GATT services and attach characteristic hooks. Only a device that exposes
      // the safety service (and a supported SOS characteristic) is kept and saved.
      final check = await _discoverAndSubscribeServices(device);
      if (check != _PendantCheck.supported) {
        debugPrint('[Esp32BleService] Device ${device.remoteId} refused as pendant: $check');
        final isSaved = device.remoteId.str == _savedDeviceId;
        if (check == _PendantCheck.notPendant && isSaved) {
          await forgetDevice();
        } else {
          await disconnect();
        }
        _lastConnectUnsupported = check == _PendantCheck.notPendant ||
            check == _PendantCheck.unsupportedFirmware;
        return false;
      }

      // Save device ID for seamless auto-reconnect
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

      // 7. Update state and start background telemetry polling
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
  ///
  /// Subscribes only to [sosCharacteristicUuid] inside [serviceUuid], or to the NUS TX
  /// characteristic inside the NUS service. Any other characteristic is never treated as SOS.
  Future<_PendantCheck> _discoverAndSubscribeServices(BluetoothDevice device) async {
    try {
      debugPrint('[Esp32BleService] Discovering GATT services...');
      final services = await device.discoverServices();

      final serviceIds = services.map((s) => s.uuid.str128.toLowerCase()).toList();
      if (!exposesSafetyService(serviceIds)) {
        debugPrint('[Esp32BleService] ⚠️ Device exposes neither the safety service ($serviceUuid) '
            'nor the Nordic UART Service ($nusServiceUuid). Not a pendant.');
        return _PendantCheck.notPendant;
      }

      BluetoothCharacteristic? sosChar;
      BluetoothCharacteristic? nusTxChar;
      BluetoothCharacteristic? batteryChar;

      for (final service in services) {
        final svcUuid = service.uuid.str128.toLowerCase();
        // Check characteristics in discovered service
        for (final characteristic in service.characteristics) {
          final charUuid = characteristic.uuid.str128.toLowerCase();

          // Match SOS characteristic, only inside the safety service
          if (svcUuid == serviceUuid && charUuid == sosCharacteristicUuid) {
            sosChar = characteristic;
          }

          // Match Nordic UART TX characteristic, only inside the NUS service
          if (svcUuid == nusServiceUuid && charUuid == nusTxCharacteristicUuid) {
            nusTxChar = characteristic;
          }

          // Match Battery characteristic (Standard 0x2A19 or within custom service)
          if (charUuid == batteryCharacteristicUuid.toLowerCase() ||
              charUuid.contains('2a19')) {
            batteryChar = characteristic;
          }
        }
      }

      // Subscribe to SOS characteristic notifications
      final notifyChar = sosChar ?? nusTxChar;
      if (notifyChar == null) {
        debugPrint('[Esp32BleService] ⚠️ Unsupported pendant firmware: no SOS characteristic '
            '($sosCharacteristicUuid) or NUS TX characteristic. Subscribing to nothing.');
        return _PendantCheck.unsupportedFirmware;
      }
      debugPrint('[Esp32BleService] Found SOS characteristic: ${notifyChar.uuid}');
      await notifyChar.setNotifyValue(true);
      _sosCharSubscription?.cancel();
      _sosCharSubscription = notifyChar.onValueReceived.listen((data) {
        _processIncomingSosPacket(data);
      });

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

      // Discovery finished: packets are accepted after the connect settle time from here on.
      _packetFilter.onConnected(DateTime.now());
      return _PendantCheck.supported;
    } catch (e) {
      debugPrint('[Esp32BleService] Error during service discovery: $e');
      return _PendantCheck.discoveryFailed;
    }
  }

  /// Processes raw byte payloads from the ESP32 hardware characteristic.
  /// Only an exact `SOS` / `SOS:<n>` packet passing [SosPacketFilter] triggers SOS.
  void _processIncomingSosPacket(List<int> data) {
    if (_packetFilter.accept(data, DateTime.now())) {
      handleHardwareSosTrigger(reason: 'ESP32 Hardware Button');
    }
  }

  /// Disconnects from the current ESP32 device cleanly.
  Future<void> disconnect() async {
    _packetFilter.onDisconnected();
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
    _packetFilter.onDisconnected();
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

  /// Processes an incoming hardware button press from the ESP32 Smart Pendant.
  /// Fires immediately: BLE callbacks already arrive on the Dart main isolate, and deferring to
  /// a post-frame callback would queue triggers until the app is next drawn.
  void handleHardwareSosTrigger({String reason = 'ESP32 Hardware Button'}) {
    debugPrint('[Esp32BleService] HARDWARE SOS: $reason');
    HapticFeedback.heavyImpact();
    unawaited(EmergencyService.instance
        .triggerEmergency(source: 'ESP32 Hardware', origin: SosOrigin.manual, playSiren: true)
        .catchError((Object e) {
      debugPrint('[Esp32BleService] Hardware SOS failed: $e');
      return EmergencyResult(isSuccess: false, message: '$e');
    }));
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
