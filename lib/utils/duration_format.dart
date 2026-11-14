/// Formats a minute count for display.
///
/// Below 60 the value is shown as minutes using [suffix] (e.g. `45 min`,
/// `45 mins`, `45m`). From 60 upwards it switches to hours:
/// 70 -> `1h 10min`, 120 -> `2h`.
String formatMinutes(int minutes, {String suffix = ' min'}) {
  if (minutes < 60) return '$minutes$suffix';
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  return mins == 0 ? '${hours}h' : '${hours}h ${mins}min';
}

/// Formats an elapsed duration as a clock: `02:15` below an hour, `1:02:15` from an hour on.
/// Negative durations are shown as `00:00`.
String formatElapsedClock(Duration elapsed) {
  final total = elapsed.isNegative ? 0 : elapsed.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '${two(minutes)}:${two(seconds)}';
}
