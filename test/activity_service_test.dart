import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/activity_model.dart';
import 'package:smart_safety/services/activity_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ActivityService.instance.resetForTesting();
  });

  tearDown(() async {
    await ActivityService.instance.clearHistory();
  });

  group('ActivityItem Model Tests', () {
    test('ActivityItem serializes and deserializes to JSON correctly', () {
      final now = DateTime.now();
      final item = ActivityItem(
        id: 'test_1',
        type: ActivityType.sos,
        title: 'SOS Dispatched',
        subtitle: '3 contacts alerted',
        timestamp: now,
        metadata: {'contactsSent': 3, 'isSuccess': true},
      );

      final jsonStr = item.toJson();
      final restored = ActivityItem.fromJson(jsonStr);

      expect(restored.id, 'test_1');
      expect(restored.type, ActivityType.sos);
      expect(restored.title, 'SOS Dispatched');
      expect(restored.subtitle, '3 contacts alerted');
      expect(restored.metadata['contactsSent'], 3);
      expect(restored.metadata['isSuccess'], isTrue);
    });

    test('ActivityItem timeAgo outputs valid relative time strings', () {
      final justNow = ActivityItem(
        id: '1',
        type: ActivityType.siren,
        title: 'Siren',
        subtitle: 'On',
        timestamp: DateTime.now().subtract(const Duration(seconds: 10)),
      );
      expect(justNow.timeAgo, 'Just now');

      final minutesAgo = ActivityItem(
        id: '2',
        type: ActivityType.contact,
        title: 'Contact',
        subtitle: 'Added',
        timestamp: DateTime.now().subtract(const Duration(minutes: 15)),
      );
      expect(minutesAgo.timeAgo, '15m ago');

      final hoursAgo = ActivityItem(
        id: '3',
        type: ActivityType.profile,
        title: 'Profile',
        subtitle: 'Updated',
        timestamp: DateTime.now().subtract(const Duration(hours: 4)),
      );
      expect(hoursAgo.timeAgo, '4h ago');
    });
  });

  group('ActivityService Integration Tests', () {
    // History is evidence: no fake sample entries are seeded any more.
    test('Starts empty when storage is empty (no sample activities seeded)', () async {
      final service = ActivityService.instance;
      final list = await service.getActivities();

      expect(list, isEmpty);
      expect(service.activitiesNotifier.value, isEmpty);
    });

    test('Logs SOS alert and increments alertCount', () async {
      final service = ActivityService.instance;
      await service.clearHistory();
      expect(service.alertCount, 0);

      await service.logSOS(
        source: 'SOS Button',
        contactsSent: 3,
        mapUrl: 'https://maps.google.com/?q=23,90',
        isSuccess: true,
      );

      final activities = await service.getActivities();
      expect(activities.length, 1);
      expect(activities.first.type, ActivityType.sos);
      expect(activities.first.title, 'SOS Alert Triggered');
      expect(service.alertCount, 1);
    });

    test('Logs contact and siren activities with persistence', () async {
      final service = ActivityService.instance;
      await service.clearHistory();

      await service.logContactEvent(action: 'Added', contactName: 'Dad');
      await service.logSiren(isPlaying: true);

      final activities = await service.getActivities();
      expect(activities.length, 2);
      expect(activities[0].type, ActivityType.siren);
      expect(activities[1].type, ActivityType.contact);
    });

    test('clearHistory completely resets the log', () async {
      final service = ActivityService.instance;
      await service.logQuickAction('Fake Call');

      await service.clearHistory();
      expect(service.activitiesNotifier.value, isEmpty);
    });

    test('clearHistory keeps SOS entries (evidence) and removes routine ones', () async {
      final service = ActivityService.instance;
      await service.logSOS(source: 'SOS Button', contactsSent: 2);
      await service.logSiren(isPlaying: true);
      await service.logContactEvent(action: 'Added', contactName: 'Mom');

      await service.clearHistory();

      final left = await service.getActivities();
      expect(left.length, 1);
      expect(left.single.type, ActivityType.sos);
      expect(service.alertCount, 1);
    });
  });

  group('Per-account history, migration and logout', () {
    const uid = 'user_A';

    ActivityItem item(String id, ActivityType type, DateTime ts) => ActivityItem(
          id: id,
          type: type,
          title: id,
          subtitle: '',
          timestamp: ts,
        );

    test('Guest SOS is saved locally with no account (device-only alert)', () async {
      final service = ActivityService.instance;
      await service.logSOS(source: 'Shake', contactsSent: 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(ActivityService.legacyStorageKey), hasLength(1));
      final sos = (await service.getActivities()).single;
      expect(sos.metadata.containsKey('accountUid'), isTrue);
      expect(sos.metadata['accountUid'], isNull);
    });

    test('Sign-in migrates local-only history to the account and skips old sample items',
        () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        ActivityService.legacyStorageKey: [
          item('sos_1', ActivityType.sos, now).toJson(),
          item('siren_1', ActivityType.siren, now.subtract(const Duration(minutes: 1))).toJson(),
          item('init_1', ActivityType.contact, now.subtract(const Duration(hours: 3))).toJson(),
        ],
      });
      final service = ActivityService.instance;

      await service.bindUser(uid);

      final prefs = await SharedPreferences.getInstance();
      // Old global key removed only after the data is saved under the account.
      expect(prefs.containsKey(ActivityService.legacyStorageKey), isFalse);
      final cached = prefs.getStringList(ActivityService.cacheKeyForUid(uid))!;
      expect(cached, hasLength(2));
      // Both real entries are queued for upload (de-duplicated by ID on the server).
      expect(
        prefs.getStringList(ActivityService.unsyncedKeyForUid(uid)),
        containsAll(<String>['sos_1', 'siren_1']),
      );
      expect(prefs.getStringList(ActivityService.unsyncedKeyForUid(uid)), isNot(contains('init_1')));
      expect(service.activitiesNotifier.value.map((a) => a.id), ['sos_1', 'siren_1']);
    });

    test('Logout clears memory but keeps not-yet-uploaded entries for the next sign-in',
        () async {
      final service = ActivityService.instance;
      await service.bindUser(uid);
      await service.logSOS(source: 'SOS Button', contactsSent: 1);

      await service.purgeOnSignOut();
      expect(service.activitiesNotifier.value, isEmpty);
      expect(service.boundUid, isNull);

      final prefs = await SharedPreferences.getInstance();
      // No Firebase in tests, so the entry is still pending: its cache must survive logout.
      expect(prefs.getStringList(ActivityService.cacheKeyForUid(uid)), hasLength(1));

      // Same account signs in again: the history is back.
      await service.bindUser(uid);
      expect(service.alertCount, 1);
    });

    test('Logout removes the local cache once everything is in the cloud', () async {
      SharedPreferences.setMockInitialValues({
        ActivityService.cacheKeyForUid(uid): [
          item('sos_9', ActivityType.sos, DateTime.now()).toJson(),
        ],
        ActivityService.unsyncedKeyForUid(uid): <String>[],
      });
      final service = ActivityService.instance;
      await service.bindUser(uid);
      expect(service.alertCount, 1);

      await service.purgeOnSignOut();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(ActivityService.cacheKeyForUid(uid)), isFalse);
    });

    test('Another account on the same phone does not see this history', () async {
      final service = ActivityService.instance;
      await service.bindUser(uid);
      await service.logSOS(source: 'SOS Button', contactsSent: 1);
      await service.purgeOnSignOut();

      await service.bindUser('user_B');
      expect(service.activitiesNotifier.value, isEmpty);
    });
  });

  group('Cache policy and cloud mapping', () {
    ActivityItem item(String id, ActivityType type, int minutesAgo) => ActivityItem(
          id: id,
          type: type,
          title: id,
          subtitle: '',
          timestamp: DateTime.now().subtract(Duration(minutes: minutesAgo)),
        );

    test('trimForCache keeps every SOS entry and caps routine entries', () {
      final items = [
        for (var i = 0; i < 80; i++) item('r$i', ActivityType.siren, i),
        for (var i = 0; i < 5; i++) item('s$i', ActivityType.sos, 1000 + i),
      ];
      final trimmed = trimForCache(items);
      expect(trimmed.where((a) => a.type == ActivityType.sos).length, 5);
      expect(trimmed.where((a) => a.type != ActivityType.sos).length,
          ActivityService.maxLocalRoutineItems);
      expect(trimmed.first.id, 'r0'); // newest first
    });

    test('mergeActivities de-duplicates by ID and sorts newest first', () {
      final merged = mergeActivities(
        [item('a', ActivityType.sos, 5), item('b', ActivityType.siren, 1)],
        [item('a', ActivityType.sos, 5), item('c', ActivityType.contact, 3)],
      );
      expect(merged.map((a) => a.id), ['b', 'c', 'a']);
    });

    test('activityFromCloud restores the entry and falls back to the document ID', () {
      final original = item('sos_123', ActivityType.sos, 10);
      final data = original.toMap()..remove('id');
      final restored = activityFromCloud('sos_123', data)!;
      expect(restored.id, 'sos_123');
      expect(restored.type, ActivityType.sos);
      expect(restored.timestamp, original.timestamp);
    });
  });
}
