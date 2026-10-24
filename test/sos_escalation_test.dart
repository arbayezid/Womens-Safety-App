import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/contact_model.dart';
import 'package:smart_safety/services/sos_escalation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 2: ContactModel isBackup Tests', () {
    test('ContactModel default isBackup is false', () {
      const contact = ContactModel(
        id: 'c1',
        name: 'Regular Contact',
        email: 'regular@example.com',
        relationship: 'Friend',
      );
      expect(contact.isBackup, isFalse);
    });

    test('ContactModel isBackup serializes and deserializes correctly', () {
      const backup = ContactModel(
        id: 'c2',
        name: 'Backup Uncle',
        email: 'backup@example.com',
        phone: '+8801711111111',
        relationship: 'Family',
        isBackup: true,
      );

      final map = backup.toMap();
      expect(map['isBackup'], isTrue);
      expect(map['is_backup'], isTrue);

      final fromMap = ContactModel.fromMap(map);
      expect(fromMap.isBackup, isTrue);
      expect(fromMap.id, equals('c2'));
      expect(fromMap.name, equals('Backup Uncle'));

      final json = backup.toJson();
      final fromJson = ContactModel.fromJson(json);
      expect(fromJson.isBackup, isTrue);

      final copy = backup.copyWith(isBackup: false);
      expect(copy.isBackup, isFalse);
    });
  });

  group('Phase 2: SosEscalationService Pure Timing & Configuration Tests', () {
    test('Default escalation configuration matches specifications (3m / 8m)', () {
      final service = SosEscalationService.instance;
      expect(service.config.stage1Seconds, equals(180)); // 3 minutes
      expect(service.config.stage2Seconds, equals(480)); // 8 minutes
    });

    test('Custom escalation configuration updates correctly', () {
      final service = SosEscalationService.instance;
      service.setConfig(const EscalationConfig(stage1Seconds: 10, stage2Seconds: 25));
      expect(service.config.stage1Seconds, equals(10));
      expect(service.config.stage2Seconds, equals(25));

      // Reset back to production defaults
      service.setConfig(const EscalationConfig());
      expect(service.config.stage1Seconds, equals(180));
    });

    test('Stop escalation resets active state and sets stage to resolved', () {
      final service = SosEscalationService.instance;
      service.stopEscalation();
      expect(service.isEscalating, isFalse);
      expect(service.currentStageNotifier.value, equals(EscalationStage.resolved));
    });
  });
}
