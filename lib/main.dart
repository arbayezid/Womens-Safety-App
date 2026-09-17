import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/app_theme.dart';
import 'screens/welcome_screen.dart';
import 'services/auth_service.dart';

/// Entry point of the Smart Safety application.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to portrait for the best mobile experience
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize Firebase and Authentication session
  await AuthService.instance.initialize();

  runApp(const SmartSafetyApp());
}

/// Root widget of the application.
/// Sets up [MaterialApp] with Material 3 theme and initial route.
class SmartSafetyApp extends StatelessWidget {
  const SmartSafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Womens Safety',
      debugShowCheckedModeBanner: false,

      // Apply the centralized Material 3 theme
      theme: AppTheme.lightTheme,

      // The app always starts at the WelcomeScreen
      home: const WelcomeScreen(),
    );
  }
}
