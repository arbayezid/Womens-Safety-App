import 'package:cloud_firestore/cloud_firestore.dart';

/// A Safe Journey update shown to one of the journey's guardians.
class JourneyGuardianEvent {
  /// Notified once per device: `journey:<id>_<status>`.
  final String key;
  final String title;
  final String body;

  const JourneyGuardianEvent({required this.key, required this.title, required this.body});
}

/// An active journey older than this is an abandoned session, not news.
const Duration journeyStartedWindow = Duration(hours: 6);

/// Arrived/cancelled updates older than this are history, not news (e.g. on a cold start).
const Duration journeyEndedWindow = Duration(minutes: 20);

/// An unanswered safety check stays worth telling the guardian about for this long.
const Duration journeyAlertWindow = Duration(hours: 3);

DateTime? _date(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  return null;
}

String _hhmm(DateTime t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

/// What a guardian should be told about journey [data], or null for nothing.
///
/// The native GuardianAlertService (Android) applies the same rules; keep the two in step.
JourneyGuardianEvent? journeyGuardianEvent({
  required String journeyId,
  required Map<String, dynamic> data,
  required String myUid,
  required DateTime now,
}) {
  final ownerId = (data['ownerId'] ?? data['owner_uid'])?.toString();
  if (ownerId == null || ownerId == myUid) return null;

  final status = (data['status'] ?? '').toString().toLowerCase();
  final rawName = data['ownerName']?.toString().trim() ?? '';
  final name = rawName.isEmpty ? 'Your contact' : rawName;
  final dest = data['destination'] is Map ? data['destination'] as Map : const {};
  final rawLabel = dest['label']?.toString().trim() ?? '';
  final destLabel = rawLabel.isEmpty ? 'their destination' : rawLabel;
  final followed = data['mode']?.toString() == 'followed';

  final startedAt = _date(data['startedAt']);
  final updatedAt = _date(data['lastUpdatedAt']) ?? startedAt;
  bool within(DateTime? t, Duration window) => t != null && now.difference(t).abs() <= window;

  final key = 'journey:${journeyId}_$status';
  switch (status) {
    case 'active':
      if (!within(startedAt, journeyStartedWindow)) return null;
      if (followed) {
        return JourneyGuardianEvent(
          key: key,
          title: '⚠️ $name thinks they are being followed',
          body: 'They are sharing their live location with you. Tap to track them now.',
        );
      }
      final eta = _date(data['expectedArrivalAt']);
      return JourneyGuardianEvent(
        key: key,
        title: '🚶 $name started a Safe Journey',
        body: 'Heading to $destLabel${eta != null ? ' · ETA ${_hhmm(eta)}' : ''}. '
            'Tap to follow their live location.',
      );
    case 'arrived':
      if (!within(updatedAt, journeyEndedWindow)) return null;
      return JourneyGuardianEvent(
        key: key,
        title: '✅ $name arrived safely',
        body: followed ? 'Followed Mode has ended safely.' : 'They reached $destLabel.',
      );
    case 'alert':
      if (!within(updatedAt, journeyAlertWindow)) return null;
      return JourneyGuardianEvent(
        key: key,
        title: '🚨 $name\'s Safe Journey raised an alert',
        body: 'A safety check went unanswered. Tap to see their live location.',
      );
    case 'cancelled':
      // An abandoned session closed by housekeeping is not something the user did.
      if (data['endReason']?.toString() == 'expired') return null;
      if (!within(updatedAt, journeyEndedWindow)) return null;
      return JourneyGuardianEvent(
        key: key,
        title: '$name ended their Safe Journey',
        body: followed ? 'Followed Mode was turned off.' : 'Ended before reaching $destLabel.',
      );
  }
  return null;
}
