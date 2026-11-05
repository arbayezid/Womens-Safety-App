import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/activity_model.dart';

/// Central singleton service for recording, persisting, and querying user activities
/// and emergency safety events.
///
/// Storage model:
/// - **Source of truth:** Firestore `users/{uid}/activity_logs/{activityId}`, owned by the
///   account. It survives logout, reinstall and a new phone, and is never trimmed or
///   auto-deleted. SOS entries cannot be deleted at all (enforced in `firestore.rules`).
/// - **Offline cache:** SharedPreferences `smart_safety_activity_logs_<uid>` (per account).
///   Logging writes the cache first (instant, offline) and then Firestore, fire-and-forget,
///   so it never blocks or throws into the SOS path.
/// - **Guest / pre-update history:** the old global key `smart_safety_activity_logs`. On the
///   next sign-in it is uploaded to that account (de-duplicated by ID) and then removed.
class ActivityService {
  ActivityService._internal();

  /// Central singleton instance
  static final ActivityService instance = ActivityService._internal();

  /// Guest history and the history saved by app versions before per-account storage.
  static const String legacyStorageKey = 'smart_safety_activity_logs';
  static const String _userKeyPrefix = 'smart_safety_activity_logs_';
  static const String _unsyncedKeyPrefix = 'smart_safety_activity_unsynced_';

  /// Non-SOS entries kept in the local cache. SOS entries are always kept.
  static const int maxLocalRoutineItems = 50;

  /// Most recent entries loaded from Firestore on sign-in (all SOS entries are loaded too).
  static const int cloudFetchLimit = 100;

  /// Per-account cache key.
  static String cacheKeyForUid(String uid) => '$_userKeyPrefix$uid';
  static String unsyncedKeyForUid(String uid) => '$_unsyncedKeyPrefix$uid';

  /// Reactive notifier emitting the latest list of activities
  final ValueNotifier<List<ActivityItem>> activitiesNotifier =
      ValueNotifier<List<ActivityItem>>([]);

  String? _uid;
  Future<void> _sync = Future<void>.value();

  /// Account the history currently belongs to (null = guest).
  String? get boundUid => _uid;

  String get _storageKey => _uid == null ? legacyStorageKey : cacheKeyForUid(_uid!);

  CollectionReference<Map<String, dynamic>>? _cloud(String uid) {
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid).collection('activity_logs');
  }

  /// Binds the history to [uid] after sign-in: shows the local cache immediately, uploads
  /// anything that exists only on this device, then loads the account's history from
  /// Firestore. Safe to call repeatedly.
  Future<void> bindUser(String uid) {
    if (uid.isEmpty) return Future<void>.value();
    if (_uid == uid) return _sync;
    _uid = uid;
    _sync = _bindAndSync(uid).catchError((Object e) {
      debugPrint('[ActivityService] Sync notice: $e');
    });
    return _sync;
  }

  /// Re-reads the account's history from Firestore (e.g. when a history screen opens).
  Future<void> refreshFromCloud() {
    final uid = _uid;
    if (uid == null) return Future<void>.value();
    _sync = _sync.then((_) => _bindAndSync(uid)).catchError((Object e) {
      debugPrint('[ActivityService] Refresh notice: $e');
    });
    return _sync;
  }

  Future<void> _bindAndSync(String uid) async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Local cache first, so the list shows instantly (also offline).
    final local = _readList(prefs, cacheKeyForUid(uid));
    final unsynced = (prefs.getStringList(unsyncedKeyForUid(uid)) ?? <String>[]).toSet();

    // 2. Migration: guest / pre-update history stored under the old global key.
    final legacy = _readList(prefs, legacyStorageKey)
        .where((a) => !isSeedActivity(a))
        .toList();
    final merged = mergeActivities(local, legacy);
    if (legacy.isNotEmpty) {
      unsynced.addAll(legacy.map((a) => a.id));
      // Saved under the account before the old key is removed, so nothing can be lost.
      await _write(prefs, cacheKeyForUid(uid), merged);
      await prefs.setStringList(unsyncedKeyForUid(uid), unsynced.toList());
    }
    if (prefs.containsKey(legacyStorageKey)) {
      await prefs.remove(legacyStorageKey);
    }
    if (_uid != uid) return;
    activitiesNotifier.value = List.unmodifiable(trimForCache(merged));

    final cloud = _cloud(uid);
    if (cloud == null) return;

    // 3. Load the account's history (served from the Firestore cache when offline).
    final Map<String, ActivityItem> remote = {};
    try {
      final results = await Future.wait([
        cloud.orderBy('timestampAt', descending: true).limit(cloudFetchLimit).get(),
        cloud.where('type', isEqualTo: ActivityType.sos.name).get(),
      ]).timeout(const Duration(seconds: 10));
      for (final snap in results) {
        for (final doc in snap.docs) {
          final item = activityFromCloud(doc.id, doc.data());
          if (item != null) remote[item.id] = item;
        }
      }
    } catch (e) {
      debugPrint('[ActivityService] Cloud history load notice: $e');
    }
    if (_uid != uid) return;

    // 4. Upload entries that exist only on this device, de-duplicated by ID.
    final localById = {for (final a in merged) a.id: a};
    final confirmed = unsynced.where(remote.containsKey).toSet();
    var failed = 0;
    for (final id in unsynced.where((id) => !remote.containsKey(id))) {
      final item = localById[id];
      if (item == null) {
        confirmed.add(id); // no longer on this device: nothing to upload
        continue;
      }
      try {
        final existing = await cloud
            .doc(id)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 5));
        if (!existing.exists) {
          await cloud.doc(id).set(activityToCloud(item)).timeout(const Duration(seconds: 5));
        }
        confirmed.add(id);
      } catch (e) {
        failed++; // offline or failed: stays pending, retried on the next sign-in
      }
    }
    // Re-read: entries logged while this sync ran must stay pending.
    final pendingNow = prefs.getStringList(unsyncedKeyForUid(uid)) ?? <String>[];
    await prefs.setStringList(
      unsyncedKeyForUid(uid),
      pendingNow.where((id) => !confirmed.contains(id)).toList(),
    );

    // 5. Show cloud + local together and refresh the cache (re-read so entries logged
    // during this sync are kept).
    final latestLocal = _readList(prefs, cacheKeyForUid(uid));
    final combined = mergeActivities(latestLocal, [...merged, ...remote.values]);
    if (_uid != uid) return;
    final cached = trimForCache(combined);
    await _write(prefs, cacheKeyForUid(uid), cached);
    activitiesNotifier.value = List.unmodifiable(cached);
    debugPrint('[ActivityService] History ready for $uid: ${cached.length} item(s), '
        '$failed pending upload(s)');
  }

  /// Retrieves the activity history of the bound account (or guest) from the local cache.
  Future<List<ActivityItem>> getActivities() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loaded = _readList(prefs, _storageKey);
      activitiesNotifier.value = List.unmodifiable(loaded);
      return loaded;
    } catch (e) {
      debugPrint('[ActivityService] Error loading activities: $e');
      return [];
    }
  }

  /// Appends a new [ActivityItem] to the log and persists it (cache now, cloud in background).
  Future<void> logActivity(ActivityItem activity) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await getActivities();

      final updated = trimForCache([activity, ...current.where((a) => a.id != activity.id)]);
      await _write(prefs, _storageKey, updated);
      activitiesNotifier.value = List.unmodifiable(updated);
      debugPrint('[ActivityService] Logged activity: ${activity.title}');

      final uid = _uid;
      if (uid != null) {
        final unsyncedKey = unsyncedKeyForUid(uid);
        final pending = prefs.getStringList(unsyncedKey) ?? <String>[];
        if (!pending.contains(activity.id)) {
          await prefs.setStringList(unsyncedKey, [...pending, activity.id]);
        }
        unawaited(_upload(uid, activity));
      }
    } catch (e) {
      debugPrint('[ActivityService] Error logging activity: $e');
    }
  }

  /// Writes one entry to Firestore. Offline, Firestore queues it; once the server confirms,
  /// it is removed from the pending list.
  Future<void> _upload(String uid, ActivityItem activity) async {
    final cloud = _cloud(uid);
    if (cloud == null) return;
    try {
      await cloud.doc(activity.id).set(activityToCloud(activity));
      final prefs = await SharedPreferences.getInstance();
      final key = unsyncedKeyForUid(uid);
      final pending = prefs.getStringList(key) ?? <String>[];
      if (pending.remove(activity.id)) await prefs.setStringList(key, pending);
    } catch (e) {
      debugPrint('[ActivityService] Cloud write notice (kept pending): $e');
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
          // No account = no cloud SOS record; the history screen lists these separately.
          'accountUid': _uid,
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

  /// Logs a quick action trigger (e.g. Fake Call, Loud Siren).
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

  /// Logs a Ride Safety Check-in event.
  Future<void> logRideEvent({
    required String action,
    required String rideType,
    required String plateFormatted,
  }) async {
    await logActivity(
      ActivityItem(
        id: 'ride_${DateTime.now().millisecondsSinceEpoch}',
        type: ActivityType.ride,
        title: 'Ride $action',
        subtitle: '$rideType ($plateFormatted)',
        timestamp: DateTime.now(),
        metadata: {
          'action': action,
          'rideType': rideType,
          'plateFormatted': plateFormatted,
        },
      ),
    );
  }

  /// User-initiated "Clear" (Profile screen). Removes routine activity from this device and
  /// the account. **SOS entries are kept**: they are evidence, and the rules forbid deleting them.
  Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await getActivities();
      final kept = current.where((a) => a.type == ActivityType.sos).toList();
      await _write(prefs, _storageKey, kept);
      activitiesNotifier.value = List.unmodifiable(kept);

      final uid = _uid;
      final cloud = uid == null ? null : _cloud(uid);
      if (cloud != null) {
        unawaited(() async {
          try {
            final snap = await cloud
                .where('type', isNotEqualTo: ActivityType.sos.name)
                .get()
                .timeout(const Duration(seconds: 10));
            for (final doc in snap.docs) {
              await doc.reference.delete();
            }
          } catch (e) {
            debugPrint('[ActivityService] Cloud clear notice: $e');
          }
        }());
      }
    } catch (e) {
      debugPrint('[ActivityService] Error clearing history: $e');
    }
  }

  /// Sign-out: forgets the account's history on this device (memory + local cache).
  /// **Never deletes anything in Firestore.** Entries not yet confirmed by the server keep
  /// their cache so they are uploaded at the next sign-in of the same account.
  Future<void> purgeOnSignOut() async {
    final uid = _uid;
    _uid = null;
    _sync = Future<void>.value();
    activitiesNotifier.value = const [];
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList(unsyncedKeyForUid(uid)) ?? const <String>[];
      if (pending.isEmpty) {
        await prefs.remove(cacheKeyForUid(uid));
        await prefs.remove(unsyncedKeyForUid(uid));
      }
    } catch (e) {
      debugPrint('[ActivityService] Sign-out cache notice: $e');
    }
  }

  /// Number of SOS emergency alerts recorded in history.
  int get alertCount {
    return activitiesNotifier.value
        .where((a) => a.type == ActivityType.sos)
        .length;
  }

  List<ActivityItem> _readList(SharedPreferences prefs, String key) {
    final List<String>? jsonList = prefs.getStringList(key);
    if (jsonList == null || jsonList.isEmpty) return [];
    return jsonList
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
  }

  Future<bool> _write(SharedPreferences prefs, String key, List<ActivityItem> list) {
    final serialized = list.map((a) => a.toJson()).toList();
    return prefs.setStringList(key, serialized);
  }

  @visibleForTesting
  void resetForTesting() {
    _uid = null;
    _sync = Future<void>.value();
    activitiesNotifier.value = const [];
  }
}

/// Sample items older app versions seeded on first launch ("Configured 3 trusted guardian
/// contacts", ...). They are not real events, so they are never uploaded.
bool isSeedActivity(ActivityItem a) => a.id.startsWith('init_');

/// Merges lists by ID (first occurrence wins) and sorts newest first.
List<ActivityItem> mergeActivities(Iterable<ActivityItem> primary, Iterable<ActivityItem> secondary) {
  final byId = <String, ActivityItem>{};
  for (final a in [...primary, ...secondary]) {
    if (a.id.isEmpty) continue;
    byId.putIfAbsent(a.id, () => a);
  }
  final list = byId.values.toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return list;
}

/// Local cache policy: every SOS entry plus the latest [ActivityService.maxLocalRoutineItems]
/// other entries, newest first. Firestore keeps everything.
List<ActivityItem> trimForCache(List<ActivityItem> items) {
  final sorted = [...items]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  var routine = 0;
  return sorted.where((a) {
    if (a.type == ActivityType.sos) return true;
    routine++;
    return routine <= ActivityService.maxLocalRoutineItems;
  }).toList();
}

/// Firestore document for an entry. `timestampAt` is a real Timestamp for ordering;
/// `timestamp` keeps the ISO string the model already uses.
Map<String, dynamic> activityToCloud(ActivityItem a) {
  return {
    ...a.toMap(),
    'timestampAt': Timestamp.fromDate(a.timestamp),
    'createdAt': FieldValue.serverTimestamp(),
  };
}

/// Parses a Firestore entry; returns null for unreadable documents.
ActivityItem? activityFromCloud(String docId, Map<String, dynamic> data) {
  try {
    final map = Map<String, dynamic>.from(data);
    map['id'] = (map['id']?.toString().isNotEmpty ?? false) ? map['id'] : docId;
    final ts = map['timestampAt'];
    if ((map['timestamp'] == null || map['timestamp'].toString().isEmpty) && ts is Timestamp) {
      map['timestamp'] = ts.toDate().toIso8601String();
    }
    return ActivityItem.fromMap(map);
  } catch (e) {
    debugPrint('[ActivityService] Unreadable cloud entry $docId: $e');
    return null;
  }
}
