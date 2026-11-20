import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/journey_model.dart';
import 'package:smart_safety/services/journey_card_dismissals.dart';

JourneyModel _journey({JourneyStatus status = JourneyStatus.active, String? sosId}) {
  final now = DateTime(2026, 11, 20, 23, 30);
  return JourneyModel(
    id: 'journey-1',
    ownerId: 'owner',
    ownerName: 'Nusrat',
    guardianUids: const ['me'],
    guardianEmails: const [],
    status: status,
    startLocation: const {},
    destination: const {},
    startedAt: now,
    expectedArrivalAt: now.add(const Duration(minutes: 10)),
    lastUpdatedAt: now,
    linkedSosAlertId: sosId,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await JourneyCardDismissals.instance.undo(_journey());
    await JourneyCardDismissals.instance.undo(_journey(status: JourneyStatus.alert, sosId: 'sos-1'));
  });

  test('a removed card stays hidden while the journey is unchanged', () async {
    await JourneyCardDismissals.instance.dismiss(_journey());
    expect(JourneyCardDismissals.instance.isDismissed(_journey()), isTrue);
  });

  test('a removed card comes back when the journey turns into an SOS', () async {
    await JourneyCardDismissals.instance.dismiss(_journey());
    final escalated = _journey(status: JourneyStatus.alert, sosId: 'sos-1');
    expect(JourneyCardDismissals.instance.isDismissed(escalated), isFalse);
  });

  test('undo shows the card again', () async {
    await JourneyCardDismissals.instance.dismiss(_journey());
    await JourneyCardDismissals.instance.undo(_journey());
    expect(JourneyCardDismissals.instance.isDismissed(_journey()), isFalse);
  });
}
