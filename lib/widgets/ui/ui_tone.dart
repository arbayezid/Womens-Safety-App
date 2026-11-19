import 'package:flutter/material.dart';

import '../../core/app_colors.dart';

/// The meaning of a status: drives the icon and colour of status labels and snackbars.
enum UiTone {
  critical(Icons.emergency_rounded, AppColors.sosRed),
  warning(Icons.warning_amber_rounded, AppColors.actionOrange),
  success(Icons.check_circle_rounded, AppColors.safeGreen),
  info(Icons.info_outline_rounded, AppColors.primary),
  live(Icons.circle, AppColors.sosRed);

  const UiTone(this.icon, this.color);

  final IconData icon;
  final Color color;
}
