import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/contact_model.dart';
import 'package:smart_safety/services/contact_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ContactModel Tests', () {
    test('Serializes to Map and JSON correctly', () {
      const contact = ContactModel(
        id: 'c1',
        name: 'Fatima Rahman',
        phone: '+8801712345678',
        relationship: 'Sister',
        isPrimary: true,
      );

      final map = contact.toMap();
      expect(map['id'], 'c1');
      expect(map['name'], 'Fatima Rahman');
      expect(map['phone'], '+8801712345678');
      expect(map['relationship'], 'Sister');
      expect(map['isPrimary'], true);

      final jsonStr = contact.toJson();
      final fromJson = ContactModel.fromJson(jsonStr);
      expect(fromJson, contact);
      expect(fromJson.initial, 'F');
    });

    test('copyWith works properly', () {
      const contact = ContactModel(
        id: 'c1',
        name: 'Ayesha',
        phone: '+8801812345678',
        relationship: 'Friend',
        isPrimary: false,
      );

      final updated = contact.copyWith(isPrimary: true, name: 'Ayesha Khan');
      expect(updated.id, 'c1');
      expect(updated.name, 'Ayesha Khan');
      expect(updated.phone, '+8801812345678');
      expect(updated.isPrimary, true);
    });
  });

  group('ContactService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Initializes with default contacts when storage is empty', () async {
      final contacts = await ContactService.instance.getContacts();

      expect(contacts.length, 3);
      expect(contacts[0].name, 'Mom');
      expect(contacts[0].phone, '+8801711000001');
      expect(contacts[0].isPrimary, true);

      expect(contacts[1].name, 'Dad');
      expect(contacts[1].isPrimary, true);

      expect(contacts[2].name, 'Riya Sharma');
      expect(contacts[2].isPrimary, false);
    });

    test('Adds a new contact and persists it', () async {
      const newContact = ContactModel(
        id: 'test_101',
        name: 'Doctor Helpline',
        phone: '+8801999999999',
        relationship: 'Doctor',
        isPrimary: true,
      );

      final addResult = await ContactService.instance.addContact(newContact);
      expect(addResult, isTrue);

      final contacts = await ContactService.instance.getContacts();
      expect(contacts.any((c) => c.id == 'test_101'), isTrue);
      expect(contacts.firstWhere((c) => c.id == 'test_101').phone, '+8801999999999');
    });

    test('Updates an existing contact', () async {
      // First get default contacts
      final contacts = await ContactService.instance.getContacts();
      final mom = contacts.firstWhere((c) => c.name == 'Mom');

      final updatedMom = mom.copyWith(phone: '+8801799887766', relationship: 'Mother');
      final updateResult = await ContactService.instance.updateContact(updatedMom);
      expect(updateResult, isTrue);

      final reloaded = await ContactService.instance.getContacts();
      final reloadedMom = reloaded.firstWhere((c) => c.id == mom.id);
      expect(reloadedMom.phone, '+8801799887766');
      expect(reloadedMom.relationship, 'Mother');
    });

    test('Deletes a contact by ID', () async {
      final contacts = await ContactService.instance.getContacts();
      final initialCount = contacts.length;
      final target = contacts.last;

      final deleteResult = await ContactService.instance.deleteContact(target.id);
      expect(deleteResult, isTrue);

      final reloaded = await ContactService.instance.getContacts();
      expect(reloaded.length, initialCount - 1);
      expect(reloaded.any((c) => c.id == target.id), isFalse);
    });

    test('getEmergencyPhoneNumbers extracts active numbers', () async {
      final allNumbers = await ContactService.instance.getEmergencyPhoneNumbers();
      expect(allNumbers, contains('+8801711000001'));
      expect(allNumbers, contains('+8801933000003'));
      expect(allNumbers, contains('+8801822000002'));

      final primaryOnly = await ContactService.instance.getEmergencyPhoneNumbers(primaryOnly: true);
      expect(primaryOnly, contains('+8801711000001'));
      expect(primaryOnly, contains('+8801933000003'));
      expect(primaryOnly, isNot(contains('+8801822000002')));
    });

    test('Bangladesh phone number regex validation', () {
      final bdPhoneRegex = RegExp(r'^(\+8801|01)[3-9]\d{8}$');

      // Valid numbers
      expect(bdPhoneRegex.hasMatch('+8801712345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('01712345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('+8801812345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('01912345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('+8801312345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('01412345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('+8801512345678'), isTrue);
      expect(bdPhoneRegex.hasMatch('01612345678'), isTrue);

      // Invalid numbers
      expect(bdPhoneRegex.hasMatch('12345'), isFalse);
      expect(bdPhoneRegex.hasMatch('+14155552671'), isFalse);
      expect(bdPhoneRegex.hasMatch('01212345678'), isFalse); // operator 2 doesn't exist in BD
      expect(bdPhoneRegex.hasMatch('0171234567'), isFalse); // too short
      expect(bdPhoneRegex.hasMatch('017123456789'), isFalse); // too long
    });
  });
}
