import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/app_theme.dart';
import 'screens/welcome_screen.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';

/// Global navigator key enabling intrusive dialog overlays from background or notification events
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Entry point of the Smart Safety application.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // Register the FCM background message handler safely
  try {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('[Main] FCM background handler warning: $e');
  }

  // Launch UI immediately so the user never sees a white screen
  runApp(const SmartSafetyApp());

  // Initialize notifications asynchronously after the first frame renders
  WidgetsBinding.instance.addPostFrameCallback((_) {
    NotificationService.instance.init(rootNavigatorKey).catchError((err) {
      debugPrint('[Main] NotificationService init error: $err');
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

      // The app always starts at the WelcomeScreen
      home: const WelcomeScreen(),
    );
  }
}
