import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/activity_model.dart';
import 'package:smart_safety/screens/sos_history_screen.dart';

void main() {
  group('SOS history: one failing query never blanks the list', () {
    test('keeps data from healthy queries and reports the failed one', () async {
      final ok = StreamController<List<Map<String, dynamic>>>();
      final failing = StreamController<List<Map<String, dynamic>>>();
      final failedIndexes = <int>[];

      final merged = mergeAndDeduplicateStreams<Map<String, dynamic>, String>(
        streams: [ok.stream, failing.stream],
        idExtractor: (m) => m['id'] as String,
        onStreamError: (index, _) => failedIndexes.add(index),
      );

      final emissions = <List<Map<String, dynamic>>>[];
      final errors = <Object>[];
      final sub = merged.listen(emissions.add, onError: errors.add);

      ok.add([
        {'id': 'mine_1'},
        {'id': 'mine_2'},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      failing.addError(Exception('permission-denied'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(errors, isEmpty, reason: 'errors must not reach the StreamBuilder');
      expect(failedIndexes, [1]);
      expect(emissions.last.map((m) => m['id']), containsAll(['mine_1', 'mine_2']));

      await sub.cancel();
      await ok.close();
      await failing.close();
    });
  });

  group('SOS history status and type', () {
    test('status labels: Active, Resolved, False Alarm, Responded', () {
      expect(sosHistoryStatusLabel({'status': 'active'}, myUid: 'me', isSender: true), 'Active');
      expect(sosHistoryStatusLabel({'status': 'resolved'}, myUid: 'me', isSender: true), 'Resolved');
      expect(
        sosHistoryStatusLabel({'status': 'resolved', 'falseAlarm': true}, myUid: 'me', isSender: true),
        'False Alarm',
      );
      expect(sosHistoryStatusLabel({'status': 'false_alarm'}, myUid: 'me', isSender: true), 'False Alarm');
      expect(
        sosHistoryStatusLabel({
          'status': 'active',
          'dismissedBy': ['me'],
        }, myUid: 'me', isSender: false),
        'Responded',
      );
      // A missing status means the alert was never resolved.
      expect(sosHistoryStatusLabel({}, myUid: 'me', isSender: true), 'Active');
    });

    test('alert type comes from the trigger source; duress is labelled', () {
      expect(sosAlertTypeLabel({'source': 'Shake'}), 'Shake');
      expect(sosAlertTypeLabel({'source': 'SOS Button', 'isDuress': true}), 'Silent SOS (duress PIN)');
      expect(sosAlertTypeLabel({}), 'SOS Alert');
    });

    test('device-only alerts are SOS entries logged without an account', () {
      ActivityItem sos(String id, Map<String, dynamic> meta) => ActivityItem(
            id: id,
            type: ActivityType.sos,
            title: 'SOS Alert Triggered',
            subtitle: '',
            timestamp: DateTime(2026, 11, 1),
            metadata: meta,
          );
      final list = [
        sos('sos_1', {'accountUid': null}), // guest: SMS only
        sos('sos_2', {'accountUid': 'uid'}), // has a cloud record
        sos('sos_3', {}), // older entry, unknown: shown in activity history only
        sos('123', {'accountUid': null}), // "I'm Safe Confirmed" style entry, not an alert
      ];
      expect(deviceOnlySosActivities(list).map((a) => a.id), ['sos_1']);
    });
  });
}
