import 'package:flutter/material.dart';

import '../../core/app_text.dart';
import 'ui_tone.dart';

/// Snackbar body: a tone icon followed by the message.
///
/// The icon takes the snackbar's text colour, so it reads on the default dark
/// snackbar and on coloured ones (red, green) alike.
class SnackContent extends StatelessWidget {
  const SnackContent(this.message, {super.key, required this.tone, this.style});

  final String message;
  final UiTone tone;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final inherited = DefaultTextStyle.of(context).style;
    final color = style?.color ?? inherited.color;
    return Row(
      children: [
        Icon(tone.icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: style)),
      ],
    );
  }
}

/// Shows a floating snackbar with a tone icon.
class AppSnack {
  AppSnack._();

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? show(
    BuildContext context,
    String message, {
    UiTone tone = UiTone.info,
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
    Color? backgroundColor,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return null;
    return messenger.showSnackBar(
      SnackBar(
        content: SnackContent(message, tone: tone, style: AppText.body.copyWith(color: Colors.white)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: backgroundColor,
        duration: duration,
        action: action,
      ),
    );
  }
}
