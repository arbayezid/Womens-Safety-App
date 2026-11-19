import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/widgets/ui/app_snack.dart';
import 'package:smart_safety/widgets/ui/battery_chip.dart';
import 'package:smart_safety/widgets/ui/channel_chip.dart';
import 'package:smart_safety/widgets/ui/status_label.dart';
import 'package:smart_safety/widgets/ui/ui_tone.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('StatusLabel', () {
    for (final tone in UiTone.values) {
      testWidgets('renders text and an indicator for $tone', (tester) async {
        await tester.pumpWidget(_host(StatusLabel('Status ${tone.name}', tone: tone)));
        expect(find.text('Status ${tone.name}'), findsOneWidget);
        if (tone == UiTone.live) {
          expect(find.byType(FadeTransition), findsWidgets);
        } else {
          expect(find.byIcon(tone.icon), findsOneWidget);
        }
      });
    }

    testWidgets('custom icon replaces the tone icon', (tester) async {
      await tester.pumpWidget(_host(const StatusLabel('Ride in progress', tone: UiTone.info, icon: Icons.local_taxi_rounded)));
      expect(find.byIcon(Icons.local_taxi_rounded), findsOneWidget);
      expect(find.byIcon(UiTone.info.icon), findsNothing);
    });
  });

  group('BatteryChip', () {
    test('icon follows the charge level', () {
      expect(BatteryChip.iconFor(5), Icons.battery_alert_rounded);
      expect(BatteryChip.iconFor(30), Icons.battery_2_bar_rounded);
      expect(BatteryChip.iconFor(60), Icons.battery_5_bar_rounded);
      expect(BatteryChip.iconFor(95), Icons.battery_full_rounded);
    });

    testWidgets('shows the percentage and suffix', (tester) async {
      await tester.pumpWidget(_host(const BatteryChip(82, suffix: ' battery')));
      expect(find.text('82% battery'), findsOneWidget);
      expect(find.byIcon(Icons.battery_full_rounded), findsOneWidget);
    });
  });

  testWidgets('ChannelChip shows label and icon for every channel', (tester) async {
    await tester.pumpWidget(_host(Column(children: [for (final c in AlertChannel.values) ChannelChip(c)])));
    for (final c in AlertChannel.values) {
      expect(find.text(c.label), findsOneWidget);
      expect(find.byIcon(c.icon), findsOneWidget);
    }
  });

  testWidgets('SnackContent puts the tone icon before the message', (tester) async {
    await tester.pumpWidget(_host(const SnackContent('Profile saved.', tone: UiTone.success)));
    expect(find.text('Profile saved.'), findsOneWidget);
    expect(find.byIcon(UiTone.success.icon), findsOneWidget);
  });
}
