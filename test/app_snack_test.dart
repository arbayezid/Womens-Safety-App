import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/widgets/ui/app_snack.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      })),
    ));
    return ctx;
  }

  SnackBar bar(String text) =>
      SnackBar(content: Text(text), duration: const Duration(seconds: 2));

  testWidgets('a new snackbar replaces the current one and nothing queues behind it',
      (tester) async {
    final context = await pumpHost(tester);

    // Rapid on/off taps.
    for (var i = 0; i < 8; i++) {
      AppSnack.showBar(context, bar(i.isEven ? 'Siren on' : 'Siren off'));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('Siren off'), findsOneWidget);
    expect(find.text('Siren on'), findsNothing);

    // Let it time out: no stale bar may follow.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('different actions back to back show only the latest', (tester) async {
    final context = await pumpHost(tester);

    AppSnack.show(context, 'Fake call in 10s');
    await tester.pump(const Duration(milliseconds: 300));
    AppSnack.showBar(context, bar('Siren on'));
    await tester.pump(const Duration(milliseconds: 300));
    AppSnack.showOn(ScaffoldMessenger.of(context), bar('Ride check-in started'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('Ride check-in started'), findsOneWidget);
    expect(find.text('Fake call in 10s'), findsNothing);
    expect(find.text('Siren on'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}
