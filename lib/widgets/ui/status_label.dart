import 'package:flutter/material.dart';

import '../../core/app_text.dart';
import '../../core/app_tokens.dart';
import 'ui_tone.dart';

/// Icon + text describing a state ("Active", "Delayed", "Marked safe").
///
/// The icon carries the tone so the words don't need an emoji. [color] overrides the
/// tone colour for both icon and text, e.g. white on a coloured banner.
class StatusLabel extends StatelessWidget {
  const StatusLabel(
    this.text, {
    super.key,
    required this.tone,
    this.style,
    this.color,
    this.iconSize,
    this.icon,
    this.background,
    this.maxLines = 1,
  });

  final String text;
  final UiTone tone;
  final TextStyle? style;
  final Color? color;
  final double? iconSize;

  /// Replaces the tone's default icon (e.g. a car for a ride status).
  final IconData? icon;

  /// When set, the label sits on a small rounded pill of this colour.
  final Color? background;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? tone.color;
    final textStyle = (style ?? AppText.label).copyWith(color: fg);
    final size = iconSize ?? ((textStyle.fontSize ?? 12) + 3);

    final Widget leading = tone == UiTone.live && icon == null
        ? _LiveDot(color: fg, size: size * 0.55)
        : Icon(icon ?? tone.icon, size: size, color: fg);

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        leading,
        SizedBox(width: size * 0.3),
        Flexible(
          child: Text(text, style: textStyle, maxLines: maxLines, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    if (background == null) return row;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: row,
    );
  }
}

/// A small dot that gently pulses to mark something as live. Static when the
/// system asks for reduced motion.
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: dot,
    );
  }
}
