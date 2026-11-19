import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/app_text.dart';

/// Battery icon that matches the charge level, followed by the percentage.
class BatteryChip extends StatelessWidget {
  const BatteryChip(this.level, {super.key, this.style, this.color, this.suffix = ''});

  final int level;
  final TextStyle? style;

  /// Colour for icon and text. Defaults to the text style's colour; at 15% or
  /// lower the icon turns SOS red.
  final Color? color;

  /// Extra words after the percentage, e.g. " battery".
  final String suffix;

  static IconData iconFor(int level) {
    if (level <= 15) return Icons.battery_alert_rounded;
    if (level <= 35) return Icons.battery_2_bar_rounded;
    if (level <= 70) return Icons.battery_5_bar_rounded;
    return Icons.battery_full_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = (style ?? AppText.caption).copyWith(color: color ?? style?.color);
    final size = (textStyle.fontSize ?? 11) + 3;
    final iconColor = level <= 15 ? AppColors.sosRed : (textStyle.color ?? DefaultTextStyle.of(context).style.color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(iconFor(level), size: size, color: iconColor),
        const SizedBox(width: 2),
        Text('$level%$suffix', style: textStyle),
      ],
    );
  }
}
