import 'package:cloud_firestore/cloud_firestore.dart';

/// Pure (Firestore-free) rules for one-way guardian links.
///
/// A guardian link has exactly one direction: the requester (sender of a
/// `connection_requests` document) is protected, and the accepter (receiver) is
/// their guardian. The protected user's `users/{uid}/contacts` list is the single
/// source of truth for who receives their alerts; the guardian sees the link only
/// through the accepted request ("People I Protect").

/// Same key the app uses for email-addressed request and placeholder IDs.
String guardianEmailKey(String email) =>
    email.toLowerCase().trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

String _str(Object? value) => value?.toString().trim() ?? '';

/// A `connection_requests` document, normalized across its camelCase and
/// snake_case field variants.
class GuardianRequestRecord {
  final String id;
  final String senderUid;
  final String senderEmail;
  final String senderName;
  final String receiverUid;
  final String receiverEmail;
  final String relationship;
  final String status;
  final DateTime? createdAt;
  final DateTime? respondedAt;

  const GuardianRequestRecord({
    required this.id,
    required this.senderUid,
    this.senderEmail = '',
    this.senderName = '',
    this.receiverUid = '',
    this.receiverEmail = '',
    this.relationship = '',
    required this.status,
    this.createdAt,
    this.respondedAt,
  });

  factory GuardianRequestRecord.fromMap(String id, Map<String, dynamic> data) {
    DateTime? time(Object? raw) => raw is Timestamp ? raw.toDate() : (raw is DateTime ? raw : null);
    String firstNonEmpty(Object? a, Object? b) => _str(a).isNotEmpty ? _str(a) : _str(b);
    return GuardianRequestRecord(
      id: id,
      senderUid: firstNonEmpty(data['senderId'], data['sender_uid']),
      senderEmail: firstNonEmpty(data['senderEmail'], data['sender_email']).toLowerCase(),
      senderName: firstNonEmpty(data['senderName'], data['sender_name']),
      receiverUid: firstNonEmpty(data['receiverId'], data['receiver_uid']),
      receiverEmail: firstNonEmpty(data['receiverEmail'], data['receiver_email']).toLowerCase(),
      relationship: _str(data['relationship']),
      status: _str(data['status']).toLowerCase(),
      createdAt: time(data['createdAt']),
      respondedAt: time(data['respondedAt']),
    );
  }

  bool get isAccepted => status == 'accepted';
  bool get isPending => status == 'pending';

  bool isSentBy(String uid) => uid.isNotEmpty && senderUid == uid;

  /// True when this request is addressed to the user with [uid] / [email].
  bool isAddressedTo(String uid, String email) {
    if (uid.isNotEmpty && receiverUid == uid) return true;
    final e = email.toLowerCase().trim();
    return e.isNotEmpty && receiverEmail == e;
  }
}

/// Someone who added the current user as their guardian and whose alerts the
/// current user therefore receives. Read-only.
class ProtectedPerson {
  final String uid;
  final String name;
  final String email;

  /// How the protected person labelled the current user (e.g. "Mother").
  final String relationship;
  final DateTime? since;
  final String requestId;

  const ProtectedPerson({
    required this.uid,
    required this.name,
    required this.email,
    required this.relationship,
    required this.requestId,
    this.since,
  });

  String get initial {
    final source = name.trim().isNotEmpty ? name.trim() : email.trim();
    return source.isEmpty ? '?' : source[0].toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is ProtectedPerson &&
      other.uid == uid &&
      other.name == name &&
      other.email == email &&
      other.relationship == relationship &&
      other.requestId == requestId &&
      other.since == since;

  @override
  int get hashCode => Object.hash(uid, name, email, relationship, requestId, since);
}

/// Derives "People I Protect" from accepted requests addressed to the current
/// user. One entry per protected user, most recent first.
List<ProtectedPerson> derivePeopleIProtect(
  Iterable<GuardianRequestRecord> requests, {
  required String myUid,
  required String myEmail,
}) {
  final byUid = <String, ProtectedPerson>{};
  for (final r in requests) {
    if (!r.isAccepted || r.senderUid.isEmpty || r.senderUid == myUid) continue;
    if (!r.isAddressedTo(myUid, myEmail)) continue;
    final person = ProtectedPerson(
      uid: r.senderUid,
      name: r.senderName.isNotEmpty ? r.senderName : r.senderEmail,
      email: r.senderEmail,
      relationship: r.relationship,
      requestId: r.id,
      since: r.respondedAt ?? r.createdAt,
    );
    final existing = byUid[r.senderUid];
    final existingTime = existing?.since ?? DateTime.fromMillisecondsSinceEpoch(0);
    final newTime = person.since ?? DateTime.fromMillisecondsSinceEpoch(0);
    if (existing == null || newTime.isAfter(existingTime)) {
      byUid[r.senderUid] = person;
    }
  }
  final list = byUid.values.toList()
    ..sort((a, b) => (b.since ?? DateTime(0)).compareTo(a.since ?? DateTime(0)));
  return list;
}

/// Minimal view of a `users/{uid}/contacts` document used by the migration.
class GuardianContactEntry {
  final String docId;
  final String contactUid;
  final String email;
  final String name;
  final bool isSyncedAppUser;
  final String syncStatus;

  const GuardianContactEntry({
    required this.docId,
    required this.contactUid,
    required this.email,
    required this.name,
    required this.isSyncedAppUser,
    required this.syncStatus,
  });

  factory GuardianContactEntry.fromMap(String docId, Map<String, dynamic> data) {
    final uid = _str(data['contactUid']).isNotEmpty ? _str(data['contactUid']) : _str(data['contact_uid']);
    final email = _str(data['email']).isNotEmpty ? _str(data['email']) : _str(data['contact_email']);
    final status = _str(data['syncStatus']).isNotEmpty ? _str(data['syncStatus']) : _str(data['sync_status']);
    return GuardianContactEntry(
      docId: docId,
      contactUid: uid.isNotEmpty ? uid : docId,
      email: email.toLowerCase(),
      name: _str(data['name']).isNotEmpty ? _str(data['name']) : _str(data['contact_name']),
      isSyncedAppUser: data['isSyncedAppUser'] == true || data['is_synced_app_user'] == true,
      syncStatus: status.toLowerCase(),
    );
  }

  /// Only linked app-user entries can be reverse entries. Pending invitations,
  /// placeholders and offline (SMS-only) contacts are always the owner's own choice.
  bool get isLinkedAppUser =>
      (isSyncedAppUser || syncStatus == 'synced') &&
      !docId.startsWith('pending_') &&
      !docId.startsWith('offline_') &&
      contactUid.isNotEmpty &&
      !contactUid.startsWith('offline_');
}

enum GuardianEntryVerdict {
  /// The owner sent this contact a request (accepted or still pending): a real guardian.
  keep,

  /// Created by the old mutual-accept bug: the owner accepted the contact's request
  /// and never asked them to be a guardian. Must be removed from the guardian list.
  reverseEntry,

  /// No request record proves either direction. Left untouched.
  unresolved,
}

class GuardianEntryDecision {
  final GuardianContactEntry entry;
  final GuardianEntryVerdict verdict;
  final String reason;
  const GuardianEntryDecision(this.entry, this.verdict, this.reason);
}

/// Decides, from the original request records, what each linked contact in the
/// current user's guardian list is.
///
/// [requests] must contain every request the user sent and every request
/// addressed to them, read from the server (an incomplete list could make a
/// real guardian look like a reverse entry).
List<GuardianEntryDecision> planOneWayGuardianMigration({
  required String myUid,
  required String myEmail,
  required Iterable<GuardianContactEntry> contacts,
  required Iterable<GuardianRequestRecord> requests,
}) {
  final email = myEmail.toLowerCase().trim();
  final outgoing = requests.where((r) => r.isSentBy(myUid)).toList();
  final incoming =
      requests.where((r) => !r.isSentBy(myUid) && r.isAddressedTo(myUid, email)).toList();

  final decisions = <GuardianEntryDecision>[];
  for (final c in contacts) {
    if (!c.isLinkedAppUser) continue;

    bool targetsContact(GuardianRequestRecord r) =>
        r.receiverUid == c.contactUid ||
        r.receiverUid == c.docId ||
        (c.email.isNotEmpty && r.receiverEmail == c.email);

    final mine = outgoing.where(targetsContact).toList();
    if (mine.any((r) => r.isAccepted || r.isPending)) {
      decisions.add(GuardianEntryDecision(
          c, GuardianEntryVerdict.keep, 'You sent this contact a guardian request'));
      continue;
    }

    final theirs = incoming.where((r) => r.senderUid == c.contactUid || r.senderUid == c.docId);
    if (theirs.any((r) => r.isAccepted)) {
      decisions.add(GuardianEntryDecision(c, GuardianEntryVerdict.reverseEntry,
          'You accepted their request; you never asked them to be your guardian'));
      continue;
    }

    decisions.add(GuardianEntryDecision(c, GuardianEntryVerdict.unresolved,
        mine.isEmpty && theirs.isEmpty
            ? 'No request record in either direction'
            : 'Request records exist but none was accepted'));
  }
  return decisions;
}
