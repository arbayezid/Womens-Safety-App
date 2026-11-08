import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'contact_sync_service.dart';
import 'notification_service.dart';

/// What an inbox entry is about.
enum InboxItemType { sos, journey, ride, request }

/// How an entry's status chip should look.
enum InboxTone { live, warning, ok, neutral }

/// One entry of the notification inbox (bell).
@immutable
class InboxItem {
  /// Read-state key. A new event on the same thing (a re-pressed SOS, a journey that arrived)
  /// gets a new key, so it shows as unread again.
  final String key;
  final InboxItemType type;

  /// Firestore document ID of the alert / journey / ride / request.
  final String id;
  final String title;
  final String body;
  final DateTime time;
  final String status;
  final InboxTone tone;

  const InboxItem({
    required this.key,
    required this.type,
    required this.id,
    required this.title,
    required this.body,
    required this.time,
    required this.status,
    required this.tone,
  });
}

/// Facebook-style notification inbox for a guardian: every SOS alert, Safe Journey update, ride
/// check-in and guardian request from the people they protect, newest first.
///
/// Items come straight from Firestore (the same documents the alerts are made from), so the
/// history survives reinstalls. Only the read state is local: [unreadCountNotifier] (the bell
/// badge) counts new items since the inbox was last opened; an item stays highlighted until it
/// is tapped.
class InboxService {
  InboxService._internal();
  static final InboxService instance = InboxService._internal();

  /// Entries older than this are not listed.
  static const Duration historyWindow = Duration(days: 30);
  static const int maxItems = 150;
  static const int _maxReadKeys = 600;

  /// On the very first run, items newer than this count as unread (e.g. alerts missed while the
  /// app was not installed or not updated yet).
  static const Duration firstRunUnreadWindow = Duration(hours: 24);

  final ValueNotifier<List<InboxItem>> itemsNotifier = ValueNotifier<List<InboxItem>>(const []);
  final ValueNotifier<int> unreadCountNotifier = ValueNotifier<int>(0);

  final Map<String, Map<String, Map<String, dynamic>>> _docsBySource = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  StreamSubscription<User?>? _authSub;
  Timer? _rebuildTimer;
  String? _uid;

  Set<String> _readKeys = {};

  /// Keys of every item that was on screen while the inbox was open. The badge is key-based:
  /// an item's time can keep moving (an active journey's `lastUpdatedAt` refreshes with every
  /// location update) and server times can be ahead of this phone's clock, so "newer than the
  /// last visit" alone made already-seen items come back on the badge.
  Set<String> _seenKeys = {};
  DateTime _seenAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _readBaseline = DateTime.fromMillisecondsSinceEpoch(0);

  /// Inbox screens currently open (the bell and a notification tap can each push one).
  /// While any is showing, everything that arrives is seen.
  int _openInboxScreens = 0;
  bool get _inboxOpen => _openInboxScreens > 0;

  /// Starts following the signed-in user. Safe to call more than once.
  void initialize() {
    if (_authSub != null || Firebase.apps.isEmpty) return;
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        _stop();
      } else if (user.uid != _uid) {
        unawaited(_start(user.uid, (user.email ?? '').toLowerCase().trim()));
      }
    });
    ContactSyncService.instance.incomingRequestsNotifier.addListener(_scheduleRebuild);
  }

  Future<void> _start(String uid, String email) async {
    _stop();
    _uid = uid;
    await _loadReadState(uid);
    if (_uid != uid) return;

    final db = FirebaseFirestore.instance;
    void listen(String source, Query<Map<String, dynamic>> query) {
      _subs.add(query.snapshots().listen((snap) {
        _docsBySource[source] = {for (final d in snap.docs) d.id: d.data()};
        _scheduleRebuild();
      }, onError: (Object e) => debugPrint('[Inbox] $source query failed: $e')));
    }

    listen('sos_uid', db.collection('sos_alerts').where('recipientUids', arrayContains: uid));
    listen('journey_uid', db.collection('journeys').where('guardianUids', arrayContains: uid));
    listen('ride_uid', db.collection('ride_checkins').where('guardianIds', arrayContains: uid));
    if (email.isNotEmpty) {
      listen('sos_email', db.collection('sos_alerts').where('recipientEmails', arrayContains: email));
      listen('journey_email', db.collection('journeys').where('guardianEmails', arrayContains: email));
      listen('ride_email', db.collection('ride_checkins').where('guardianEmails', arrayContains: email));
    }
    // Live/active state changes with the clock (30-minute live window): refresh labels.
    _rebuildTimer = Timer.periodic(const Duration(minutes: 1), (_) => _rebuild());
    _rebuild();
  }

  void _stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    _docsBySource.clear();
    _uid = null;
    _readKeys = {};
    _seenKeys = {};
    itemsNotifier.value = const [];
    unreadCountNotifier.value = 0;
  }

  bool _rebuildScheduled = false;
  void _scheduleRebuild() {
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    scheduleMicrotask(() {
      _rebuildScheduled = false;
      _rebuild();
    });
  }

  void _rebuild() {
    final uid = _uid;
    if (uid == null) return;
    Map<String, Map<String, dynamic>> merged(String a, String b) => {
          ...?_docsBySource[a],
          ...?_docsBySource[b],
        };
    final items = buildItems(
      sosAlerts: merged('sos_uid', 'sos_email'),
      journeys: merged('journey_uid', 'journey_email'),
      rides: merged('ride_uid', 'ride_email'),
      requests: ContactSyncService.instance.incomingRequestsNotifier.value,
      myUid: uid,
      now: DateTime.now(),
    );
    itemsNotifier.value = items;
    if (_inboxOpen) {
      // On screen right now, so already seen: must not show on the badge after going back
      final before = _seenKeys.length;
      _seenKeys.addAll(items.map((i) => i.key));
      if (_seenKeys.length != before) unawaited(_saveReadState());
    }
    _updateBadge();
  }

  void _updateBadge() {
    unreadCountNotifier.value =
        countBadge(itemsNotifier.value, readKeys: _readKeys, seenKeys: _seenKeys, seenAt: _seenAt);
  }

  /// Whether [item] is highlighted as unread in the list.
  bool isUnread(InboxItem item) => !_readKeys.contains(item.key) && item.time.isAfter(_readBaseline);

  /// The inbox screen became visible: everything listed now (and everything that arrives while
  /// it stays open) counts as seen and leaves the badge. Items stay highlighted until tapped.
  Future<void> inboxOpened() async {
    _openInboxScreens++;
    await markAllSeen();
  }

  /// The inbox screen was closed. Items that arrived while it was open were seen too.
  Future<void> inboxClosed() async {
    if (_openInboxScreens > 0) _openInboxScreens--;
    await markAllSeen();
  }

  /// Clears the badge for everything currently listed.
  Future<void> markAllSeen() async {
    _seenKeys.addAll(itemsNotifier.value.map((i) => i.key));
    _seenAt = DateTime.now();
    _updateBadge();
    await _saveReadState();
  }

  Future<void> markRead(InboxItem item) async {
    final added = _readKeys.add(item.key);
    _seenKeys.add(item.key);
    if (!added) return;
    _updateBadge();
    itemsNotifier.value = List.of(itemsNotifier.value); // repaint highlights
    await _saveReadState();
  }

  Future<void> markAllRead() async {
    final keys = itemsNotifier.value.map((i) => i.key);
    _readKeys.addAll(keys);
    _seenKeys.addAll(keys);
    _seenAt = DateTime.now();
    _updateBadge();
    itemsNotifier.value = List.of(itemsNotifier.value);
    await _saveReadState();
  }

  String _k(String name, String uid) => 'inbox_${name}_$uid';

  Future<void> _loadReadState(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _readKeys = (prefs.getStringList(_k('read', uid)) ?? const []).toSet();
      _seenKeys = (prefs.getStringList(_k('seenkeys', uid)) ?? const []).toSet();
      final baseline = prefs.getInt(_k('baseline', uid));
      if (baseline == null) {
        // First run: anything from the last 24 hours is new to this user.
        final start = DateTime.now().subtract(firstRunUnreadWindow);
        _readBaseline = start;
        _seenAt = start;
        await prefs.setInt(_k('baseline', uid), start.millisecondsSinceEpoch);
        await prefs.setInt(_k('seen', uid), start.millisecondsSinceEpoch);
      } else {
        _readBaseline = DateTime.fromMillisecondsSinceEpoch(baseline);
        _seenAt = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_k('seen', uid)) ?? baseline);
      }
    } catch (e) {
      debugPrint('[Inbox] Could not load read state: $e');
    }
  }

  Future<void> _saveReadState() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final listed = itemsNotifier.value.map((i) => i.key).toSet();
      await prefs.setStringList(_k('read', uid), trimKeys(_readKeys, keep: listed, max: _maxReadKeys));
      await prefs.setStringList(_k('seenkeys', uid), trimKeys(_seenKeys, keep: listed, max: _maxReadKeys));
      await prefs.setInt(_k('seen', uid), _seenAt.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[Inbox] Could not save read state: $e');
    }
  }

  // ── Pure mapping (unit-tested) ─────────────────────────────────────────────

  /// How far before the last inbox visit an item's time may lie and still count as new when its
  /// key was never seen: covers a phone clock running ahead of the server and alerts delivered
  /// late (phone offline). Items that were listed during the visit are excluded by key.
  static const Duration badgeClockGrace = Duration(minutes: 15);

  /// Bell badge: items never listed while the inbox was open ([seenKeys]), not read, and not
  /// older than the last visit ([seenAt], minus [badgeClockGrace]).
  static int countBadge(
    List<InboxItem> items, {
    required Set<String> readKeys,
    required DateTime seenAt,
    Set<String> seenKeys = const {},
  }) {
    final since = seenAt.subtract(badgeClockGrace);
    return items
        .where((i) => !seenKeys.contains(i.key) && !readKeys.contains(i.key) && i.time.isAfter(since))
        .length;
  }

  /// Keys to persist: every key of a listed item ([keep]) first, then the most recent others,
  /// at most [max]. Keeping the listed ones means a long history can never evict the key of an
  /// item that is still shown (which would put it back on the badge).
  static List<String> trimKeys(Set<String> keys, {required Set<String> keep, required int max}) {
    final listed = keys.where(keep.contains).toList();
    final others = keys.where((k) => !keep.contains(k)).toList();
    final room = (max - listed.length).clamp(0, others.length);
    return [...listed, ...others.sublist(others.length - room)];
  }

  static DateTime? _date(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  static List<String> _list(dynamic raw) => ((raw as List<dynamic>?) ?? const []).map((e) => e.toString()).toList();

  static String _name(dynamic raw, String fallback) {
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? fallback : s;
  }

  static String _hhmm(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Every inbox entry for [myUid], newest first, at most [maxItems] within [historyWindow].
  static List<InboxItem> buildItems({
    required Map<String, Map<String, dynamic>> sosAlerts,
    required Map<String, Map<String, dynamic>> journeys,
    required Map<String, Map<String, dynamic>> rides,
    required List<Map<String, dynamic>> requests,
    required String myUid,
    required DateTime now,
  }) {
    final items = <InboxItem?>[
      for (final e in sosAlerts.entries) sosItem(e.key, e.value, myUid: myUid, now: now),
      for (final e in journeys.entries) journeyItem(e.key, e.value, myUid: myUid),
      for (final e in rides.entries) rideItem(e.key, e.value, myUid: myUid),
      for (final r in requests) requestItem(r, now: now),
    ].whereType<InboxItem>().toList();
    final cutoff = now.subtract(historyWindow);
    items.removeWhere((i) => i.time.isBefore(cutoff));
    items.sort((a, b) => b.time.compareTo(a.time));
    return items.length > maxItems ? items.sublist(0, maxItems) : items;
  }

  /// Status of an SOS alert as this guardian sees it.
  static (String, InboxTone) sosStatus(Map<String, dynamic> data, {required String myUid, required DateTime now}) {
    final status = (data['status'] ?? '').toString().toLowerCase();
    if (data['falseAlarm'] == true || status.startsWith('false')) return ('False alarm', InboxTone.neutral);
    if (_list(data['acknowledgedBy']).contains(myUid)) return ('Responded', InboxTone.ok);
    final expiresAt = _date(data['expiresAt']);
    final active = status == 'active' && (expiresAt == null || expiresAt.isAfter(now));
    if (active && _list(data['dismissedBy']).contains(myUid)) return ('Dismissed', InboxTone.neutral);
    if (active) {
      return NotificationService.isSosAlertLive(data, now) ? ('LIVE', InboxTone.live) : ('Active', InboxTone.warning);
    }
    if (status == 'resolved') return ('Marked safe', InboxTone.ok);
    return ('Ended', InboxTone.neutral);
  }

  static InboxItem? sosItem(String id, Map<String, dynamic> data, {required String myUid, required DateTime now}) {
    final sender = (data['senderId'] ?? data['sender_uid'])?.toString();
    if (sender == myUid) return null;
    final time = NotificationService.sosLastRingTime(data);
    if (time == null) return null;
    final name = _name(data['senderName'] ?? data['sender_name'], 'Your contact');
    final (status, tone) = sosStatus(data, myUid: myUid, now: now);
    final source = data['isDuress'] == true ? 'Silent SOS' : _name(data['source'], 'SOS');
    final location = data['location'];
    final address = (location is Map ? location['address'] : null) ?? data['address'];
    final ringSeq = NotificationService.ringSeqOf(data['ringSeq']);
    return InboxItem(
      key: 'sos:$id#$ringSeq',
      type: InboxItemType.sos,
      id: id,
      title: tone == InboxTone.live ? '🚨 $name needs help now!' : '🚨 SOS from $name',
      body: [source, if (address != null && address.toString().trim().isNotEmpty) address.toString().trim()]
          .join(' · '),
      time: time,
      status: status,
      tone: tone,
    );
  }

  static InboxItem? journeyItem(String id, Map<String, dynamic> data, {required String myUid}) {
    final owner = (data['ownerId'] ?? data['owner_uid'])?.toString();
    if (owner == null || owner == myUid) return null;
    final status = (data['status'] ?? '').toString().toLowerCase();
    final time = _date(data['lastUpdatedAt']) ?? _date(data['startedAt']);
    if (time == null) return null;
    final name = _name(data['ownerName'], 'Your contact');
    final dest = data['destination'] is Map ? _name((data['destination'] as Map)['label'], 'their destination') : 'their destination';
    final followed = data['mode']?.toString() == 'followed';
    final (String title, String body, String chip, InboxTone tone) = switch (status) {
      'active' when followed => ('⚠️ $name thinks they are being followed', 'Sharing live location with you.', 'Live', InboxTone.warning),
      'active' => ('🚶 $name started a Safe Journey', 'Heading to $dest.', 'On the way', InboxTone.warning),
      'arrived' => ('✅ $name arrived safely', followed ? 'Followed Mode ended safely.' : 'Reached $dest.', 'Arrived', InboxTone.ok),
      'alert' => ('🚨 $name\'s Safe Journey raised an alert', 'A safety check went unanswered.', 'Alert', InboxTone.live),
      'cancelled' => ('$name ended their Safe Journey', followed ? 'Followed Mode was turned off.' : 'Ended before reaching $dest.', 'Ended', InboxTone.neutral),
      _ => ('', '', '', InboxTone.neutral),
    };
    if (title.isEmpty) return null;
    return InboxItem(
      key: 'journey:$id:$status',
      type: InboxItemType.journey,
      id: id,
      title: title,
      body: body,
      time: time,
      status: chip,
      tone: tone,
    );
  }

  static InboxItem? rideItem(String id, Map<String, dynamic> data, {required String myUid}) {
    final owner = data['userId']?.toString();
    if (owner == null || owner == myUid) return null;
    final status = (data['status'] ?? '').toString().toLowerCase();
    final time = _date(data['lastUpdatedAt']) ?? _date(data['createdAt']);
    if (time == null) return null;
    final name = _name(data['userName'], 'Your contact');
    final rideType = _name(data['rideType'], 'Ride');
    final plate = _name(data['plateFormatted'], 'unknown plate');
    final (String title, String chip, InboxTone tone) = switch (status) {
      'active' => ('🚗 $name started a $rideType ride', 'On a ride', InboxTone.warning),
      'arrived' => ('✅ $name arrived safely', 'Arrived', InboxTone.ok),
      'overdue' => ('⚠️ $name\'s ride is overdue', 'Overdue', InboxTone.live),
      _ => ('', '', InboxTone.neutral),
    };
    if (title.isEmpty) return null;
    return InboxItem(
      key: 'ride:$id:$status',
      type: InboxItemType.ride,
      id: id,
      title: title,
      body: 'Vehicle $plate',
      time: time,
      status: chip,
      tone: tone,
    );
  }

  static InboxItem? requestItem(Map<String, dynamic> request, {required DateTime now}) {
    final id = request['docId']?.toString() ?? '';
    if (id.isEmpty) return null;
    final name = _name(request['senderName'] ?? request['sender_name'], 'Someone');
    final relationship = _name(request['relationship'], '');
    return InboxItem(
      key: 'request:$id',
      type: InboxItemType.request,
      id: id,
      title: '🛡️ $name wants you as their guardian',
      body: relationship.isEmpty ? 'Tap to accept or decline.' : '$relationship · Tap to accept or decline.',
      time: _date(request['createdAt']) ?? now,
      status: 'Pending',
      tone: InboxTone.warning,
    );
  }

  /// "11:32 AM" today, "Yesterday", or "Nov 6" — for list rows.
  static String formatTime(DateTime t, DateTime now) {
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24 && t.day == now.day) return _hhmm(t);
    if (diff.inDays < 2 && now.day - t.day == 1) return 'Yesterday ${_hhmm(t)}';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}, ${_hhmm(t)}';
  }
}
