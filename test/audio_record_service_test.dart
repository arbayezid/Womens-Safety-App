import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/audio_record_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioRecordService Unit Tests', () {
    test('Initial states are idle and duration is 0', () {
      final service = AudioRecordService.instance;
      expect(service.isRecordingNotifier.value, isFalse);
      expect(service.durationNotifier.value, 0);
      expect(service.currentLocalPath, isNull);
    });

    test('AudioDispatchResult models success and failure properly', () {
      const successResult = AudioDispatchResult(
        isSuccess: true,
        message: 'Audio alert sent successfully!',
        audioUrl: 'https://storage.googleapis.com/audio/test.m4a',
        alertId: 'alert_123',
        smsSentCount: 2,
        totalRecipients: 3,
      );

      expect(successResult.isSuccess, isTrue);
      expect(successResult.message, 'Audio alert sent successfully!');
      expect(successResult.audioUrl, contains('.m4a'));
      expect(successResult.smsSentCount, 2);
      expect(successResult.totalRecipients, 3);

      const failResult = AudioDispatchResult(
        isSuccess: false,
        message: 'Audio recording file not found.',
      );

      expect(failResult.isSuccess, isFalse);
      expect(failResult.message, contains('not found'));
      expect(failResult.audioUrl, isNull);
    });

    test('cleanupLocalCache handles null current path without crashing', () async {
      final service = AudioRecordService.instance;
      await service.cleanupLocalCache();
      expect(service.currentLocalPath, isNull);
    });
  });
}
