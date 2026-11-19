import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Corner radii. Every rounded surface in the app uses one of these values.
class AppRadius {
  AppRadius._();

  /// Drag handles and thin progress bars.
  static const double handle = 2;

  /// Tiny badges.
  static const double xs = 4;

  /// Chips and small buttons.
  static const double sm = 8;

  /// Icon tiles, text fields, buttons and list rows.
  static const double md = 12;

  /// Cards.
  static const double lg = 16;

  /// Dialogs, bottom sheets and hero cards.
  static const double xl = 20;
}

/// Elevation styles. Cards, bars and tinted surfaces share these shadows.
class AppShadow {
  AppShadow._();

  /// White cards on the grey background.
  static const BoxShadow card = BoxShadow(
    color: Color(0x0F000000),
    blurRadius: 12,
    offset: Offset(0, 4),
  );

  /// Bars pinned to the bottom of the screen.
  static const BoxShadow navBar = BoxShadow(
    color: Color(0x14000000),
    blurRadius: 16,
    offset: Offset(0, -4),
  );

  /// Coloured surfaces (brand gradients, alert banners) cast a shadow in their own hue.
  static BoxShadow tinted(Color color) => BoxShadow(
        color: color.withValues(alpha: 0.30),
        blurRadius: 14,
        offset: const Offset(0, 5),
      );

  /// The idle SOS button.
  static final BoxShadow sosButton = BoxShadow(
    color: AppColors.sosRed.withValues(alpha: 0.45),
    blurRadius: 24,
    offset: const Offset(0, 8),
    spreadRadius: 2,
  );
}
