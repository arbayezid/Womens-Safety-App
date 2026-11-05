import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/fake_caller.dart';
import 'package:smart_safety/services/fake_call_audio_service.dart';
import 'package:smart_safety/services/fake_call_settings_service.dart';
import 'package:smart_safety/widgets/fake_call_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Issue 4: FakeCaller', () {
    test('presets show their own name, never a contact or profile name', () {
      expect(const FakeCaller(FakeCallerPreset.ammu).name, 'Ammu');
      expect(const FakeCaller(FakeCallerPreset.abbu).name, 'Abbu');
      expect(const FakeCaller(FakeCallerPreset.bhaiya).name, 'Bhaiya');
      expect(const FakeCaller(FakeCallerPreset.police).name, 'Police Station');
      expect(const FakeCaller(FakeCallerPreset.office).name, 'Office');
      expect(FakeCaller.defaultCaller.preset, FakeCallerPreset.ammu);
    });

    test('presets ignore stray custom fields', () {
      const caller = FakeCaller(FakeCallerPreset.ammu, customName: 'Fatima', customPhone: '017');
      expect(caller.name, 'Ammu');
      expect(caller.phone, isEmpty);
      expect(caller.subtitle, 'Mobile');
    });

    test('custom name and optional number', () {
      const withNumber = FakeCaller(FakeCallerPreset.custom, customName: ' Rina Apu ', customPhone: ' +880 1711-223344 ');
      expect(withNumber.name, 'Rina Apu');
      expect(withNumber.phone, '+880 1711-223344');
      expect(withNumber.subtitle, '+880 1711-223344');
      expect(withNumber.avatarLetter, 'R');

      const noNumber = FakeCaller(FakeCallerPreset.custom, customName: 'Nanu');
      expect(noNumber.subtitle, 'Phone');
      expect(noNumber.isValid, isTrue);

      expect(const FakeCaller(FakeCallerPreset.custom, customName: '   ').isValid, isFalse);
    });

    test('Bangla custom names get a Bangla letter avatar', () {
      const caller = FakeCaller(FakeCallerPreset.custom, customName: 'নানু');
      expect(caller.avatarLetter, 'না');
    });

    test('detects the user own profile name', () {
      const caller = FakeCaller(FakeCallerPreset.custom, customName: 'Fatima Akter');
      expect(caller.usesOwnName('fatima akter'), isTrue);
      expect(caller.usesOwnName('Someone Else'), isFalse);
      expect(caller.usesOwnName(null), isFalse);
      expect(const FakeCaller(FakeCallerPreset.custom, customName: 'Guest').usesOwnName('Guest'), isFalse);
    });
  });

  group('Issue 4: caller preference is remembered', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to Ammu', () async {
      final caller = await FakeCallSettingsService.instance.loadCaller();
      expect(caller, FakeCaller.defaultCaller);
    });

    test('custom caller survives a restart (reload from prefs)', () async {
      const custom = FakeCaller(FakeCallerPreset.custom, customName: 'Rina Apu', customPhone: '+8801711223344');
      await FakeCallSettingsService.instance.saveCaller(custom);
      // Simulate a restart: the in-memory notifier is reset, prefs are kept.
      FakeCallSettingsService.instance.callerNotifier.value = FakeCaller.defaultCaller;
      final reloaded = await FakeCallSettingsService.instance.loadCaller();
      expect(reloaded, custom);
      expect(FakeCallSettingsService.instance.callerNotifier.value, custom);
    });

    test('picking a preset keeps the last custom name for the picker', () async {
      await FakeCallSettingsService.instance
          .saveCaller(const FakeCaller(FakeCallerPreset.custom, customName: 'Nanu'));
      await FakeCallSettingsService.instance.saveCaller(const FakeCaller(FakeCallerPreset.police));
      expect((await FakeCallSettingsService.instance.loadCaller()).name, 'Police Station');
      expect((await FakeCallSettingsService.instance.lastCustomCaller()).customName, 'Nanu');
    });

    test('an invalid saved custom caller falls back to Ammu', () async {
      SharedPreferences.setMockInitialValues({FakeCallSettingsService.prefCallerPreset: 'custom'});
      expect(await FakeCallSettingsService.instance.loadCaller(), FakeCaller.defaultCaller);
    });

    test('resolveCaller uses the saved caller unless one is passed', () async {
      await FakeCallSettingsService.instance.saveCaller(const FakeCaller(FakeCallerPreset.office));
      expect((await FakeCallDialog.resolveCaller(null)).name, 'Office');
      expect((await FakeCallDialog.resolveCaller(const FakeCaller(FakeCallerPreset.abbu))).name, 'Abbu');
    });

    test('voice language defaults to Bangla and is remembered', () async {
      expect(await FakeCallSettingsService.instance.loadLanguage(), FakeCallVoiceLanguage.bangla);
      await FakeCallSettingsService.instance.saveLanguage(FakeCallVoiceLanguage.english);
      expect(await FakeCallSettingsService.instance.loadLanguage(), FakeCallVoiceLanguage.english);
    });
  });

  group('Issue 5: voice playback priority', () {
    const realClip = 120 * 1024;
    const placeholder = 2080;

    Future<FakeCallVoiceSource> resolve(
      FakeCallerPreset preset,
      FakeCallVoiceLanguage language, {
      String? recording,
      int clipSize = realClip,
    }) {
      return resolveFakeCallVoice(
        preset: preset,
        language: language,
        userRecordingPath: (_) async => recording,
        bundledAssetSize: (_) async => clipSize,
      );
    }

    test('user recording wins over the bundled clip', () async {
      final source = await resolve(FakeCallerPreset.ammu, FakeCallVoiceLanguage.bangla, recording: '/data/ammu.m4a');
      expect(source, const FakeCallVoiceSource(FakeCallVoiceKind.userRecording, '/data/ammu.m4a'));
    });

    test('user recording also wins when English is selected', () async {
      final source = await resolve(FakeCallerPreset.abbu, FakeCallVoiceLanguage.english, recording: '/data/abbu.m4a');
      expect(source.kind, FakeCallVoiceKind.userRecording);
    });

    test('Bangla plays the bundled clip for that caller', () async {
      for (final p in FakeCallerPreset.values.where((p) => p != FakeCallerPreset.custom)) {
        final source = await resolve(p, FakeCallVoiceLanguage.bangla);
        expect(source, FakeCallVoiceSource(FakeCallVoiceKind.bundledBangla, 'assets/fake_call/bn/${p.bundledClipKey}.mp3'));
      }
      expect(bundledBanglaClipPath(FakeCallerPreset.police), 'assets/fake_call/bn/police.mp3');
    });

    test('custom caller uses the generic Bhaiya clip', () async {
      final source = await resolve(FakeCallerPreset.custom, FakeCallVoiceLanguage.bangla);
      expect(source.path, 'assets/fake_call/bn/bhaiya.mp3');
    });

    test('placeholder or missing clip falls back to English', () async {
      expect((await resolve(FakeCallerPreset.ammu, FakeCallVoiceLanguage.bangla, clipSize: placeholder)).kind,
          FakeCallVoiceKind.english);
      expect((await resolve(FakeCallerPreset.ammu, FakeCallVoiceLanguage.bangla, clipSize: 0)).kind,
          FakeCallVoiceKind.english);
    });

    test('English ignores bundled Bangla clips', () async {
      expect((await resolve(FakeCallerPreset.ammu, FakeCallVoiceLanguage.english)).kind, FakeCallVoiceKind.english);
    });

    test('English audio arguments are exactly the original ones', () {
      final args = FakeCallAudioService.conversationArguments(FakeCallVoiceSource.english, speaker: true);
      expect(args['assetPath'], FakeCallAudioService.voiceAssetPath);
      expect(args['script'], FakeCallAudioService.conversationScript);
      expect(args['loopGapMs'], 0);
      expect(args['filePath'], '');
      expect(args['speaker'], true);
    });

    test('recorded clips pass the file or asset with a natural replay gap', () {
      final file = FakeCallAudioService.conversationArguments(
        const FakeCallVoiceSource(FakeCallVoiceKind.userRecording, '/x/ammu.m4a'),
        speaker: false,
      );
      expect(file['filePath'], '/x/ammu.m4a');
      expect(file['assetPath'], '');
      expect(file['loopGapMs'], FakeCallAudioService.recordedClipLoopGapMs);
      expect(file['speaker'], false);

      final asset = FakeCallAudioService.conversationArguments(
        const FakeCallVoiceSource(FakeCallVoiceKind.bundledBangla, 'assets/fake_call/bn/ammu.mp3'),
        speaker: true,
      );
      expect(asset['assetPath'], 'assets/fake_call/bn/ammu.mp3');
      expect(asset['filePath'], '');
    });
  });

  group('Fake call screen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('shows the chosen caller; Accept starts the timer; Speaker toggles to Earpiece',
        (tester) async {
      const caller = FakeCaller(FakeCallerPreset.custom, customName: 'Rina Apu', customPhone: '+880 1711-223344');
      await tester.pumpWidget(const MaterialApp(home: FakeCallDialog(caller: caller)));
      await tester.pump();

      expect(find.text('Rina Apu'), findsOneWidget);
      expect(find.text('+880 1711-223344'), findsOneWidget);
      expect(find.text('Incoming Call...'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.call_rounded));
      await tester.pump();
      expect(find.text('00:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('00:02'), findsOneWidget);
      expect(find.text('Rina Apu'), findsOneWidget);

      // Default output is unchanged (loudspeaker), shown as an active "Speaker" button.
      expect(find.text('Speaker'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await tester.pump();
      expect(find.text('Earpiece'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.phone_in_talk_rounded));
      await tester.pump();
      expect(find.text('Speaker'), findsOneWidget);

      // Dispose the screen so its timers stop.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
