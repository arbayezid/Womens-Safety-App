import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../services/app_permission_service.dart';
import '../services/esp32_ble_service.dart';

/// Bottom sheet dialog for Bluetooth device discovery, connection,
/// and management for the ESP32 Women's Safety Smart Pendant.
class Esp32ScanSheet extends StatefulWidget {
  const Esp32ScanSheet({super.key});

  /// Convenience method to show the scan modal from any screen.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const Esp32ScanSheet(),
    );
  }

  @override
  State<Esp32ScanSheet> createState() => _Esp32ScanSheetState();
}

class _Esp32ScanSheetState extends State<Esp32ScanSheet> with SingleTickerProviderStateMixin {
  final Esp32BleService _bleService = Esp32BleService.instance;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  String? _connectingDeviceId;
  bool _isTurningOnBt = false;
  String? _errorMessage;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _initBluetoothAndScan();
  }

  Future<void> _initBluetoothAndScan() async {
    // 1. Check runtime permissions
    final hasPermission =
        await AppPermissionService.instance.checkAndRequestBluetoothPermissions();
    if (!mounted) return;

    if (!hasPermission) {
      setState(() {
        _errorMessage =
            'Bluetooth & Nearby Device permissions are required to scan for the ESP32 safety pendant.';
      });
      return;
    }

    // 2. Read initial adapter state
    _adapterState = FlutterBluePlus.adapterStateNow;

    // 3. Listen to reactive adapter state changes
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() {
        _adapterState = state;
      });

      // When Bluetooth is switched ON by user, start scanning automatically
      if (state == BluetoothAdapterState.on && !_isScanning && !_bleService.isConnected) {
        _startScan();
      }
    });

    // 4. Listen to scan results
    _scanSub = _bleService.scanResultsStream.listen((results) {
      if (!mounted) return;
      setState(() {
        _scanResults = results;
      });
    });

    // 5. Listen to scanning active flag
    _isScanningSub = _bleService.isScanningStream.listen((scanning) {
      if (!mounted) return;
      setState(() {
        _isScanning = scanning;
      });
    });

    // If already ON and not currently connected, initiate scan
    if (_adapterState == BluetoothAdapterState.on && !_bleService.isConnected) {
      _startScan();
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _errorMessage = null;
    });
    final started = await _bleService.startScan(timeout: const Duration(seconds: 15));
    if (!started && mounted) {
      setState(() {
        _errorMessage = 'Could not start Bluetooth scan. Please verify permissions and settings.';
      });
    }
  }

  Future<void> _handleTurnOnBluetooth() async {
    setState(() {
      _isTurningOnBt = true;
      _errorMessage = null;
    });

    try {
      final success = await _bleService.turnOnBluetooth();
      if (!mounted) return;
      if (!success) {
        setState(() {
          _errorMessage =
              'Could not turn on Bluetooth automatically. Please turn it on in your device Quick Settings.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to enable Bluetooth: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isTurningOnBt = false;
        });
      }
    }
  }

  Future<void> _handleConnect(BluetoothDevice device) async {
    setState(() {
      _connectingDeviceId = device.remoteId.str;
      _errorMessage = null;
    });

    final success = await _bleService.connectToDevice(targetDevice: device);

    if (!mounted) return;
    setState(() {
      _connectingDeviceId = null;
    });

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Connected to ${device.platformName.isNotEmpty ? device.platformName : "ESP32"} successfully!',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
          ),
          backgroundColor: AppColors.successForeground,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (_bleService.lastConnectWasUnsupported) {
      setState(() {
        _errorMessage =
            '${device.platformName.isNotEmpty ? device.platformName : "This device"} is not a supported Woman Guard pendant (unsupported firmware). Nothing was saved.';
      });
    } else {
      setState(() {
        _errorMessage =
            'Failed to connect to ${device.platformName.isNotEmpty ? device.platformName : "device"}. Ensure it is powered on and within range.';
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _adapterSub?.cancel();
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    // Stop scanning when sheet is closed if still scanning
    if (_isScanning) {
      _bleService.stopScan();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.85,
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: ValueListenableBuilder<Esp32ConnectionStatus>(
        valueListenable: _bleService.connectionStateNotifier,
        builder: (context, connStatus, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTopDragHandle(),
              const SizedBox(height: 16),
              _buildHeader(connStatus),
              const SizedBox(height: 16),
              if (_errorMessage != null) _buildErrorBanner(),
              Flexible(
                child: _buildBody(connStatus),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTopDragHandle() {
    return Center(
      child: Container(
        width: 44,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  Widget _buildHeader(Esp32ConnectionStatus connStatus) {
    final isConnected = connStatus == Esp32ConnectionStatus.connected;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isConnected ? const Color(0xFFE8F5E9) : const Color(0xFFEDE9FF),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_searching_rounded,
            color: isConnected ? AppColors.successForeground : AppColors.primary,
            size: 26,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ESP32 Safety Device',
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                isConnected
                    ? 'Connected and armed for SOS trigger'
                    : 'Pair your emergency hardware pendant',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sosRed.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.sosRed, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage!,
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: AppColors.sosRed,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Esp32ConnectionStatus connStatus) {
    // ── CASE 1: Bluetooth is TURNED OFF ──
    if (_adapterState != BluetoothAdapterState.on && _adapterState != BluetoothAdapterState.unknown) {
      return _buildBluetoothOffView();
    }

    // ── CASE 2: Device is ALREADY CONNECTED ──
    if (connStatus == Esp32ConnectionStatus.connected) {
      return _buildConnectedDeviceView();
    }

    // ── CASE 3: Scanning / Device List View ──
    return _buildDeviceListView();
  }

  /// View shown when Bluetooth radio is disabled on the phone.
  Widget _buildBluetoothOffView() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFFFB74D), width: 1.5),
            ),
            child: const Icon(
              Icons.bluetooth_disabled_rounded,
              color: Color(0xFFE65100),
              size: 48,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Bluetooth is Turned Off',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Bluetooth must be turned on to scan and connect to your ESP32 safety pendant. Please enable Bluetooth to continue.',
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isTurningOnBt ? null : _handleTurnOnBluetooth,
              icon: _isTurningOnBt
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.bluetooth_rounded, color: Colors.white),
              label: Text(
                _isTurningOnBt ? 'Turning On...' : 'Turn On Bluetooth',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// View shown when an ESP32 is actively connected.
  Widget _buildConnectedDeviceView() {
    final state = _bleService.deviceStateNotifier.value;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.successForeground.withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.successBackground,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.check_circle_rounded,
                          color: AppColors.successForeground, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            state.deviceName,
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            state.deviceAddress,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.successBackground,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Active',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.successForeground,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                ValueListenableBuilder<int>(
                  valueListenable: _bleService.batteryLevelNotifier,
                  builder: (context, battery, _) {
                    return _buildStatRow(
                      icon: Icons.battery_charging_full_rounded,
                      iconColor: AppColors.successForeground,
                      label: 'Battery Level',
                      value: '$battery%',
                    );
                  },
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<int>(
                  valueListenable: _bleService.rssiNotifier,
                  builder: (context, rssi, _) {
                    return _buildStatRow(
                      icon: Icons.signal_cellular_alt_rounded,
                      iconColor: AppColors.actionBlue,
                      label: 'Signal Strength',
                      value: '$rssi dBm',
                    );
                  },
                ),
                const SizedBox(height: 10),
                _buildStatRow(
                  icon: Icons.touch_app_rounded,
                  iconColor: AppColors.sosRed,
                  label: 'Hardware Button',
                  value: 'Armed & Listening',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Test SOS Trigger button: a dry run of the packet parser, never a real SOS
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                final recognised = _bleService.runHardwareTestDryRun();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      recognised
                          ? 'Pendant SOS received (test only, no alert sent)'
                          : 'Pendant SOS packet not recognised',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.warning_amber_rounded, color: Colors.white),
              label: Text(
                'Test Hardware SOS Trigger',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.sosRed,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Disconnect & Forget Row
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _bleService.disconnect(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Disconnect', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await _bleService.forgetDevice();
                    if (mounted) _startScan();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.sosRed,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Forget Device', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 10),
        Text(
          label,
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
        ),
        const Spacer(),
        Text(
          value,
          style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
        ),
      ],
    );
  }

  static bool _isEspressifMac(String mac) {
    final cleanMac = mac.toUpperCase().replaceAll(':', '').replaceAll('-', '');
    if (cleanMac.length < 6) return false;
    final prefix = cleanMac.substring(0, 6);
    const espressifOuis = {
      '044F1F', '083AF2', '08D1F9', '10061C', '10521C', '1091A8', '1097BD',
      '142B2F', '18FE34', '240AC4', '244CAB', '2462AB', '246F28', '24A160',
      '24DCC3', '2CBCBB', '308398', '30AEA4', '30C6F7', '30C922', '348518',
      '34865D', '349454', '34987A', '34AB95', '3C6105', '3C71BF', '3C8427',
      '3CE90E', '4022D8', '409151', '441793', '4827E2', '4831B7', '485519',
      '4C11AE', '4C7525', '5443B2', '545AA6', '58BF25', '58CF79', '600194',
      '6055F9', '64E833', '686725', '68B6B3', '70039F', '70041D', '70B8F6',
      '782184', '78E36D', '7C87CE', '7C9EBD', '7CDFA1', '80646F', '807D3A',
      '840D8E', '84F703', '84FCE6', '8C4B14', '8CAAB5', '8CCE4E', '901205',
      '90380C', '943CC6', '94B555', '94B97E', '98CDAC', 'A020A6', 'A0764E',
      'A0B765', 'A4C138', 'A4CF12', 'A4E57C', 'AC0BFB', 'AC67B2', 'B48A0A',
      'B4E62D', 'BCDDC2', 'C049EF', 'C44F33', 'C4D8D5', 'C4DD57', 'C82B96',
      'C8C9A3', 'CC50E3', 'CC7B5C', 'CCBA97', 'D48AFC', 'D4D4DA', 'D8A01D',
      'D8BC38', 'DC4F22', 'DC5475', 'E05A1B', 'E0E2E6', 'E465B8', 'E831CD',
      'E868E7', 'E89F6D', 'E8DB84', 'EC6260', 'EC64C9', 'ECDA3B', 'ECFABC',
      'F008D1', 'F024F9', 'F0F5BD', 'F412FA', 'F4CFA2', 'FCF5C4',
    };
    return espressifOuis.contains(prefix);
  }

  /// Bluetooth SIG company identifiers for common consumer brands.
  static const Map<int, String> _manufacturerNames = {
    0x0002: 'Intel',
    0x0006: 'Microsoft',
    0x000A: 'Qualcomm',
    0x000F: 'Broadcom',
    0x0046: 'MediaTek',
    0x004C: 'Apple',
    0x0059: 'Nordic',
    0x005D: 'Realtek',
    0x0067: 'Jabra',
    0x0075: 'Samsung',
    0x0087: 'Garmin',
    0x009E: 'Bose',
    0x00C4: 'LG',
    0x00E0: 'Google',
    0x012D: 'Sony',
    0x0157: 'Amazfit',
    0x0171: 'Amazon',
    0x01DA: 'Logitech',
    0x027D: 'Huawei',
    0x02E5: 'Espressif',
    0x038F: 'Xiaomi',
    0x05A7: 'Sonos',
  };

  /// Well-known 16-bit service UUIDs that hint at the device type.
  static const Map<String, String> _serviceHints = {
    'fe2c': 'Google Fast Pair Device',
    'fd6f': 'Phone (Exposure Notification)',
    'fd5a': 'Samsung Device',
    'feaa': 'Eddystone Beacon',
    'fe03': 'Amazon Echo Device',
    '180d': 'Heart Rate Monitor',
    '1812': 'Keyboard / Mouse (HID)',
  };

  static bool _hasSafetyServiceUuid(ScanResult result) {
    return Esp32BleService.exposesSafetyService(
        result.advertisementData.serviceUuids.map((g) => g.str128));
  }

  /// The name the device itself broadcasts (or the OS has cached), or null.
  static String? _broadcastName(ScanResult result) {
    final candidates = [
      result.advertisementData.advName,
      result.device.advName,
      result.device.platformName,
    ];
    for (final c in candidates) {
      final t = c.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// Best-effort guess for devices that do not broadcast a name, based on
  /// manufacturer data and advertised service UUIDs.
  static String? _guessDeviceType(ScanResult result) {
    final adv = result.advertisementData;

    for (final entry in adv.manufacturerData.entries) {
      final data = entry.value;
      if (entry.key == 0x004C && data.isNotEmpty) {
        switch (data[0]) {
          case 0x07:
            return 'Apple AirPods / Beats';
          case 0x12:
            return 'Apple Find My (AirTag)';
          case 0x09:
            return 'Apple TV / AirPlay';
          case 0x0C:
          case 0x10:
            return 'Apple iPhone / iPad / Mac';
        }
      }
      if (entry.key == 0x0006) return 'Windows PC (Microsoft)';
      final brand = _manufacturerNames[entry.key];
      if (brand != null) return '$brand Device';
    }

    for (final g in adv.serviceUuids) {
      final s = g.str128.toLowerCase();
      if (s.startsWith('0000') && s.endsWith('-0000-1000-8000-00805f9b34fb')) {
        final hint = _serviceHints[s.substring(4, 8)];
        if (hint != null) return hint;
      }
    }
    for (final g in adv.serviceData.keys) {
      final s = g.str128.toLowerCase();
      if (s.startsWith('0000')) {
        final hint = _serviceHints[s.substring(4, 8)];
        if (hint != null) return hint;
      }
    }
    return null;
  }

  static String _resolveDeviceName(ScanResult result) {
    final name = _broadcastName(result);
    if (name != null) return name;

    if (_hasSafetyServiceUuid(result)) return 'ESP32-Safety-Pendant';

    final mac = result.device.remoteId.str;
    if (_isEspressifMac(mac)) {
      final shortMac = mac.length >= 5 ? mac.substring(mac.length - 5) : mac;
      return 'ESP32 Device ($shortMac)';
    }

    return _guessDeviceType(result) ?? 'Unknown BLE Device';
  }

  static bool _isEsp32(ScanResult result) {
    if (_hasSafetyServiceUuid(result)) return true;
    final name = _resolveDeviceName(result).toUpperCase();
    if (name.contains('ESP32') ||
        name.contains('SAFETY') ||
        name.contains('PENDANT') ||
        name.contains('WOMAN')) {
      return true;
    }
    return _isEspressifMac(result.device.remoteId.str);
  }

  /// View displaying discovered Bluetooth devices in real time.
  Widget _buildDeviceListView() {
    // Show all available devices directly without filtering.
    // ESP32 devices and named devices remain sorted at the top by signal strength.
    final sortedResults = List<ScanResult>.from(_scanResults);
    sortedResults.sort((a, b) {
      final aIsEsp = _isEsp32(a);
      final bIsEsp = _isEsp32(b);
      if (aIsEsp && !bIsEsp) return -1;
      if (!aIsEsp && bIsEsp) return 1;

      final aKnown = _broadcastName(a) != null;
      final bKnown = _broadcastName(b) != null;
      if (aKnown && !bKnown) return -1;
      if (!aKnown && bKnown) return 1;

      return b.rssi.compareTo(a.rssi);
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scan progress bar row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                if (_isScanning)
                  FadeTransition(
                    opacity: _pulseController,
                    child: Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: const BoxDecoration(
                        color: AppColors.actionBlue,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Text(
                  _isScanning
                      ? 'Scanning for devices...'
                      : 'Available Devices (${sortedResults.length})',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: _isScanning ? null : _startScan,
              icon: Icon(
                Icons.refresh_rounded,
                size: 16,
                color: _isScanning ? Colors.grey : AppColors.primary,
              ),
              label: Text(
                _isScanning ? 'Scanning' : 'Rescan',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _isScanning ? Colors.grey : AppColors.primary,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Device List
        if (sortedResults.isEmpty)
          _buildEmptyScanState()
        else
          Expanded(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: sortedResults.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, index) {
                final result = sortedResults[index];
                return _buildDeviceTile(result);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyScanState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isScanning ? Icons.radar_rounded : Icons.bluetooth_searching_rounded,
            size: 44,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 12),
          Text(
            _isScanning ? 'Discovering nearby devices...' : 'No Bluetooth Devices Found',
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isScanning
                ? 'Ensure your ESP32 device is powered on and advertising.'
                : 'Make sure your ESP32 safety hardware is powered on and in range, then tap Rescan.',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(ScanResult result) {
    final device = result.device;
    final name = _resolveDeviceName(result);
    final isEsp32 = _isEsp32(result);
    final isConnectingThis = _connectingDeviceId == device.remoteId.str;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isEsp32 ? const Color(0xFFF7F5FF) : AppColors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEsp32 ? AppColors.primary.withValues(alpha: 0.3) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isEsp32 ? AppColors.primary : Colors.grey.shade300,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.bluetooth_rounded,
              color: isEsp32 ? Colors.white : Colors.grey.shade700,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isEsp32) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'ESP32',
                          style: GoogleFonts.poppins(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      device.remoteId.str,
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '• ${result.rssi} dBm',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _getRssiColor(result.rssi),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: isConnectingThis ? null : () => _handleConnect(device),
            style: ElevatedButton.styleFrom(
              backgroundColor: isEsp32 ? AppColors.primary : AppColors.actionBlue,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: isConnectingThis
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Text(
                    'Connect',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Color _getRssiColor(int rssi) {
    if (rssi >= -65) return AppColors.successForeground;
    if (rssi >= -80) return AppColors.actionBlue;
    return Colors.grey.shade600;
  }
}
