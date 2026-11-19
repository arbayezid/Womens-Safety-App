import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Emoji in user-facing strings read as auto-generated UI; states are shown with
/// Material icons instead (see lib/widgets/ui). Debug logs may still use emoji.
void main() {
  final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{23F1}]', unicode: true);
  final logLine = RegExp(r'debugPrint|print\(|log\(|^\s*//');

  test('no emoji in user-facing strings', () {
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets', 'lib/services']) {
      for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (logLine.hasMatch(line)) continue;
          if (emoji.hasMatch(line)) offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
