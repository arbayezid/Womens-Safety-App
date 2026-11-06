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
