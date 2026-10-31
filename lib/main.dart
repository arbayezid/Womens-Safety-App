import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/app_theme.dart';
import 'screens/welcome_screen.dart';
import 'services/auth_service.dart';
import 'services/background_service.dart';
import 'services/guardian_alert_service.dart';
import 'services/live_tracking_service.dart';
import 'services/notification_service.dart';

import 'screens/camouflage_calculator_screen.dart';
import 'services/contact_sync_service.dart';
import 'services/pin_security_service.dart';
import 'services/ride_checkin_service.dart';
import 'services/app_permission_service.dart';
import 'services/esp32_ble_service.dart';

/// Global navigator key enabling intrusive dialog overlays from background or notification events
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Forwards an uncaught error to Crashlytics once Firebase is ready.
void _reportUncaughtError(Object error, StackTrace stack) {
  debugPrint('[Main] Uncaught error: $error');
  if (Firebase.apps.isEmpty) return;
  try {
    FirebaseCrashlytics.instance.recordError(error, stack);
  } catch (_) {}
}

/// Entry point of the Smart Safety application.
void main() {
  runZonedGuarded<Future<void>>(_bootstrap, _reportUncaughtError);
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (Firebase.apps.isEmpty) return;
    try {
      FirebaseCrashlytics.instance.recordFlutterError(details);
    } catch (_) {}
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _reportUncaughtError(error, stack);
    return true;
  };

  // Lock orientation to portrait for the best mobile experience
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize Firebase and Authentication session
  try {
    await AuthService.instance.initialize();
  } catch (e) {
    debugPrint('[Main] AuthService init warning: $e');
  }

  // Crash reports are only collected from release/profile builds
  if (Firebase.apps.isNotEmpty) {
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!kDebugMode);
    } catch (e) {
      debugPrint('[Main] Crashlytics init warning: $e');
    }
  }

  // Initialize PIN security & restore camouflage state if active
  try {
    await PinSecurityService.instance.initialize();
  } catch (e) {
    debugPrint('[Main] PinSecurityService init warning: $e');
  }

  // Register the FCM background message handler safely
  try {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('[Main] FCM background handler warning: $e');
  }

  // Launch UI immediately so the user never sees a white screen
  runApp(const SmartSafetyApp());

  // Initialize notifications, permissions, contact sync, ESP32 BLE & background tracking services asynchronously after the first frame renders
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    ContactSyncService.instance.initialize();

    // Verify and request cross-version Android permissions safely. Awaited so this batch finishes
    // before NotificationService asks for notification permission: Android handles only one
    // permission request at a time and silently drops results of overlapping requests.
    await AppPermissionService.instance.requestEssentialPermissions().catchError((err) {
      debugPrint('[Main] AppPermissionService init warning: $err');
      return const PermissionReport(
        locationPrecise: false,
        locationCoarse: false,
        bluetoothConnect: false,
        bluetoothScan: false,
        notifications: false,
        sms: false,
      );
    });

    // Initialize ESP32 Bluetooth hardware listener safely
    Esp32BleService.instance.initialize().catchError((err) {
      debugPrint('[Main] Esp32BleService init warning: $err');
    });

    NotificationService.instance.init(rootNavigatorKey).catchError((err) {
      debugPrint('[Main] NotificationService init error: $err');
    });

    // Native background SOS alert receiver; runs only while a user is signed in
    GuardianAlertService.instance.initialize(rootNavigatorKey);

    BackgroundServiceManager.instance.initialize().then((_) {
      LiveTrackingService.instance.autoResumeActiveSessions().catchError((err) {
        debugPrint('[Main] Auto-resume tracking error: $err');
      });
      RideCheckinService.instance.autoResumeActiveRide().catchError((err) {
        debugPrint('[Main] Auto-resume ride check-in error: $err');
      });
    }).catchError((err) {
      debugPrint('[Main] BackgroundServiceManager init error: $err');
    });
  });
}

/// Root widget of the application.
/// Sets up [MaterialApp] with Material 3 theme and initial route.
class SmartSafetyApp extends StatelessWidget {
  const SmartSafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Woman Guard',
      debugShowCheckedModeBanner: false,

      // Apply the centralized Material 3 theme
      theme: AppTheme.lightTheme,

      // Seamlessly switch the entire application view to Camouflage Calculator
      // when duress mode is triggered or camouflage mode is manually engaged.
      builder: (context, child) {
        return ValueListenableBuilder<bool>(
          valueListenable: PinSecurityService.instance.isCamouflageActiveNotifier,
          builder: (context, isCamouflage, _) {
            if (isCamouflage) {
              return const CamouflageCalculatorScreen();
            }
            return child ?? const SizedBox.shrink();
          },
        );
      },

      // The app always starts at the WelcomeScreen
      home: const WelcomeScreen(),
    );
  }
}
