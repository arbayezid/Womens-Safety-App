import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/journey_guardian_alerts.dart';

void main() {
  final now = DateTime(2026, 11, 6, 18, 0);

  Map<String, dynamic> journey({
    String status = 'active',
    String ownerId = 'owner',
    DateTime? startedAt,
    DateTime? updatedAt,
    String? mode,
    String? endReason,
  }) =>
      {
        'ownerId': ownerId,
        'ownerName': 'Ayesha',
        'status': status,
        'destination': {'label': 'Dhanmondi 27'},
        'startedAt': Timestamp.fromDate(startedAt ?? now.subtract(const Duration(minutes: 1))),
        'expectedArrivalAt': Timestamp.fromDate(DateTime(2026, 11, 6, 18, 25)),
        'lastUpdatedAt': Timestamp.fromDate(updatedAt ?? now.subtract(const Duration(minutes: 1))),
        if (mode != null) 'mode': mode,
        if (endReason != null) 'endReason': endReason,
      };

  JourneyGuardianEvent? eventFor(Map<String, dynamic> data, {String me = 'guardian'}) =>
      journeyGuardianEvent(journeyId: 'j1', data: data, myUid: me, now: now);

  test('guardian is told when a Safe Journey starts', () {
    final e = eventFor(journey())!;
    expect(e.key, 'journey:j1_active');
    expect(e.title, contains('Ayesha started a Safe Journey'));
    expect(e.body, contains('Dhanmondi 27'));
    expect(e.body, contains('ETA 18:25'));
  });

  test('the traveller is never notified about their own journey', () {
    expect(eventFor(journey(), me: 'owner'), isNull);
  });

  test('arrival, alert and cancellation each get their own key', () {
    expect(eventFor(journey(status: 'arrived'))!.key, 'journey:j1_arrived');
    expect(eventFor(journey(status: 'alert'))!.key, 'journey:j1_alert');
    expect(eventFor(journey(status: 'cancelled'))!.key, 'journey:j1_cancelled');
  });

  test('followed mode is worded as an urgent heads-up', () {
    expect(eventFor(journey(mode: 'followed'))!.title, contains('being followed'));
  });

  test('old sessions and old endings are not announced', () {
    expect(eventFor(journey(startedAt: now.subtract(const Duration(hours: 7)))), isNull);
    expect(
      eventFor(journey(status: 'arrived', updatedAt: now.subtract(const Duration(hours: 1)))),
      isNull,
    );
  });

  test('a session expired by housekeeping is not announced as cancelled', () {
    expect(eventFor(journey(status: 'cancelled', endReason: 'expired')), isNull);
  });
}
