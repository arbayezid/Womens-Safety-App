import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/activity_model.dart';

/// Central singleton service for recording, persisting, and querying user activities
/// and emergency safety events.
class ActivityService {
  ActivityService._internal();

  /// Central singleton instance
  static final ActivityService instance = ActivityService._internal();

  static const String _storageKey = 'smart_safety_activity_logs';

  /// Reactive notifier emitting the latest list of activities
  final ValueNotifier<List<ActivityItem>> activitiesNotifier =
      ValueNotifier<List<ActivityItem>>([]);

  /// Initial sample activity logs for first-time launch
  static List<ActivityItem> _getDefaultActivities() {
    final now = DateTime.now();
    return [
      ActivityItem(
        id: 'init_1',
        type: ActivityType.contact,
        title: 'Emergency Contacts Set Up',
        subtitle: 'Configured 3 trusted guardian contacts',
        timestamp: now.subtract(const Duration(hours: 3)),
      ),
      ActivityItem(
        id: 'init_2',
        type: ActivityType.profile,
        title: 'Safety Profile Created',
        subtitle: 'Personal medical and emergency details configured',
        timestamp: now.subtract(const Duration(days: 1)),
      ),
      ActivityItem(
        id: 'init_3',
        type: ActivityType.location,
        title: 'Live GPS Calibrated',
        subtitle: 'High-accuracy geolocation active and verified',
        timestamp: now.subtract(const Duration(days: 2)),
      ),
    ];
  }

  /// Retrieves the list of persisted activities from [SharedPreferences].
  /// Populates default initial activities on first app launch.
  Future<List<ActivityItem>> getActivities() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!prefs.containsKey(_storageKey)) {
        final initial = _getDefaultActivities();
        await _saveActivities(prefs, initial);
        activitiesNotifier.value = List.unmodifiable(initial);
        return initial;
      }

      final List<String>? jsonList = prefs.getStringList(_storageKey);
      if (jsonList == null || jsonList.isEmpty) {
        activitiesNotifier.value = [];
        return [];
      }

      final loaded = jsonList
          .map((item) {
            try {
              return ActivityItem.fromJson(item);
            } catch (e) {
              debugPrint('[ActivityService] Error parsing activity JSON: $e');
              return null;
            }
          })
          .whereType<ActivityItem>()
          .toList();

      activitiesNotifier.value = List.unmodifiable(loaded);
      return loaded;
    } catch (e) {
      debugPrint('[ActivityService] Error loading activities: $e');
      return [];
    }
  }

  /// Appends a new [ActivityItem] to the log and persists it.
  Future<void> logActivity(ActivityItem activity) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await getActivities();

      final updated = [activity, ...current];
      // Keep up to top 50 recent events
      if (updated.length > 50) {
        updated.removeRange(50, updated.length);
      }

      await _saveActivities(prefs, updated);
      activitiesNotifier.value = List.unmodifiable(updated);
      debugPrint('[ActivityService] Logged activity: ${activity.title}');
    } catch (e) {
      debugPrint('[ActivityService] Error logging activity: $e');
    }
  }

  /// Logs an SOS Emergency Alert dispatch event.
  Future<void> logSOS({
    required String source,
    required int contactsSent,
    String? mapUrl,
    bool isSuccess = true,
  }) async {
    final title = isSuccess ? 'SOS Alert Triggered' : 'SOS Alert Attempted';
    final subtitle = contactsSent > 0
        ? 'Dispatched to $contactsSent emergency contacts ($source)'
        : 'Emergency alert via $source (GPS: ${mapUrl != null ? "Attached" : "Unavailable"})';

    await logActivity(
      ActivityItem(
        id: 'sos_${DateTime.now().millisecondsSinceEpoch}',
        type: ActivityType.sos,
        title: title,
        subtitle: subtitle,
        timestamp: DateTime.now(),
        metadata: {
          'source': source,
          'contactsSent': contactsSent,
          'mapUrl': mapUrl,
          'isSuccess': isSuccess,
        },
      ),
    );
  }

  /// Logs an Emergency Siren toggle event.
  Future<void> logSiren({required bool isPlaying}) async {
    await logActivity(
      ActivityItem(
        id: 'siren_${DateTime.now().millisecondsSinceEpoch}',
        type: ActivityType.siren,
        title: isPlaying ? 'Loud Siren Activated' : 'Loud Siren Stopped',
        subtitle: isPlaying
            ? 'Emergency high-decibel alarm playing'
            : 'Siren sound deactivated',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Logs emergency contact additions, updates, or removals.
  Future<void> logContactEvent({
    required String action, // 'Added', 'Updated', 'Deleted'
    required String contactName,
  }) async {
    await logActivity(
      ActivityItem(
        id: 'contact_${DateTime.now().millisecondsSinceEpoch}',
        type: ActivityType.contact,
        title: 'Contact $action',
        subtitle: '$action emergency contact: $contactName',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Logs a safety profile modification event.
  Future<void> logProfileUpdate({required String summary}) async {
    await logActivity(
      ActivityItem(
        id: 'profile_${DateTime.now().millisecondsSinceEpoch}',
        type: ActivityType.profile,
        title: 'Profile Updated',
        subtitle: summary,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Logs a quick action trigger (e.g. Fake Call, Audio recording).
  Future<void> logQuickAction(String action) async {
    ActivityType type;
    if (action.toLowerCase().contains('call')) {
      type = ActivityType.fakeCall;
    } else if (action.toLowerCase().contains('audio')) {
      type = ActivityType.audio;
    } else {
      type = ActivityType.location;
    }

    await logActivity(
      ActivityItem(
        id: 'qa_${DateTime.now().millisecondsSinceEpoch}',
        type: type,
        title: '$action Activated',
        subtitle: 'Quick Action executed from Safety Dashboard',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Completely clears the activity history.
  Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _saveActivities(prefs, []);
      activitiesNotifier.value = [];
    } catch (e) {
      debugPrint('[ActivityService] Error clearing history: $e');
    }
  }

  /// Number of SOS emergency alerts recorded in history.
  int get alertCount {
    return activitiesNotifier.value
        .where((a) => a.type == ActivityType.sos)
        .length;
  }

  Future<bool> _saveActivities(
      SharedPreferences prefs, List<ActivityItem> list) {
    final serialized = list.map((a) => a.toJson()).toList();
    return prefs.setStringList(_storageKey, serialized);
  }
}
