import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/contact_model.dart';
import 'package:smart_safety/services/contact_service.dart';
import 'package:smart_safety/services/emergency_service.dart';

ContactModel _contact(String id, String phone, String status) => ContactModel(
      id: id,
      name: 'Contact $id',
      email: '$id@test.local',
      phone: phone,
      relationship: 'Friend',
      contactUid: status == 'offline_only' ? null : 'uid_$id',
      isSyncedAppUser: status == 'synced',
      syncStatus: status,
    );

Future<void> _useContacts(List<ContactModel> contacts) async {
  await ContactService.instance.clearContacts();
  for (final c in contacts) {
    await ContactService.instance.addContact(c);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ContactService.instance.resetMemoryCache();
    EmergencyService.instance.updateContacts([]);
  });

  group('Who may be alerted', () {
    test('a contact whose request is still pending gets no alert on any channel', () {
      final pending = _contact('p', '01711000001', 'pending');
      expect(pending.canReceiveAlerts, isFalse);
      expect(pending.canReceiveAppAlerts, isFalse);
      expect(pending.alertChannels, ['No alert channel']);
    });

    test('an accepted guardian gets SMS and the in-app alert', () {
      final synced = _contact('s', '01711000002', 'synced');
      expect(synced.canReceiveAlerts, isTrue);
      expect(synced.canReceiveAppAlerts, isTrue);
      expect(synced.alertChannels, ['SMS', 'App']);
    });

    test('a contact without an app account (cannot accept a request) gets no alert either', () {
      final offline = _contact('o', '01711000003', 'offline_only');
      expect(offline.canReceiveAlerts, isFalse);
      expect(offline.canReceiveAppAlerts, isFalse);
      expect(offline.alertChannels, ['No alert channel']);
    });

    test('follow-up SMS (journey, ride, battery, escalation) go to accepted guardians only',
        () async {
      await _useContacts([
        _contact('p', '+8801711000001', 'pending'),
        _contact('s', '+8801711000002', 'synced'),
        _contact('o', '+8801711000003', 'offline_only'),
      ]);
      final numbers = await ContactService.instance.getEmergencyPhoneNumbers();
      expect(numbers, ['+8801711000002']);
    });
  });

  group('SOS', () {
    test('is not texted to a contact who has not accepted the request', () async {
      await _useContacts([
        _contact('p', '01711000001', 'pending'),
        _contact('s', '01711000002', 'synced'),
      ]);
      final result =
          await EmergencyService.instance.triggerEmergency(source: 'Test SOS', origin: SosOrigin.manual);
      expect(result.recipientPhones, [EmergencyService.instance.formatRecipientPhone('01711000002')]);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('sends nothing when no contact has accepted yet, and says why', () async {
      await _useContacts([
        _contact('p1', '01711000001', 'pending'),
        _contact('o1', '01711000002', 'offline_only'),
      ]);
      final result =
          await EmergencyService.instance.triggerEmergency(source: 'Test SOS', origin: SosOrigin.manual);
      expect(result.isSuccess, isFalse);
      expect(result.hasNoRecipients, isTrue);
      expect(result.recipientPhones, isEmpty);
      expect(result.message, contains('accepted'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
