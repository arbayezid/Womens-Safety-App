import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/notification_service.dart';

const _me = 'guardian_b';
const _myEmail = 'b@example.com';
final _now = DateTime(2026, 11, 6, 23);

Map<String, dynamic> _alert({
  String status = 'active',
  String senderId = 'sender_a',
  Object? triggeredAt,
  bool noTime = false,
  Object? expiresAt,
  int? ringSeq,
  List<String> dismissedBy = const [],
  List<String> acknowledgedBy = const [],
  Map<String, Object?>? acknowledgedAt,
  Object? ringAt,
  List<String> recipientUids = const [_me],
  List<String> recipientEmails = const [],
}) =>
    {
      'status': status,
      'senderId': senderId,
      if (!noTime) 'triggeredAt': triggeredAt ?? Timestamp.fromDate(_now.subtract(const Duration(minutes: 5))),
      if (expiresAt != null) 'expiresAt': expiresAt,
      if (ringSeq != null) 'ringSeq': ringSeq,
      'dismissedBy': dismissedBy,
      'acknowledgedBy': acknowledgedBy,
      if (acknowledgedAt != null) 'acknowledgedAt': acknowledgedAt,
      if (ringAt != null) 'ringAt': ringAt,
      'recipientUids': recipientUids,
      'recipientEmails': recipientEmails,
    };

bool _eligible(Map<String, dynamic> data, {Set<String> dismissed = const {}, String alertId = 'a1'}) =>
    NotificationService.sosAlertTimeIfEligible(
      alertId: alertId,
      data: data,
      myUid: _me,
      myEmail: _myEmail,
      dismissedRingKeys: dismissed,
      now: _now,
    ) !=
    null;

void main() {
  group('Ring key', () {
    test('is alertId#ringSeq, missing ringSeq counts as 0', () {
      expect(NotificationService.sosRingKey('a1', null), 'a1#0');
      expect(NotificationService.sosRingKey('a1', 2), 'a1#2');
      expect(NotificationService.sosRingKey('a1', '3'), 'a1#3', reason: 'FCM data arrives as strings');
      expect(NotificationService.sosRingKey('a1', 'x'), 'a1#0');
    });
  });

  group('Shared eligibility (rows 3-8)', () {
    test('a fresh active alert addressed to me is eligible', () {
      expect(_eligible(_alert()), isTrue);
      expect(_eligible(_alert(recipientUids: const [], recipientEmails: const [_myEmail])), isTrue);
    });

    test('rows 3 and 6: dismissed in the dialog or from the native notification stays quiet', () {
      expect(_eligible(_alert(dismissedBy: const [_me])), isFalse, reason: 'cloud dismissedBy');
      expect(_eligible(_alert(), dismissed: {'a1#0'}), isFalse, reason: 'local dismissal of this ring');
    });

    test('I\'m Responding (acknowledgedBy) stays quiet', () {
      expect(_eligible(_alert(acknowledgedBy: const [_me])), isFalse);
    });

    test('I\'m Responding, then the sender re-sends: rings again (acknowledgedBy is never cleared)',
        () {
      Timestamp ago(int minutes) => Timestamp.fromDate(_now.subtract(Duration(minutes: minutes)));
      // Responded 3 min ago, sender re-pressed 1 min ago (ringSeq 1): ring again.
      expect(
        _eligible(
          _alert(
            ringSeq: 1,
            ringAt: ago(1),
            acknowledgedBy: const [_me],
            acknowledgedAt: {_me: ago(3)},
          ),
          dismissed: {'a1#0'},
        ),
        isTrue,
      );
      // Responded after the latest re-press: stays quiet.
      expect(
        _eligible(_alert(
          ringSeq: 1,
          ringAt: ago(3),
          acknowledgedBy: const [_me],
          acknowledgedAt: {_me: ago(1)},
        )),
        isFalse,
      );
      // The re-ring already answered on this device stays quiet via its ring key.
      expect(
        _eligible(
          _alert(
            ringSeq: 1,
            ringAt: ago(1),
            acknowledgedBy: const [_me],
            acknowledgedAt: {_me: ago(3)},
          ),
          dismissed: {'a1#0', 'a1#1'},
        ),
        isFalse,
      );
      // Another guardian's acknowledgement never silences me.
      expect(_eligible(_alert(acknowledgedBy: const ['someone_else'])), isTrue);
    });

    test('a deliberate re-ring (ringSeq + 1, dismissals cleared) is eligible once more', () {
      expect(_eligible(_alert(ringSeq: 1), dismissed: {'a1#0'}), isTrue);
      expect(_eligible(_alert(ringSeq: 1), dismissed: {'a1#0', 'a1#1'}), isFalse);
    });

    test('row 7: an expired alert is ignored even while still active', () {
      expect(
        _eligible(_alert(expiresAt: Timestamp.fromDate(_now.subtract(const Duration(minutes: 1))))),
        isFalse,
      );
      expect(
        _eligible(_alert(expiresAt: Timestamp.fromDate(_now.add(const Duration(hours: 1))))),
        isTrue,
      );
    });

    test('row 7: an alert older than 3 hours is ignored', () {
      expect(
        _eligible(_alert(triggeredAt: Timestamp.fromDate(_now.subtract(const Duration(hours: 4))))),
        isFalse,
      );
    });

    test('row 8: an alert without a trigger time is never treated as "now"', () {
      expect(_eligible(_alert(noTime: true)), isFalse);
    });

    test('resolved alerts, my own alerts and alerts for others are ignored', () {
      expect(_eligible(_alert(status: 'resolved')), isFalse);
      expect(_eligible(_alert(senderId: _me)), isFalse);
      expect(_eligible(_alert(recipientUids: const ['someone_else'])), isFalse);
    });

    test('time formats: epoch ms and ISO strings are parsed', () {
      final ms = _now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
      expect(_eligible(_alert(triggeredAt: ms)), isTrue);
      expect(_eligible(_alert(triggeredAt: _now.toIso8601String())), isTrue);
      expect(_eligible(_alert(triggeredAt: 'not a time')), isFalse);
    });
  });
}
