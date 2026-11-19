import 'package:flutter/material.dart';

import '../../core/app_text.dart';
import 'ui_tone.dart';

/// Snackbar body: a tone icon followed by the message.
///
/// The icon takes the snackbar's text colour, so it reads on the default dark
/// snackbar and on coloured ones (red, green) alike.
class SnackContent extends StatelessWidget {
  const SnackContent(this.message, {super.key, required this.tone, this.style, this.icon});

  final String message;
  final UiTone tone;
  final TextStyle? style;

  /// Replaces the tone's default icon (e.g. a speaker for the siren).
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final inherited = DefaultTextStyle.of(context).style;
    final color = style?.color ?? inherited.color;
    return Row(
      children: [
        Icon(icon ?? tone.icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: style)),
      ],
    );
  }
}

/// The only way the app shows a snackbar.
///
/// [ScaffoldMessenger.showSnackBar] queues: each bar waits for the previous one to time out, so
/// quick taps (e.g. the siren on/off) leave a backlog that keeps appearing long after the user
/// stopped, often contradicting the current state. Every method here first drops the queue and
/// removes the visible bar, so the newest message shows at once and nothing stale follows it.
class AppSnack {
  AppSnack._();

  /// Default display time for short status messages.
  static const Duration shortDuration = Duration(milliseconds: 2000);

  /// Shows a floating snackbar with a tone icon, replacing any current or queued one.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? show(
    BuildContext context,
    String message, {
    UiTone tone = UiTone.info,
    Duration duration = shortDuration,
    SnackBarAction? action,
    Color? backgroundColor,
  }) {
    return showBar(
      context,
      SnackBar(
        content: SnackContent(message, tone: tone, style: AppText.body.copyWith(color: Colors.white)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: backgroundColor,
        duration: duration,
        persist: false,
        action: action,
      ),
    );
  }

  /// Shows a custom [bar], replacing any current or queued snackbar.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showBar(
    BuildContext context,
    SnackBar bar,
  ) {
    return showOn(ScaffoldMessenger.maybeOf(context), bar);
  }

  /// Same as [showBar] for a messenger captured before an async gap.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showOn(
    ScaffoldMessengerState? messenger,
    SnackBar bar,
  ) {
    if (messenger == null || !messenger.mounted) return null;
    dismiss(messenger);
    return messenger.showSnackBar(bar);
  }

  /// Removes the visible snackbar and everything queued behind it.
  static void dismiss(ScaffoldMessengerState? messenger) {
    if (messenger == null || !messenger.mounted) return;
    // clearSnackBars drops the queue; removeCurrentSnackBar then takes the visible bar off
    // without its exit animation, so the next bar can slide in immediately.
    messenger
      ..clearSnackBars()
      ..removeCurrentSnackBar();
  }
}
