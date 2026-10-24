import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/contact_model.dart';
import 'package:smart_safety/screens/sos_history_screen.dart';
import 'package:smart_safety/services/contact_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4.1: Dispatch Routing Tests', () {
    test('Phone only contact routes to SMS only', () {
      const contact = ContactModel(
        id: 'c_phone_only',
        name: 'Phone Guardian',
        phone: '+8801711223344',
        email: '',
        relationship: 'Family',
      );

      final channels = contact.alertChannels;
      expect(channels, contains('SMS'));
      expect(channels, isNot(contains('App')));
      expect(channels, isNot(contains('No alert channel')));
    });

    test('Email only synced contact routes to Cloud SOS only', () {
      const contact = ContactModel(
        id: 'c_email_only',
        name: 'Email Guardian',
        phone: '',
        email: 'guardian@app.local',
        relationship: 'Friend',
        isSyncedAppUser: true,
        syncStatus: 'synced',
      );

      final channels = contact.alertChannels;
      expect(channels, isNot(contains('SMS')));
      expect(channels, contains('App'));
      expect(channels, isNot(contains('No alert channel')));
    });

    test('Phone + Synced contact routes to both channels', () {
      const contact = ContactModel(
        id: 'c_both',
        name: 'Dual Guardian',
        phone: '+8801711223344',
        email: 'guardian@app.local',
        relationship: 'Family',
        isSyncedAppUser: true,
        syncStatus: 'synced',
      );

      final channels = contact.alertChannels;
      expect(channels, contains('SMS'));
      expect(channels, contains('App'));
      expect(channels.length, 2);
    });

    test('Contact with neither phone nor synced app status is flagged as No alert channel', () {
      const contact = ContactModel(
        id: 'c_none',
        name: 'Empty Guardian',
        phone: '   ',
        email: '   ',
        relationship: 'Other',
      );

      final channels = contact.alertChannels;
      expect(channels, contains('No alert channel'));
      expect(channels.length, 1);
    });
  });

  group('Phase 4.1: Channel Badges Tests', () {
    test('alertChannels returns correct badges for each configuration', () {
      const smsOnly = ContactModel(
        id: '1',
        name: 'A',
        phone: '01700000000',
        email: '',
        relationship: 'Friend',
      );
      expect(smsOnly.alertChannels, ['SMS']);

      const appOnly = ContactModel(
        id: '2',
        name: 'B',
        phone: '',
        email: 'b@app.com',
        relationship: 'Friend',
        isSyncedAppUser: true,
        syncStatus: 'synced',
      );
      expect(appOnly.alertChannels, ['App']);

      const dual = ContactModel(
        id: '3',
        name: 'C',
        phone: '01700000000',
        email: 'c@app.com',
        relationship: 'Sister',
        isSyncedAppUser: true,
        syncStatus: 'synced',
      );
      expect(dual.alertChannels, ['SMS', 'App']);

      const neither = ContactModel(
        id: '4',
        name: 'D',
        phone: '',
        email: '',
        relationship: 'Other',
      );
      expect(neither.alertChannels, ['No alert channel']);
    });
  });

  group('Phase 4.1: Email Normalization Tests', () {
    test('Email with mixed case and whitespace is trimmed and lowercased on ContactModel', () {
      final contact = ContactModel.fromMap({
        'id': 'norm_1',
        'name': 'Test User',
        'email': '  User.NAME@Example.COM  ',
        'phone': '+8801711223344',
        'relationship': 'Colleague',
      });

      expect(contact.email, 'user.name@example.com');
      expect(contact.toMap()['email'], 'user.name@example.com');
      expect(contact.toMap()['contact_email'], 'user.name@example.com');
    });

    test('Duplicate contact checks in ContactService match regardless of case/whitespace', () async {
      SharedPreferences.setMockInitialValues({});
      ContactService.instance.resetMemoryCache();
      await ContactService.instance.clearContacts();

      const initial = ContactModel(
        id: 'c_initial',
        name: 'Initial Name',
        email: 'trusted@guard.org',
        phone: '+8801700112233',
        relationship: 'Family',
      );
      await ContactService.instance.addContact(initial);
      expect((await ContactService.instance.getContacts()).length, 1);

      // Add same email with mixed case and whitespace
      const duplicateWithDifferentCase = ContactModel(
        id: 'c_new_id',
        name: 'Updated Name',
        email: '  TRUSTED@Guard.ORG  ',
        phone: '+8801700112233',
        relationship: 'Family',
      );
      await ContactService.instance.addContact(duplicateWithDifferentCase);

      final current = await ContactService.instance.getContacts();
      expect(current.length, 1, reason: 'Duplicate email should update existing entry rather than append');
      expect(current.first.email, 'trusted@guard.org');
      expect(current.first.name, 'Updated Name');
    });
  });

  group('Phase 4.1: Local Contact Disk Cache & Sign-Out Scrub Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ContactService.instance.resetMemoryCache();
    });

    test('Contacts serialize to and deserialize from disk cache correctly', () async {
      const testUid = 'user_test_cache_42';
      final contactsToCache = [
        const ContactModel(
          id: 'c_cached_1',
          name: 'Cached Mom',
          email: 'mom@family.local',
          phone: '+8801711000001',
          relationship: 'Mother',
          isPrimary: true,
        ),
        const ContactModel(
          id: 'c_cached_2',
          name: 'Cached Friend',
          email: 'friend@app.local',
          phone: '',
          relationship: 'Friend',
          isPrimary: false,
        ),
      ];

      // Reset and add contacts
      await ContactService.instance.clearContacts();
      for (final c in contactsToCache) {
        await ContactService.instance.addContact(c);
      }

      // Explicitly trigger save to disk cache for testUid
      await ContactService.instance.saveToDiskCache(testUid);

      // Verify SharedPreferences key exists
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = ContactService.cacheKeyForUid(testUid);
      expect(prefs.containsKey(cacheKey), isTrue);

      // Load directly from disk cache and verify deserialized models
      final loaded = await ContactService.instance.loadFromDiskCache(testUid);
      expect(loaded.length, 2);
      expect(loaded[0].name, 'Cached Mom');
      expect(loaded[0].phone, '+8801711000001');
      expect(loaded[0].relationship, 'Mother');
      expect(loaded[0].isPrimary, isTrue);
      expect(loaded[1].name, 'Cached Friend');
      expect(loaded[1].email, 'friend@app.local');
      expect(loaded[1].relationship, 'Friend');
    });

    test('Disk cache is completely cleared on purgeOnSignOut', () async {
      const userA = 'user_alpha';
      const userB = 'user_beta';

      // Seed SharedPreferences with mock caches for multiple users
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(ContactService.cacheKeyForUid(userA), '[{"id":"1","name":"A","relationship":"Other"}]');
      await prefs.setString(ContactService.cacheKeyForUid(userB), '[{"id":"2","name":"B","relationship":"Other"}]');
      await prefs.setString('emergency_contacts_list', 'legacy_data');

      expect(prefs.containsKey(ContactService.cacheKeyForUid(userA)), isTrue);
      expect(prefs.containsKey(ContactService.cacheKeyForUid(userB)), isTrue);
      expect(prefs.containsKey('emergency_contacts_list'), isTrue);

      // Execute purgeOnSignOut
      await ContactService.instance.purgeOnSignOut();

      // All contact disk caches and legacy keys must be wiped
      expect(prefs.containsKey(ContactService.cacheKeyForUid(userA)), isFalse);
      expect(prefs.containsKey(ContactService.cacheKeyForUid(userB)), isFalse);
      expect(prefs.containsKey('emergency_contacts_list'), isFalse);
    });
  });

  group('Phase 4.1: Stream Merge & Deduplication Tests', () {
    test('Merges multiple streams and deduplicates items by ID', () async {
      final controller1 = StreamController<List<Map<String, dynamic>>>();
      final controller2 = StreamController<List<Map<String, dynamic>>>();

      final mergedStream = mergeAndDeduplicateStreams<Map<String, dynamic>, String>(
        streams: [controller1.stream, controller2.stream],
        idExtractor: (item) => item['id'] as String,
      );

      final emissions = <List<Map<String, dynamic>>>[];
      final sub = mergedStream.listen((list) {
        emissions.add(list);
      });

      // Stream 1 emits alerts A and B
      controller1.add([
        {'id': 'alert_A', 'timestamp': 100},
        {'id': 'alert_B', 'timestamp': 200},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Stream 2 emits alerts B (overlapping duplicate) and C
      controller2.add([
        {'id': 'alert_B', 'timestamp': 200, 'updated': true},
        {'id': 'alert_C', 'timestamp': 300},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(emissions.isNotEmpty, isTrue);
      final lastEmission = emissions.last;

      // Must contain exactly 3 items: alert_A, alert_B, alert_C
      expect(lastEmission.length, 3);
      final ids = lastEmission.map((e) => e['id']).toSet();
      expect(ids, containsAll(['alert_A', 'alert_B', 'alert_C']));

      await sub.cancel();
      await controller1.close();
      await controller2.close();
    });
  });
}
