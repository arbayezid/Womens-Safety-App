import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/inbox_service.dart';
import 'package:smart_safety/services/notification_service.dart';

void main() {
  const me = 'guardian-uid';
  final now = DateTime(2026, 11, 7, 12, 0);

  Map<String, dynamic> sos({
    required Duration age,
    String status = 'active',
    Duration? reRungAgo,
    int ringSeq = 0,
    Map<String, dynamic> extra = const {},
  }) =>
      {
        'senderId': 'sender-uid',
        'senderName': 'Hridoy Bepari',
        'recipientUids': [me],
        'status': status,
        'triggeredAt': Timestamp.fromDate(now.subtract(age)),
        'expiresAt': Timestamp.fromDate(now.subtract(age).add(const Duration(hours: 2))),
        'ringSeq': ringSeq,
        if (reRungAgo != null) 'ringAt': Timestamp.fromDate(now.subtract(reRungAgo)),
        'source': 'ESP32 Hardware',
        'location': {'address': 'Rampura, Dhaka'},
        ...extra,
      };

  group('live window (full-screen + siren only within 30 minutes)', () {
    test('an alert pressed 5 minutes ago is live', () {
      expect(NotificationService.isSosAlertLive(sos(age: const Duration(minutes: 5)), now), isTrue);
    });

    test('an alert pressed 31 minutes ago is not live', () {
      expect(NotificationService.isSosAlertLive(sos(age: const Duration(minutes: 31)), now), isFalse);
    });

    test('a deliberate re-press makes an old alert live again', () {
      final data = sos(age: const Duration(minutes: 50), reRungAgo: const Duration(minutes: 2), ringSeq: 1);
      expect(NotificationService.isSosAlertLive(data, now), isTrue);
      expect(NotificationService.sosLastRingTime(data), now.subtract(const Duration(minutes: 2)));
    });

    test('live location updates (lastUpdatedAt) do not make an alert live', () {
      final data = sos(age: const Duration(minutes: 50), extra: {'lastUpdatedAt': Timestamp.fromDate(now)});
      expect(NotificationService.isSosAlertLive(data, now), isFalse);
    });
  });

  group('SOS inbox status', () {
    (String, InboxTone) status(Map<String, dynamic> d) => InboxService.sosStatus(d, myUid: me, now: now);

    test('live, active, marked safe, ended', () {
      expect(status(sos(age: const Duration(minutes: 3))), ('LIVE', InboxTone.live));
      expect(status(sos(age: const Duration(minutes: 45))), ('Active', InboxTone.warning));
      expect(status(sos(age: const Duration(minutes: 40), status: 'resolved')), ('Marked safe', InboxTone.ok));
      expect(status(sos(age: const Duration(hours: 3))), ('Ended', InboxTone.neutral)); // expired
    });

    test('my own answers win', () {
      expect(status(sos(age: const Duration(minutes: 3), extra: {'acknowledgedBy': [me]})).$1, 'Responded');
      expect(status(sos(age: const Duration(minutes: 3), extra: {'dismissedBy': [me]})).$1, 'Dismissed');
      expect(status(sos(age: const Duration(minutes: 3), status: 'resolved', extra: {'falseAlarm': true})).$1,
          'False alarm');
    });
  });

  group('buildItems', () {
    test('lists everything from protected people, newest first, never my own', () {
      final items = InboxService.buildItems(
        sosAlerts: {
          'a1': sos(age: const Duration(minutes: 40), status: 'resolved'),
          'mine': sos(age: const Duration(minutes: 1), extra: {'senderId': me}),
        },
        journeys: {
          'j1': {
            'ownerId': 'sender-uid',
            'ownerName': 'Rakhi',
            'status': 'arrived',
            'destination': {'label': 'Home'},
            'lastUpdatedAt': Timestamp.fromDate(now.subtract(const Duration(minutes: 10))),
          },
        },
        rides: {
          'r1': {
            'userId': 'sender-uid',
            'userName': 'Rakhi',
            'status': 'overdue',
            'rideType': 'CNG',
            'plateFormatted': 'DHAKA METRO-THA 11-2233',
            'lastUpdatedAt': Timestamp.fromDate(now.subtract(const Duration(hours: 2))),
          },
        },
        requests: [
          {'docId': 'q1', 'senderName': 'Mitu', 'createdAt': Timestamp.fromDate(now.subtract(const Duration(days: 1)))},
        ],
        myUid: me,
        now: now,
      );
      expect(items.map((i) => i.key), ['journey:j1:arrived', 'sos:a1#0', 'ride:r1:overdue', 'request:q1']);
      expect(items[1].title, contains('Hridoy Bepari'));
      expect(items[1].status, 'Marked safe');
      expect(items[1].body, 'ESP32 Hardware · Rampura, Dhaka');
    });

    test('drops entries older than 30 days', () {
      final items = InboxService.buildItems(
        sosAlerts: {'old': sos(age: const Duration(days: 31), status: 'resolved')},
        journeys: const {},
        rides: const {},
        requests: const [],
        myUid: me,
        now: now,
      );
      expect(items, isEmpty);
    });

    test('a re-pressed alert gets a new key, so it is unread again', () {
      final first = InboxService.sosItem('a1', sos(age: const Duration(minutes: 5)), myUid: me, now: now)!;
      final again = InboxService.sosItem(
          'a1', sos(age: const Duration(minutes: 50), reRungAgo: const Duration(minutes: 1), ringSeq: 1),
          myUid: me, now: now)!;
      expect(first.key, isNot(again.key));
    });
  });

  test('badge counts unread items newer than the last inbox visit', () {
    InboxItem item(String key, Duration age) => InboxItem(
          key: key,
          type: InboxItemType.sos,
          id: key,
          title: '',
          body: '',
          time: now.subtract(age),
          status: '',
          tone: InboxTone.neutral,
        );
    final items = [
      item('a', const Duration(minutes: 1)),
      item('b', const Duration(minutes: 5)),
      item('c', const Duration(minutes: 20)),
      item('d', const Duration(hours: 5)),
    ];
    final seenAt = now.subtract(const Duration(hours: 1));
    expect(InboxService.countBadge(items, readKeys: {}, seenAt: seenAt), 3);
    expect(InboxService.countBadge(items, readKeys: {'b'}, seenAt: seenAt), 2);
    expect(InboxService.countBadge(items, readKeys: {}, seenAt: now), 0);
  });
}
