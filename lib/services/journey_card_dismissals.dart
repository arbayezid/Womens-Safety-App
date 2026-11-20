import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/journey_model.dart';

/// Guardian home-screen journey cards the user removed with the X button (this device only).
///
/// A removal is tied to the journey's current state: if that changes (a Safe Journey turns into
/// an alert, or an SOS is sent), the card shows again, so removing a card never hides a new
/// emergency.
class JourneyCardDismissals {
  JourneyCardDismissals._internal();
  static final JourneyCardDismissals instance = JourneyCardDismissals._internal();

  static const String _prefKey = 'dismissed_journey_cards';
  static const int _maxStored = 50;

  final ValueNotifier<List<String>> dismissedNotifier = ValueNotifier<List<String>>(const []);
  bool _loaded = false;

  static String keyFor(JourneyModel journey) =>
      '${journey.id}|${journey.status.name}|${journey.linkedSosAlertId ?? ''}';

  bool isDismissed(JourneyModel journey) => dismissedNotifier.value.contains(keyFor(journey));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      dismissedNotifier.value = prefs.getStringList(_prefKey) ?? const [];
    } catch (e) {
      debugPrint('[JourneyCardDismissals] Load notice: $e');
    }
  }

  Future<void> dismiss(JourneyModel journey) => _save([
        ...dismissedNotifier.value.where((k) => k != keyFor(journey)),
        keyFor(journey),
      ]);

  Future<void> undo(JourneyModel journey) =>
      _save(dismissedNotifier.value.where((k) => k != keyFor(journey)).toList());

  Future<void> _save(List<String> keys) async {
    // Newest last; old journeys drop off so the list stays small.
    final trimmed = keys.length > _maxStored ? keys.sublist(keys.length - _maxStored) : keys;
    dismissedNotifier.value = List.unmodifiable(trimmed);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, trimmed);
    } catch (e) {
      debugPrint('[JourneyCardDismissals] Save notice: $e');
    }
  }
}
