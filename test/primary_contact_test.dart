import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/contact_model.dart';
import 'package:smart_safety/services/contact_service.dart';
import 'package:smart_safety/services/emergency_service.dart';

ContactModel _contact(String id, String phone, {bool primary = false, bool backup = false}) =>
    ContactModel(
      id: id,
      name: 'Contact $id',
      email: '$id@test.local',
      phone: phone,
      relationship: 'Friend',
      isPrimary: primary,
      isBackup: backup,
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

  group('Primary flag storage', () {
    test('existing contacts saved with the legacy forced isPrimary:true are not primary', () {
      final legacy = ContactModel.fromMap({
        'id': 'old_1',
        'name': 'Old Contact',
        'relationship': 'Parent',
        'isPrimary': true,
      });
      expect(legacy.isPrimary, isFalse);
    });

    test('the primary flag survives a save/load round trip (cache and Firestore map)', () {
      final map = _contact('a', '+8801711000001', primary: true).toMap();
      expect(map[ContactModel.primaryKey], isTrue);
      expect(map['isPrimary'], isTrue);
      expect(ContactModel.fromMap(map).isPrimary, isTrue);
      expect(ContactModel.fromMap(_contact('b', '').toMap()).isPrimary, isFalse);
    });

    test('the primary choice is restored from the per-user disk cache', () async {
      await _useContacts([_contact('a', '+8801711000001'), _contact('b', '+8801711000002')]);
      await ContactService.instance.setPrimaryContact('b');
      await ContactService.instance.saveToDiskCache('uid_primary');

      final loaded = await ContactService.instance.loadFromDiskCache('uid_primary');
      expect(loaded.where((c) => c.isPrimary).map((c) => c.id), ['b']);
    });
  });

  group('Only one primary at a time', () {
    test('setting a primary unsets the previous one', () async {
      await _useContacts([
        _contact('a', '+8801711000001'),
        _contact('b', '+8801711000002'),
        _contact('c', '+8801711000003'),
      ]);

      expect(await ContactService.instance.setPrimaryContact('a'), isTrue);
      expect(ContactService.instance.primaryContact?.id, 'a');

      expect(await ContactService.instance.setPrimaryContact('c'), isTrue);
      final primaries = ContactService.instance.contacts.where((c) => c.isPrimary).toList();
      expect(primaries.map((c) => c.id), ['c']);
      expect(ContactService.instance.contactsNotifier.value.where((c) => c.isPrimary).length, 1);
    });

    test('clearing the primary leaves no primary; unknown ids change nothing', () async {
      await _useContacts([_contact('a', '+8801711000001', primary: true), _contact('b', '')]);
      expect(await ContactService.instance.setPrimaryContact('missing'), isFalse);
      expect(ContactService.instance.primaryContact?.id, 'a');

      expect(await ContactService.instance.setPrimaryContact(null), isTrue);
      expect(ContactService.instance.primaryContact, isNull);
    });

    test('deleting the primary contact leaves no primary', () async {
      await _useContacts([_contact('a', '+8801711000001'), _contact('b', '+8801711000002')]);
      await ContactService.instance.setPrimaryContact('a');
      await ContactService.instance.deleteContact('a');
      expect(ContactService.instance.primaryContact, isNull);
      expect(ContactService.instance.contacts.map((c) => c.id), ['b']);
    });
  });

  group('Primary contact is alerted first', () {
    test('primaryFirst moves only the primary and keeps everyone else in order', () {
      final ordered = ContactService.primaryFirst([
        _contact('a', '1'),
        _contact('b', '2'),
        _contact('c', '3', primary: true),
        _contact('d', '4'),
      ]);
      expect(ordered.map((c) => c.id), ['c', 'a', 'b', 'd']);
      expect(ContactService.primaryFirst([_contact('a', '1'), _contact('b', '2')]).map((c) => c.id),
          ['a', 'b']);
    });

    test('phone numbers for SOS follow-ups list the primary first and still include everyone',
        () async {
      await _useContacts([
        _contact('a', '+8801711000001'),
        _contact('b', '+8801711000002'),
        _contact('c', '+8801711000003'),
      ]);
      await ContactService.instance.setPrimaryContact('c');

      final numbers = await ContactService.instance.getEmergencyPhoneNumbers();
      expect(numbers, ['+8801711000003', '+8801711000001', '+8801711000002']);
    });

    test('SOS texts the primary first and still reaches every regular contact', () async {
      await _useContacts([
        _contact('a', '01711000001'),
        _contact('b', '01711000002'),
        _contact('c', '01711000003'),
        _contact('backup', '01711000009', backup: true),
      ]);
      await ContactService.instance.setPrimaryContact('b');

      final result = await EmergencyService.instance.triggerEmergency(source: 'Test SOS');
      final phones = result.recipientPhones;
      expect(phones.length, 3, reason: 'backup contacts stay out of the first wave, as before');
      expect(phones.first, EmergencyService.instance.formatRecipientPhone('01711000002'));
      expect(phones.toSet(), {
        EmergencyService.instance.formatRecipientPhone('01711000001'),
        EmergencyService.instance.formatRecipientPhone('01711000002'),
        EmergencyService.instance.formatRecipientPhone('01711000003'),
      });
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
