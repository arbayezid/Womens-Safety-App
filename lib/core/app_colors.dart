import 'package:flutter/material.dart';

/// Centralized color palette for the Smart Safety application.
/// All UI colors should be referenced from this class to ensure
/// design consistency across the entire app.
class AppColors {
  AppColors._(); // Prevent instantiation

  // --- Primary Brand Colors ---
  /// The main brand color: vibrant Royal Purple/Blue
  static const Color primary = Color(0xFF5A4FCF);

  /// A slightly lighter variant of the primary for accents
  static const Color primaryLight = Color(0xFF7B72DB);

  /// Very light purple for avatar backgrounds and subtle highlights
  static const Color primarySurface = Color(0xFFEDE9FF);

  // --- Background Colors ---
  /// App-wide light off-white background
  static const Color background = Color(0xFFF4F6F9);

  /// Pure white for cards and elevated surfaces
  static const Color surface = Color(0xFFFFFFFF);

  // --- SOS / Alert Colors ---
  /// The bold SOS red for the main emergency button
  static const Color sosRed = Color(0xFFFF3B30);

  /// Medium-intensity pink/red for the second ripple ring
  static const Color sosMediumRing = Color(0xFFFFB3AE);

  /// Very light pink/red for the outer ripple ring
  static const Color sosOuterRing = Color(0xFFFFDDDB);

  // --- Status Colors ---
  /// Light green background for the "ESP32 Connected" badge
  static const Color successBackground = Color(0xFFDFF5E3);

  /// Dark green for text and dot in the success badge
  static const Color successForeground = Color(0xFF27AE60);

  // --- Quick Action Icon Colors ---
  /// Blue for the "Fake Call" action
  static const Color actionBlue = Color(0xFF4A90E2);

  /// Orange/Amber for the "Loud Siren" action
  static const Color actionOrange = Color(0xFFF5A623);

  /// Purple for the "Record Audio" action
  static const Color actionPurple = Color(0xFF9B59B6);

  /// Green for the "Safe Route" action
  static const Color actionGreen = Color(0xFF27AE60);

  // --- Text Colors ---
  /// Primary text color
  static const Color textPrimary = Color(0xFF1A1A2E);

  /// Secondary / subtitle text color
  static const Color textSecondary = Color(0xFF8E8E93);

  /// Light text used on dark/colored backgrounds
  static const Color textOnPrimary = Color(0xFFFFFFFF);
}
