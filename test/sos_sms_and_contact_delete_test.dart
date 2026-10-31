import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/contact_model.dart';
import 'package:smart_safety/services/contact_service.dart';
import 'package:smart_safety/services/emergency_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SOS SMS message format', () {
    final service = EmergencyService.instance;
    final time = DateTime(2026, 10, 30, 22, 42);

    test('uses the required EMERGENCY format with a maps.google.com link and time', () {
      final msg = service.buildSosSmsMessage(
        userName: 'Nusrat',
        latitude: 23.7614038,
        longitude: 90.4453419,
        time: time,
      );
      expect(
        msg,
        'EMERGENCY! Nusrat needs help. Live location: '
        'https://maps.google.com/?q=23.761404,90.445342  Time: 10:42 PM, 30 Oct 2026',
      );
    });

    test('still sends text when location is unavailable', () {
      final msg = service.buildSosSmsMessage(userName: 'Nusrat', time: time);
      expect(msg, contains('EMERGENCY! Nusrat needs help.'));
      expect(msg, contains('Live location: Location unavailable'));
      expect(msg, contains('Time: 10:42 PM, 30 Oct 2026'));
    });

    test('custom messages keep their text and gain the location link', () {
      final msg = service.buildSosSmsMessage(
        userName: 'Nusrat',
        latitude: 1.5,
        longitude: 2.25,
        time: time,
        customMessage: 'AUTOMATIC SOS: A fall impact was detected.',
      );
      expect(msg, startsWith('AUTOMATIC SOS: A fall impact was detected. Live location: '));
      expect(msg, contains('https://maps.google.com/?q=1.500000,2.250000'));
    });

    test('falls back to a generic name and formats midnight/noon correctly', () {
      expect(service.buildSosSmsMessage(userName: '  ', time: time), startsWith('EMERGENCY! A Woman Guard user needs help.'));
      expect(service.formatSmsTime(DateTime(2026, 1, 5, 0, 7)), '12:07 AM, 5 Jan 2026');
      expect(service.formatSmsTime(DateTime(2026, 12, 31, 12, 0)), '12:00 PM, 31 Dec 2026');
    });

    test('follow-up message carries the fresh live location', () {
      final msg = service.buildSosLocationUpdateMessage(
        userName: 'Nusrat',
        latitude: 23.8,
        longitude: 90.4,
        time: time,
      );
      expect(msg, startsWith('EMERGENCY UPDATE: Nusrat needs help. Live location: https://maps.google.com/?q=23.800000,90.400000'));
    });
  });

  group('Contact deletion stays deleted', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ContactService.instance.resetMemoryCache();
    });

    test('a stale cloud snapshot cannot bring a deleted contact back', () async {
      final before = await ContactService.instance.getContacts();
      final mom = before.firstWhere((c) => c.id == 'default_1');

      expect(await ContactService.instance.deleteContact(mom.id), isTrue);

      // A sync carrying data read before the delete (the old resurrection path)
      ContactService.instance.syncFromCloud(before);

      final after = await ContactService.instance.getContacts(forceRefresh: true);
      expect(after.any((c) => c.id == 'default_1'), isFalse);
      expect(ContactService.instance.contactsNotifier.value.any((c) => c.id == 'default_1'), isFalse);
    });

    test('a deleted contact never receives SOS SMS', () async {
      await ContactService.instance.getContacts();
      await ContactService.instance.deleteContact('default_1');
      final numbers = await ContactService.instance.getEmergencyPhoneNumbers();
      expect(numbers, isNot(contains('+8801711000001')));
    });

    test('re-adding the same contact makes it visible again', () async {
      final before = await ContactService.instance.getContacts();
      final mom = before.firstWhere((c) => c.id == 'default_1');
      await ContactService.instance.deleteContact(mom.id);

      expect(await ContactService.instance.addContact(mom), isTrue);
      ContactService.instance.syncFromCloud([mom]);

      final after = await ContactService.instance.getContacts();
      expect(after.map((c) => c.id), contains('default_1'));
    });

    test('deleting removes every duplicate of the same person', () async {
      await ContactService.instance.getContacts();
      await ContactService.instance.addContact(const ContactModel(
        id: 'offline_dup',
        name: 'Mom (old)',
        email: 'mom@family.local',
        phone: '',
        relationship: 'Family',
        isPrimary: true,
      ));

      await ContactService.instance.deleteContact('default_1', email: 'mom@family.local');
      final after = await ContactService.instance.getContacts();
      expect(after.any((c) => c.email == 'mom@family.local'), isFalse);
    });
  });
}
