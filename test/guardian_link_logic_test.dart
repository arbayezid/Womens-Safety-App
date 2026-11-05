import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/guardian_link_logic.dart';

const a = 'uid_a';
const b = 'uid_b';
const c = 'uid_c';
const aEmail = 'alice@example.com';
const bEmail = 'bob@example.com';

GuardianRequestRecord req(String sender, String receiver, String status,
        {String receiverEmail = '', String senderEmail = '', String name = '', DateTime? at}) =>
    GuardianRequestRecord(
      id: '${sender}_${receiver.isNotEmpty ? receiver : guardianEmailKey(receiverEmail)}',
      senderUid: sender,
      senderEmail: senderEmail,
      senderName: name,
      receiverUid: receiver,
      receiverEmail: receiverEmail,
      relationship: 'Sister',
      status: status,
      respondedAt: at,
    );

GuardianContactEntry linked(String uid, {String email = '', String status = 'synced', bool synced = true}) =>
    GuardianContactEntry(
      docId: uid,
      contactUid: uid,
      email: email,
      name: uid,
      isSyncedAppUser: synced,
      syncStatus: status,
    );

GuardianEntryVerdict verdictFor(List<GuardianEntryDecision> decisions, String docId) =>
    decisions.firstWhere((d) => d.entry.docId == docId).verdict;

void main() {
  group('GuardianRequestRecord.fromMap', () {
    test('reads camelCase and snake_case variants and lowercases emails', () {
      final snake = GuardianRequestRecord.fromMap('x', {
        'sender_uid': a,
        'sender_email': 'Alice@Example.com',
        'sender_name': 'Alice',
        'receiver_uid': b,
        'receiver_email': 'BOB@example.com',
        'status': 'accepted',
        'respondedAt': Timestamp.fromDate(DateTime(2026, 1, 2)),
      });
      expect(snake.senderUid, a);
      expect(snake.senderEmail, aEmail);
      expect(snake.receiverUid, b);
      expect(snake.receiverEmail, bEmail);
      expect(snake.isAccepted, isTrue);
      expect(snake.respondedAt, DateTime(2026, 1, 2));

      final camel = GuardianRequestRecord.fromMap('y', {
        'senderId': a,
        'receiverId': '',
        'receiverEmail': bEmail,
        'status': 'pending',
      });
      expect(camel.senderUid, a);
      expect(camel.receiverUid, '');
      expect(camel.isAddressedTo(b, bEmail), isTrue, reason: 'email-addressed request');
      expect(camel.isPending, isTrue);
    });

    test('email key matches the app request/placeholder id format', () {
      expect(guardianEmailKey(' Bob.Smith+1@Example.com '), 'bob_smith_1_example_com');
    });
  });

  group('derivePeopleIProtect', () {
    test('A adds B, B accepts: B protects A; A protects nobody', () {
      final requests = [req(a, b, 'accepted', senderEmail: aEmail, name: 'Alice')];

      final forB = derivePeopleIProtect(requests, myUid: b, myEmail: bEmail);
      expect(forB.map((p) => p.uid), [a]);
      expect(forB.single.name, 'Alice');
      expect(forB.single.relationship, 'Sister');

      final forA = derivePeopleIProtect(requests, myUid: a, myEmail: aEmail);
      expect(forA, isEmpty);
    });

    test('pending, rejected and cancelled requests are not links', () {
      for (final status in ['pending', 'rejected', 'cancelled']) {
        expect(derivePeopleIProtect([req(a, b, status)], myUid: b, myEmail: bEmail), isEmpty,
            reason: status);
      }
    });

    test('email-addressed accepted request counts', () {
      final r = req(a, '', 'accepted', receiverEmail: bEmail, name: 'Alice');
      expect(derivePeopleIProtect([r], myUid: b, myEmail: bEmail).single.uid, a);
    });

    test('requests addressed to someone else are ignored', () {
      expect(derivePeopleIProtect([req(a, c, 'accepted')], myUid: b, myEmail: bEmail), isEmpty);
    });

    test('duplicate requests from the same person collapse to the latest', () {
      final people = derivePeopleIProtect([
        req(a, b, 'accepted', name: 'Old', at: DateTime(2026, 1, 1)),
        req(a, '', 'accepted', receiverEmail: bEmail, name: 'New', at: DateTime(2026, 3, 1)),
      ], myUid: b, myEmail: bEmail);
      expect(people.single.name, 'New');
    });

    test('two separate requests: each user protects the other', () {
      final requests = [req(a, b, 'accepted'), req(b, a, 'accepted')];
      expect(derivePeopleIProtect(requests, myUid: a, myEmail: aEmail).single.uid, b);
      expect(derivePeopleIProtect(requests, myUid: b, myEmail: bEmail).single.uid, a);
    });
  });

  group('planOneWayGuardianMigration', () {
    test('old mutual pair from one request: requester keeps guardian, reverse entry is removed', () {
      final requests = [req(a, b, 'accepted')];

      final onA = planOneWayGuardianMigration(
          myUid: a, myEmail: aEmail, contacts: [linked(b, email: bEmail)], requests: requests);
      expect(verdictFor(onA, b), GuardianEntryVerdict.keep);

      final onB = planOneWayGuardianMigration(
          myUid: b, myEmail: bEmail, contacts: [linked(a, email: aEmail)], requests: requests);
      expect(verdictFor(onB, a), GuardianEntryVerdict.reverseEntry);
    });

    test('both users requested each other: both directions are kept', () {
      final requests = [req(a, b, 'accepted'), req(b, a, 'accepted')];
      final onA = planOneWayGuardianMigration(
          myUid: a, myEmail: aEmail, contacts: [linked(b)], requests: requests);
      final onB = planOneWayGuardianMigration(
          myUid: b, myEmail: bEmail, contacts: [linked(a)], requests: requests);
      expect(verdictFor(onA, b), GuardianEntryVerdict.keep);
      expect(verdictFor(onB, a), GuardianEntryVerdict.keep);
    });

    test('own request still pending is kept (user asked, consent pending)', () {
      final onB = planOneWayGuardianMigration(
        myUid: b,
        myEmail: bEmail,
        contacts: [linked(a)],
        requests: [req(a, b, 'accepted'), req(b, a, 'pending')],
      );
      expect(verdictFor(onB, a), GuardianEntryVerdict.keep);
    });

    test('own request rejected but theirs accepted: reverse entry', () {
      final onB = planOneWayGuardianMigration(
        myUid: b,
        myEmail: bEmail,
        contacts: [linked(a)],
        requests: [req(a, b, 'accepted'), req(b, a, 'rejected')],
      );
      expect(verdictFor(onB, a), GuardianEntryVerdict.reverseEntry);
    });

    test('own email-addressed accepted request is matched by email and kept', () {
      final onA = planOneWayGuardianMigration(
        myUid: a,
        myEmail: aEmail,
        contacts: [linked(b, email: bEmail)],
        requests: [req(a, '', 'accepted', receiverEmail: bEmail)],
      );
      expect(verdictFor(onA, b), GuardianEntryVerdict.keep);
    });

    test('no request record in either direction: unresolved, never guessed', () {
      final decisions = planOneWayGuardianMigration(
          myUid: b, myEmail: bEmail, contacts: [linked(a)], requests: const []);
      expect(verdictFor(decisions, a), GuardianEntryVerdict.unresolved);
    });

    test('incoming request not accepted and no own request: unresolved', () {
      final decisions = planOneWayGuardianMigration(
          myUid: b, myEmail: bEmail, contacts: [linked(a)], requests: [req(a, b, 'cancelled')]);
      expect(verdictFor(decisions, a), GuardianEntryVerdict.unresolved);
    });

    test('pending invitations, placeholders and offline contacts are never touched', () {
      final contacts = [
        linked(c, status: 'pending', synced: false),
        const GuardianContactEntry(
            docId: 'pending_carol_example_com',
            contactUid: 'pending_carol_example_com',
            email: 'carol@example.com',
            name: 'Carol',
            isSyncedAppUser: false,
            syncStatus: 'pending'),
        const GuardianContactEntry(
            docId: 'offline_123',
            contactUid: 'offline_123',
            email: '',
            name: 'Dad',
            isSyncedAppUser: false,
            syncStatus: 'offline_only'),
      ];
      final decisions = planOneWayGuardianMigration(
          myUid: b, myEmail: bEmail, contacts: contacts, requests: [req(c, b, 'accepted')]);
      expect(decisions, isEmpty);
    });

    test('contact entry parsed from snake_case Firestore fields', () {
      final entry = GuardianContactEntry.fromMap(a, {
        'contact_uid': a,
        'contact_email': aEmail,
        'contact_name': 'Alice',
        'is_synced_app_user': true,
        'sync_status': 'synced',
      });
      expect(entry.isLinkedAppUser, isTrue);
      final decisions = planOneWayGuardianMigration(
          myUid: b, myEmail: bEmail, contacts: [entry], requests: [req(a, b, 'accepted')]);
      expect(verdictFor(decisions, a), GuardianEntryVerdict.reverseEntry);
    });
  });
}
