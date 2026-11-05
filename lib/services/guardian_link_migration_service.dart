import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'guardian_link_logic.dart';

/// One-time, client-side migration from the old mutual guardian links to one-way links.
///
/// Older versions wrote BOTH users into each other's `users/{uid}/contacts` when a request
/// was accepted, so the guardian's SOS also went to the person they protect. For the
/// signed-in user this removes only the entries that the original request records prove were
/// created by that reverse write (see [planOneWayGuardianMigration]). Entries with no request
/// record in either direction are never guessed at: they are left as they are and listed in
/// `users/{uid}.guardianLinkMigration.unresolved`.
///
/// Free on Spark: a few reads per sign-in plus at most one write per removed entry.
class GuardianLinkMigrationService {
  GuardianLinkMigrationService._internal();
  static final GuardianLinkMigrationService instance = GuardianLinkMigrationService._internal();

  static const int migrationVersion = 1;
  static const String summaryField = 'guardianLinkMigration';

  final Set<String> _completedUids = {};
  final Map<String, Future<void>> _inFlight = {};

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  /// Runs the migration for [uid] at most once per app process. A failed run (offline,
  /// denied) is retried on the next call.
  Future<void> runOnceForUser(String uid, String email) {
    if (uid.isEmpty || Firebase.apps.isEmpty || _completedUids.contains(uid)) {
      return Future.value();
    }
    return _inFlight[uid] ??= _run(uid, email.toLowerCase().trim()).whenComplete(() {
      _inFlight.remove(uid);
    });
  }

  Future<void> _run(String uid, String email) async {
    const server = GetOptions(source: Source.server);
    const timeout = Duration(seconds: 10);
    final requests = _firestore.collection('connection_requests');

    try {
      // Evidence must come from the server: a partial cached view could make a real
      // guardian look like a reverse entry. Any failure aborts the whole run.
      final contactsSnap =
          await _firestore.collection('users').doc(uid).collection('contacts').get(server).timeout(timeout);

      final queries = <Query<Map<String, dynamic>>>[
        requests.where('senderId', isEqualTo: uid),
        requests.where('sender_uid', isEqualTo: uid),
        requests.where('receiverId', isEqualTo: uid),
        requests.where('receiver_uid', isEqualTo: uid),
        if (email.isNotEmpty) requests.where('receiver_email', isEqualTo: email),
        if (email.isNotEmpty) requests.where('receiverEmail', isEqualTo: email),
      ];
      final snaps = await Future.wait(queries.map((q) => q.get(server).timeout(timeout)));

      final records = <String, GuardianRequestRecord>{};
      for (final snap in snaps) {
        for (final doc in snap.docs) {
          records[doc.id] = GuardianRequestRecord.fromMap(doc.id, doc.data());
        }
      }

      final contacts = contactsSnap.docs
          .map((d) => GuardianContactEntry.fromMap(d.id, d.data()))
          .toList();

      final decisions = planOneWayGuardianMigration(
        myUid: uid,
        myEmail: email,
        contacts: contacts,
        requests: records.values,
      );

      final removed = <Map<String, dynamic>>[];
      for (final d in decisions.where((d) => d.verdict == GuardianEntryVerdict.reverseEntry)) {
        await _firestore
            .collection('users')
            .doc(uid)
            .collection('contacts')
            .doc(d.entry.docId)
            .delete()
            .timeout(timeout);
        removed.add(_describe(d));
        debugPrint('[GuardianMigration] Removed reverse guardian entry ${d.entry.docId} (${d.entry.email})');
      }

      final unresolved = decisions
          .where((d) => d.verdict == GuardianEntryVerdict.unresolved)
          .map(_describe)
          .toList();
      for (final u in unresolved) {
        debugPrint('[GuardianMigration] Unresolved (left as-is): ${u['docId']} ${u['email']} — ${u['reason']}');
      }

      await _recordSummary(uid, removed: removed, unresolved: unresolved);
      _completedUids.add(uid);
      debugPrint('[GuardianMigration] Done for $uid: ${removed.length} removed, ${unresolved.length} unresolved');
    } catch (e) {
      debugPrint('[GuardianMigration] Skipped for now (will retry): $e');
    }
  }

  Map<String, dynamic> _describe(GuardianEntryDecision d) => {
        'docId': d.entry.docId,
        'uid': d.entry.contactUid,
        'name': d.entry.name,
        'email': d.entry.email,
        'reason': d.reason,
      };

  /// Writes the result to the user's own profile doc so unresolved pairs can be reviewed in
  /// the Firebase console. Skips the write when nothing changed since the last run.
  Future<void> _recordSummary(
    String uid, {
    required List<Map<String, dynamic>> removed,
    required List<Map<String, dynamic>> unresolved,
  }) async {
    final userRef = _firestore.collection('users').doc(uid);
    final current = (await userRef.get().timeout(const Duration(seconds: 10))).data()?[summaryField];
    final previous = current is Map ? current : const {};
    final previousUnresolved = (previous['unresolved'] as List?)?.map((e) => (e as Map)['docId']).toSet() ?? {};
    final unresolvedIds = unresolved.map((e) => e['docId']).toSet();

    final unchanged = previous['version'] == migrationVersion &&
        removed.isEmpty &&
        setEquals(previousUnresolved, unresolvedIds);
    if (unchanged) return;

    final previousRemoved = (previous['removedReverseEntries'] as List?) ?? const [];
    await userRef.set({
      summaryField: {
        'version': migrationVersion,
        'completedAt': FieldValue.serverTimestamp(),
        'removedReverseEntries': [...previousRemoved, ...removed],
        'unresolved': unresolved,
      },
    }, SetOptions(merge: true)).timeout(const Duration(seconds: 10));
  }
}
