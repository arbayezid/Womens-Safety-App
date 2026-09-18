import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/activity_model.dart';
import 'package:smart_safety/services/activity_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
    test('Initializes with default starter activities when storage is empty', () async {
      final service = ActivityService.instance;
      final list = await service.getActivities();

      expect(list.isNotEmpty, isTrue);
      expect(service.activitiesNotifier.value.length, list.length);
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
  });
}
