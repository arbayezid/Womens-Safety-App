import 'dart:async';
import 'dart:ui';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';
import '../firebase_options.dart';

/// Top-level background execution entry point invoked by [FlutterBackgroundService].
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Initialize Firebase in the isolated background engine
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    debugPrint('[BackgroundService] Firebase init notice in isolate: $e');
  }

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });

    service.on('updateNotification').listen((event) {
      final title = event?['title']?.toString() ?? 'Woman Guard Protection';
      final content = event?['content']?.toString() ?? 'Active monitoring in progress';
      service.setForegroundNotificationInfo(
        title: title,
        content: content,
      );
    });
  }

  service.on('stopService').listen((_) {
    service.stopSelf();
  });
}

/// Background handler for iOS background fetch cycles.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// Central manager configuring and orchestrating Android/iOS foreground background services
/// for live SOS tracking, journey monitoring, and camouflage disguised status notifications.
class BackgroundServiceManager {
  BackgroundServiceManager._internal();

  /// Central singleton instance
  static final BackgroundServiceManager instance = BackgroundServiceManager._internal();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;

  static const String _prefBatteryOptPrompted = 'pref_battery_optimization_prompted';

  /// Initializes the background service configuration.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'sos_emergency_channel',
          initialNotificationTitle: 'Woman Guard Protection Active',
          initialNotificationContent: 'Monitoring your safety in the background',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onStart,
          onBackground: onIosBackground,
        ),
      );
      _isInitialized = true;
      debugPrint('[BackgroundServiceManager] Background service configured.');
    } catch (e) {
      debugPrint('[BackgroundServiceManager] Error configuring background service: $e');
    }
  }

  /// Starts the foreground service with customizable notification text.
  Future<bool> startService({
    String title = 'Woman Guard Protection Active',
    String content = 'Live safety tracking active in background',
  }) async {
    await initialize();
    try {
      final isRunning = await _service.isRunning();
      if (!isRunning) {
        await _service.startService();
      }
      updateNotification(title: title, content: content);
      return true;
    } catch (e) {
      debugPrint('[BackgroundServiceManager] Error starting service: $e');
      return false;
    }
  }

  /// Dynamically updates the persistent foreground notification text.
  /// Used to switch to disguised text (e.g. "Calculator running") in Camouflage Mode.
  void updateNotification({
    required String title,
    required String content,
  }) {
    _service.invoke('updateNotification', {
      'title': title,
      'content': content,
    });
  }

  /// Stops the background service cleanly.
  Future<void> stopService() async {
    try {
      final isRunning = await _service.isRunning();
      if (isRunning) {
        _service.invoke('stopService');
      }
    } catch (e) {
      debugPrint('[BackgroundServiceManager] Error stopping service: $e');
    }
  }

  /// Checks if the service is currently running.
  Future<bool> isRunning() => _service.isRunning();

  /// Prompts the user once to exempt Woman Guard from aggressive Android battery optimization.
  Future<void> promptBatteryOptimizationOnce(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasPrompted = prefs.getBool(_prefBatteryOptPrompted) ?? false;
      if (hasPrompted) return;

      final status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        await prefs.setBool(_prefBatteryOptPrompted, true);
        return;
      }

      if (!context.mounted) return;

      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.actionBlue.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.battery_charging_full_rounded, color: AppColors.actionBlue, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Background Reliability',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
          content: Text(
            'To ensure continuous live GPS tracking, Safe Journey monitoring, and emergency SOS alerts remain active even when your screen is locked, please allow Woman Guard to run unrestricted without battery optimization.',
            style: GoogleFonts.poppins(fontSize: 13, height: 1.5, color: AppColors.textPrimary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Later', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Enable', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

      await prefs.setBool(_prefBatteryOptPrompted, true);

      if (proceed == true) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (e) {
      debugPrint('[BackgroundServiceManager] Battery optimization prompt error: $e');
    }
  }
}
