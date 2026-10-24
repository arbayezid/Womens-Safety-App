import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../models/contact_model.dart';
import 'auth_service.dart';
import 'contact_service.dart';

/// Service managing real-time mutual consent emergency contact synchronization,
/// email-based user lookup, connection requests, and live Firestore streams.
class ContactSyncService {
  ContactSyncService._internal() {
    _initAuthAndRequestsListener();
  }
  static final ContactSyncService instance = ContactSyncService._internal();

  bool get _isFirebaseReady => Firebase.apps.isNotEmpty;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  String? get _currentUid {
    if (!_isFirebaseReady) return null;
    try {
      return _auth.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  String? get _currentEmail {
    if (!_isFirebaseReady) return null;
    try {
      return _auth.currentUser?.email?.toLowerCase().trim();
    } catch (_) {
      return null;
    }
  }

  // ── Unified Reactive State for Incoming Consent Requests ──
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription? _subUid;
  StreamSubscription? _subUidSnake;
  StreamSubscription? _subEmail;
  StreamSubscription? _subEmailCamel;
  final Map<String, Map<String, dynamic>> _requestsMap = {};
  final StreamController<List<Map<String, dynamic>>> _broadcastRequestsController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  /// Reactive notifier for real-time UI binding
  final ValueNotifier<List<Map<String, dynamic>>> incomingRequestsNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  /// Synchronously accessible list of current pending incoming requests
  List<Map<String, dynamic>> get currentPendingRequests =>
      List.unmodifiable(incomingRequestsNotifier.value);

  void _initAuthAndRequestsListener() {
    if (!_isFirebaseReady) return;
    try {
      _authSubscription?.cancel();
      _authSubscription = _auth.authStateChanges().listen((user) {
        if (user != null) {
          final uid = user.uid;
          final email = (user.email ?? '').toLowerCase().trim();
          _startRequestsListeners(uid, email);
          refreshIncomingRequests();
        } else {
          _cancelRequestsSubscriptions();
          _requestsMap.clear();
          _notifyIncomingRequests();
        }
      }, onError: (e) {
        debugPrint('[ContactSync] Auth state listener notice: $e');
      });
    } catch (e) {
      debugPrint('[ContactSync] Auth listener init notice: $e');
    }
  }

  void _cancelRequestsSubscriptions() {
    _subUid?.cancel();
    _subUidSnake?.cancel();
    _subEmail?.cancel();
    _subEmailCamel?.cancel();
    _subUid = null;
    _subUidSnake = null;
    _subEmail = null;
    _subEmailCamel = null;
  }

  /// Cancels all active Firestore subscriptions and clears in-memory pending request state.
  void purgeOnSignOut() {
    _cancelRequestsSubscriptions();
    _requestsMap.clear();
    _notifyIncomingRequests();
  }

  void _startRequestsListeners(String uid, String email) {
    _cancelRequestsSubscriptions();
    final normalizedEmail = email.toLowerCase().trim();

    void updateSource(String sourceKey, QuerySnapshot<Map<String, dynamic>> snap) {
      _requestsMap.removeWhere((key, val) => val['_source'] == sourceKey);
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['status'] == 'pending') {
          _requestsMap[doc.id] = {'docId': doc.id, '_source': sourceKey, ...data};
        }
      }
      _notifyIncomingRequests();
    }

    if (uid.isNotEmpty) {
      _subUid = _firestore
          .collection('connection_requests')
          .where('receiverId', isEqualTo: uid)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen(
            (snap) => updateSource('uid', snap),
            onError: (e) => debugPrint('[ContactSync] receiverId listener error: $e'),
          );

      _subUidSnake = _firestore
          .collection('connection_requests')
          .where('receiver_uid', isEqualTo: uid)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen(
            (snap) => updateSource('uid_snake', snap),
            onError: (e) => debugPrint('[ContactSync] receiver_uid listener error: $e'),
          );
    }

    if (normalizedEmail.isNotEmpty) {
      _subEmail = _firestore
          .collection('connection_requests')
          .where('receiver_email', isEqualTo: normalizedEmail)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen(
            (snap) => updateSource('email', snap),
            onError: (e) => debugPrint('[ContactSync] receiver_email listener error: $e'),
          );

      _subEmailCamel = _firestore
          .collection('connection_requests')
          .where('receiverEmail', isEqualTo: normalizedEmail)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen(
            (snap) => updateSource('email_camel', snap),
            onError: (e) => debugPrint('[ContactSync] receiverEmail listener error: $e'),
          );
    }
  }

  void _notifyIncomingRequests() {
    final list = _requestsMap.values.toList();
    list.retainWhere((r) => r['status'] == 'pending');
    list.sort((a, b) {
      final aTime = a['createdAt'];
      final bTime = b['createdAt'];
      if (aTime is Timestamp && bTime is Timestamp) {
        return bTime.compareTo(aTime);
      }
      return 0;
    });

    incomingRequestsNotifier.value = List.unmodifiable(list);
    if (!_broadcastRequestsController.isClosed) {
      _broadcastRequestsController.add(List.unmodifiable(list));
    }
  }

  /// Normalizes phone number string into standard international format (+880...)
  String normalizePhone(String rawPhone) {
    String digits = rawPhone.replaceAll(RegExp(r'\s+|-|\(|\)'), '');
    if (digits.startsWith('+')) return digits;
    if (digits.startsWith('00')) return '+${digits.substring(2)}';
    if (digits.startsWith('0')) digits = digits.substring(1);
    return '+880$digits';
  }

  /// Searches for a registered platform user by their email address.
  ///
  /// Throws an [Exception] if the user is trying to add their own email.
  Future<Map<String, dynamic>?> searchUserByEmail(String rawEmail) async {
    final String normalized = rawEmail.toLowerCase().trim();

    final currentEmail = _currentEmail;
    if (currentEmail != null && normalized == currentEmail) {
      throw Exception('You cannot add your own email as an emergency contact.');
    }

    try {
      debugPrint('[ContactSync] 🔍 Querying Firestore users collection for: $normalized');
      var query = await _firestore
          .collection('users')
          .where('email', isEqualTo: normalized)
          .limit(1)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 3));

      if (query.docs.isEmpty) {
        // Fallback check with trimmed original casing
        query = await _firestore
            .collection('users')
            .where('email', isEqualTo: rawEmail.trim())
            .limit(1)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 3));
      }

      if (query.docs.isEmpty) {
        // Fallback check with user_email field
        query = await _firestore
            .collection('users')
            .where('user_email', isEqualTo: normalized)
            .limit(1)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 3));
      }

      if (query.docs.isEmpty) {
        debugPrint('[ContactSync] ⚠️ No registered user found with email: $normalized');
        return null;
      }

      final doc = query.docs.first;
      final data = doc.data();
      debugPrint('[ContactSync] ✅ Found registered user: ${doc.id} (${data['email']})');

      // Guard: User cannot add themselves by UID
      if (doc.id == _currentUid) {
        throw Exception('You cannot add your own account as an emergency contact.');
      }

      return {
        'uid': doc.id,
        'name': data['displayName'] ?? data['name'] ?? 'User',
        'email': data['email'] ?? normalized,
        'phoneNumber': data['phoneNumber'] ?? data['phone'] ?? '',
        'photoUrl': data['photoUrl'] ?? data['photoURL'],
        'safetyScore': data['safetyScore'] ?? 90,
      };
    } catch (e) {
      if (e.toString().contains('cannot add your own')) rethrow;
      debugPrint('[ContactSync] Email search fallback notice (offline or unavailable): $e');
      return null;
    }
  }

  /// Dispatches an email-based connection request to a registered [receiverUid] (if known)
  /// or directly to [receiverEmail].
  ///
  /// Also stores the pending contact in User A's contacts list and local database.
  Future<void> sendConnectionRequest({
    String? receiverUid,
    required String receiverEmail,
    required String receiverName,
    required String relationship,
    String? optionalPhone,
    bool isBackup = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('You must be signed in to send emergency contact requests.');
    }

    final senderId = user.uid;
    final senderEmail = (user.email ?? '').toLowerCase().trim();
    final senderName = user.displayName ?? AuthService.instance.displayName;
    final normalizedReceiverEmail = receiverEmail.toLowerCase().trim();
    final cleanPhone = optionalPhone?.trim() ?? '';
    final safeEmailKey = normalizedReceiverEmail.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

    final requestId = (receiverUid != null && receiverUid.isNotEmpty)
        ? '${senderId}_$receiverUid'
        : '${senderId}_$safeEmailKey';

    // 1. Verify if already mutually added and synced
    if (receiverUid != null && receiverUid.isNotEmpty) {
      try {
        final existingContact = await _firestore
            .collection('users')
            .doc(senderId)
            .collection('contacts')
            .doc(receiverUid)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 2));

        if (existingContact.exists && existingContact.data()?['is_synced_app_user'] == true) {
          // Check if this contact is genuinely present in the user's active local emergency contacts list
          final localContacts = await ContactService.instance.getContacts();
          final isLocallyPresent = localContacts.any((c) =>
              (c.contactUid == receiverUid ||
                  c.id == receiverUid ||
                  c.email.toLowerCase().trim() == normalizedReceiverEmail));

          if (isLocallyPresent) {
            throw Exception('This contact is already in your verified emergency contact list.');
          } else {
            // It was previously removed by the user locally, but an orphaned record remained in Firestore.
            // Clean up the stale record so the user can re-invite them!
            debugPrint('[ContactSync] Found stale synced contact in Firestore ($receiverUid). Cleaning up to allow re-invite...');
            await _firestore
                .collection('users')
                .doc(senderId)
                .collection('contacts')
                .doc(receiverUid)
                .delete();
          }
        }
      } catch (e) {
        if (e.toString().contains('already in your verified')) rethrow;
        debugPrint('[ContactSync] Existing contact check notice: $e');
      }
    }

    // 2. Check if a request is already pending
    try {
      final existingReq = await _firestore
          .collection('connection_requests')
          .doc(requestId)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 2));
      if (existingReq.exists && existingReq.data()?['status'] == 'pending') {
        throw Exception('A connection request is already pending for this user.');
      }
    } catch (e) {
      if (e.toString().contains('already pending')) rethrow;
      debugPrint('[ContactSync] Existing request check notice: $e');
    }

    // 3. Write new pending connection request to Firestore (with timeout and offline queuing)
    try {
      await _firestore.collection('connection_requests').doc(requestId).set({
        'requestId': requestId,
        'id': requestId,
        'sender_uid': senderId,
        'senderId': senderId,
        'sender_name': senderName,
        'senderName': senderName,
        'sender_email': senderEmail,
        'senderEmail': senderEmail,
        'receiver_uid': receiverUid ?? '',
        'receiverId': receiverUid ?? '',
        'receiver_email': normalizedReceiverEmail,
        'receiverEmail': normalizedReceiverEmail,
        'relationship': relationship,
        'optional_phone': cleanPhone,
        'optionalPhone': cleanPhone,
        'isBackup': isBackup,
        'is_backup': isBackup,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'respondedAt': null,
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[ContactSync] Firestore connection request queued in offline cache: $e');
    }

    // 4. Save into Sender A's contacts list as pending
    final contactId = (receiverUid != null && receiverUid.isNotEmpty)
        ? receiverUid
        : 'pending_$safeEmailKey';

    final contactModel = ContactModel(
      id: contactId,
      name: receiverName,
      email: normalizedReceiverEmail,
      phone: cleanPhone,
      relationship: relationship,
      contactUid: receiverUid,
      isSyncedAppUser: false,
      syncStatus: 'pending',
      isPrimary: true,
      isBackup: isBackup,
    );

    try {
      await _firestore
          .collection('users')
          .doc(senderId)
          .collection('contacts')
          .doc(contactId)
          .set(contactModel.toMap(), SetOptions(merge: true))
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[ContactSync] Firestore contact write queued in offline cache: $e');
    }

    // 5. Always persist locally in SharedPreferences for offline SMS fallback
    await ContactService.instance.addContact(contactModel);

    debugPrint('[ContactSync] ✅ Successfully saved contact and dispatched request: $requestId');
  }

  /// Saves an emergency contact whose email is not registered in the app.
  ///
  /// This enables the contact to receive offline SMS distress alerts immediately.
  Future<ContactModel> saveOfflineContact({
    required String name,
    required String email,
    required String relationship,
    String? optionalPhone,
    bool isBackup = false,
  }) async {
    final user = _auth.currentUser;
    final senderId = user?.uid;
    final normalizedEmail = email.toLowerCase().trim();
    final cleanPhone = optionalPhone?.trim() ?? '';
    final String contactId = 'offline_${DateTime.now().millisecondsSinceEpoch}';

    final contactModel = ContactModel(
      id: contactId,
      name: name.trim(),
      email: normalizedEmail,
      phone: cleanPhone,
      relationship: relationship,
      contactUid: null,
      isSyncedAppUser: false,
      syncStatus: 'offline_only',
      isPrimary: true,
      isBackup: isBackup,
    );

    if (senderId != null) {
      try {
        await _firestore
            .collection('users')
            .doc(senderId)
            .collection('contacts')
            .doc(contactId)
            .set(contactModel.toMap());
      } catch (e) {
        debugPrint('[ContactSync] Offline contact Firestore sync warning: $e');
      }
    }

    // Cache locally for offline SMS dispatch
    await ContactService.instance.addContact(contactModel);
    debugPrint('[ContactSync] 📱 Saved offline contact: ${contactModel.name} ($cleanPhone)');
    return contactModel;
  }

  /// Real-time stream of incoming pending requests directed to the current user (User B),
  /// matching both their registered UID and their Google email address.
  /// Replays currently cached requests immediately to eliminate tab switch and rendering delay.
  Stream<List<Map<String, dynamic>>> streamIncomingRequests() {
    final uid = _currentUid;
    final email = _currentEmail;
    if (_subUid == null && (uid != null || email != null)) {
      _startRequestsListeners(uid ?? '', email ?? '');
    }

    return (() async* {
      yield currentPendingRequests;
      yield* _broadcastRequestsController.stream;
    })();
  }

  /// Force-refreshes pending incoming requests from Firestore (both server and cache)
  /// and updates the shared stream and reactive notifier.
  Future<List<Map<String, dynamic>>> refreshIncomingRequests() async {
    final uid = _currentUid;
    final email = _currentEmail;
    if (uid == null && email == null) return [];

    try {
      debugPrint('[ContactSync] 🔄 Actively refreshing incoming connection requests...');
      final normalizedEmail = (email ?? '').toLowerCase().trim();

      final List<QuerySnapshot<Map<String, dynamic>>> results = await Future.wait([
        if (uid != null && uid.isNotEmpty) ...[
          _firestore
              .collection('connection_requests')
              .where('receiverId', isEqualTo: uid)
              .where('status', isEqualTo: 'pending')
              .get(const GetOptions(source: Source.serverAndCache)),
          _firestore
              .collection('connection_requests')
              .where('receiver_uid', isEqualTo: uid)
              .where('status', isEqualTo: 'pending')
              .get(const GetOptions(source: Source.serverAndCache)),
        ],
        if (normalizedEmail.isNotEmpty) ...[
          _firestore
              .collection('connection_requests')
              .where('receiver_email', isEqualTo: normalizedEmail)
              .where('status', isEqualTo: 'pending')
              .get(const GetOptions(source: Source.serverAndCache)),
          _firestore
              .collection('connection_requests')
              .where('receiverEmail', isEqualTo: normalizedEmail)
              .where('status', isEqualTo: 'pending')
              .get(const GetOptions(source: Source.serverAndCache)),
        ],
      ]);

      _requestsMap.clear();
      for (final snap in results) {
        for (final doc in snap.docs) {
          final data = doc.data();
          if (data['status'] == 'pending') {
            _requestsMap[doc.id] = {'docId': doc.id, ...data};
          }
        }
      }
      _notifyIncomingRequests();
      return currentPendingRequests;
    } catch (e) {
      debugPrint('[ContactSync] Error actively refreshing requests: $e');
      return currentPendingRequests;
    }
  }

  /// Real-time stream of emergency contacts in `users/{currentUid}/contacts`.
  Stream<List<ContactModel>> streamSyncedContacts() {
    final uid = _currentUid;
    if (uid == null) return const Stream.empty();

    return _firestore
        .collection('users')
        .doc(uid)
        .collection('contacts')
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) {
              final data = doc.data();
              return ContactModel.fromMap({
                ...data,
                'id': doc.id,
                'contactUid': data['contactUid'] ?? data['contact_uid'] ?? doc.id,
              });
            }).toList());
  }

  /// Approves an incoming connection request and updates its state to `accepted`.
  ///
  /// Executes atomic batch write so both User A and User B are linked simultaneously.
  Future<void> acceptRequest(String requestId) async {
    // 0. Optimistically remove from pending requests map for instant UI response
    _requestsMap.remove(requestId);
    _notifyIncomingRequests();

    final reqDoc = await _firestore.collection('connection_requests').doc(requestId).get();
    if (!reqDoc.exists) return;

    final data = reqDoc.data()!;
    final senderId = (data['sender_uid'] ?? data['senderId']) as String;
    final String receiverId = ((data['receiver_uid'] ?? data['receiverId'])?.toString().isNotEmpty == true)
        ? (data['receiver_uid'] ?? data['receiverId']) as String
        : (_currentUid ?? '');
    if (receiverId.isEmpty) return;

    final senderName = (data['sender_name'] ?? data['senderName']) ?? 'Emergency Contact';
    final senderEmail = (data['sender_email'] ?? data['senderEmail']) ?? '';
    var senderPhone = (data['optional_phone'] ?? data['optionalPhone'] ?? '').toString();
    final relationship = (data['relationship'] as String?) ?? 'Guardian';

    final currentUserName = AuthService.instance.displayName;
    final currentUserEmail = _currentEmail ?? '';
    var currentUserPhone = AuthService.instance.currentProfile.phone;

    // Fallback: Resolve sender or current user phone from their Firestore profiles if not in request
    if (senderPhone.isEmpty) {
      try {
        final senderDoc = await _firestore.collection('users').doc(senderId).get();
        if (senderDoc.exists && senderDoc.data() != null) {
          senderPhone = (senderDoc.data()!['phoneNumber'] ?? senderDoc.data()!['phone'] ?? '').toString();
        }
      } catch (_) {}
    }
    if (currentUserPhone.isEmpty) {
      try {
        final receiverDoc = await _firestore.collection('users').doc(receiverId).get();
        if (receiverDoc.exists && receiverDoc.data() != null) {
          currentUserPhone = (receiverDoc.data()!['phoneNumber'] ?? receiverDoc.data()!['phone'] ?? '').toString();
        }
      } catch (_) {}
    }

    // 1. Mark request as accepted in connection_requests
    await _firestore.collection('connection_requests').doc(requestId).update({
      'status': 'accepted',
      'receiver_uid': receiverId,
      'receiverId': receiverId,
      'respondedAt': FieldValue.serverTimestamp(),
    });

    // 2. Client-side optimistic batch write for instant mutual linking
    try {
      final batch = _firestore.batch();

      // Add/Update Receiver B in Sender A's contacts list
      final senderContactRef =
          _firestore.collection('users').doc(senderId).collection('contacts').doc(receiverId);
      batch.set(senderContactRef, {
        'id': receiverId,
        'contactUid': receiverId,
        'contact_uid': receiverId,
        'name': currentUserName,
        'contact_name': currentUserName,
        'email': currentUserEmail,
        'contact_email': currentUserEmail,
        'phone': currentUserPhone,
        'contact_optional_phone': currentUserPhone,
        'relationship': relationship,
        'isPrimary': true,
        'isSyncedAppUser': true,
        'is_synced_app_user': true,
        'syncStatus': 'synced',
        'sync_status': 'synced',
        'syncedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Clean up placeholder contact doc if sent by email
      final safeEmailKey = currentUserEmail.toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      final placeholderRef = _firestore
          .collection('users')
          .doc(senderId)
          .collection('contacts')
          .doc('pending_$safeEmailKey');
      batch.delete(placeholderRef);

      // Add Sender A into Receiver B's contacts list
      final receiverContactRef =
          _firestore.collection('users').doc(receiverId).collection('contacts').doc(senderId);
      batch.set(receiverContactRef, {
        'id': senderId,
        'contactUid': senderId,
        'contact_uid': senderId,
        'name': senderName,
        'contact_name': senderName,
        'email': senderEmail,
        'contact_email': senderEmail,
        'phone': senderPhone,
        'contact_optional_phone': senderPhone,
        'relationship': 'Safety Ward',
        'isPrimary': true,
        'isSyncedAppUser': true,
        'is_synced_app_user': true,
        'syncStatus': 'synced',
        'sync_status': 'synced',
        'syncedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await batch.commit();
      debugPrint('[ContactSync] 🤝 Mutually linked $senderId and $receiverId');
    } catch (e) {
      debugPrint('[ContactSync] Batch mutual linking notice: $e');
    }

    // 3. Save into local persistent storage for offline fallback & instant promotion in UI
    final localContact = ContactModel(
      id: senderId,
      name: senderName.toString(),
      email: senderEmail.toString(),
      phone: senderPhone.toString(),
      relationship: 'Safety Ward',
      contactUid: senderId,
      isSyncedAppUser: true,
      syncStatus: 'synced',
      isPrimary: true,
    );
    await ContactService.instance.addContact(localContact);
  }

  /// Rejects an incoming connection request and updates its state to `rejected`.
  Future<void> rejectRequest(String requestId) async {
    // 0. Optimistically remove from pending requests map for instant UI response
    _requestsMap.remove(requestId);
    _notifyIncomingRequests();

    await _firestore.collection('connection_requests').doc(requestId).update({
      'status': 'rejected',
      'respondedAt': FieldValue.serverTimestamp(),
    });
    debugPrint('[ContactSync] ❌ Request rejected: $requestId');
  }

  /// Permanently removes a contact from the user's Firestore list, mutual partner's list,
  /// any existing connection requests, and local device storage.
  Future<void> deleteSyncedContact(
    dynamic contactOrId, {
    String? contactUid,
    String? email,
    String? phone,
  }) async {
    final uid = _currentUid;
    String contactId = '';
    String? resolvedUid = contactUid;
    String? resolvedEmail = email;
    String? resolvedPhone = phone;

    if (contactOrId is ContactModel) {
      contactId = contactOrId.id;
      resolvedUid ??= contactOrId.contactUid;
      resolvedEmail ??= contactOrId.email;
      resolvedPhone ??= contactOrId.phone;
    } else if (contactOrId is String) {
      contactId = contactOrId;
    }

    final normalizedEmail = resolvedEmail?.toLowerCase().trim() ?? '';
    final safeEmailKey = normalizedEmail.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

    if (uid != null) {
      // 1. Delete from current user's contacts subcollection
      final List<String> docIdsToDelete = {
        if (contactId.isNotEmpty) contactId,
        if (resolvedUid != null && resolvedUid.isNotEmpty) resolvedUid,
        if (safeEmailKey.isNotEmpty) 'pending_$safeEmailKey',
      }.toList();

      for (final docId in docIdsToDelete) {
        try {
          await _firestore
              .collection('users')
              .doc(uid)
              .collection('contacts')
              .doc(docId)
              .delete();
        } catch (e) {
          debugPrint('[ContactSync] Error deleting own contact doc $docId: $e');
        }
      }

      // Query any leftover documents in current user's contacts by email
      if (normalizedEmail.isNotEmpty) {
        try {
          final query = await _firestore
              .collection('users')
              .doc(uid)
              .collection('contacts')
              .where('email', isEqualTo: normalizedEmail)
              .get(const GetOptions(source: Source.serverAndCache))
              .timeout(const Duration(seconds: 2));
          for (final doc in query.docs) {
            await doc.reference.delete();
          }
        } catch (e) {
          debugPrint('[ContactSync] Error cleaning up contacts by email: $e');
        }
      }

      // 2. Mutual unlink: Remove current user from partner's contacts subcollection
      if (resolvedUid != null && resolvedUid.isNotEmpty) {
        try {
          await _firestore
              .collection('users')
              .doc(resolvedUid)
              .collection('contacts')
              .doc(uid)
              .delete();
        } catch (e) {
          debugPrint('[ContactSync] Notice unlinking partner contacts doc ($resolvedUid): $e');
        }

        if (_currentEmail != null && _currentEmail!.isNotEmpty) {
          final mySafeEmail = _currentEmail!.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
          try {
            await _firestore
                .collection('users')
                .doc(resolvedUid)
                .collection('contacts')
                .doc('pending_$mySafeEmail')
                .delete();
          } catch (_) {}
        }
      }

      // 3. Delete connection requests in both directions & email
      final List<String> requestIdsToDelete = {
        if (resolvedUid != null && resolvedUid.isNotEmpty) ...[
          '${uid}_$resolvedUid',
          '${resolvedUid}_$uid',
        ],
        if (safeEmailKey.isNotEmpty) '${uid}_$safeEmailKey',
      }.toList();

      for (final reqId in requestIdsToDelete) {
        try {
          await _firestore.collection('connection_requests').doc(reqId).delete();
        } catch (e) {
          // If delete rule prevented deletion, cancel it
          try {
            await _firestore.collection('connection_requests').doc(reqId).update({
              'status': 'cancelled',
              'respondedAt': FieldValue.serverTimestamp(),
            });
          } catch (_) {}
        }
      }
    }

    // 4. Permanently remove from in-memory cache and cloud
    await ContactService.instance.deleteContact(
      contactId,
      contactUid: resolvedUid,
      email: normalizedEmail,
      phone: resolvedPhone,
    );

    debugPrint('[ContactSync] 🗑️ Permanently deleted contact: $contactId / $resolvedUid / $normalizedEmail');
  }

  /// Upgrades an existing offline contact by dispatching a Guardian Connection Request.
  /// Works even if the contact has not yet initialized their Firestore profile.
  Future<bool> upgradeOfflineToSynced(ContactModel offlineContact) async {
    final email = offlineContact.email.trim().toLowerCase();
    if (email.isEmpty) return false;

    final targetUser = await searchUserByEmail(email);
    final String? receiverUid = targetUser?['uid'] as String?;

    await sendConnectionRequest(
      receiverUid: receiverUid,
      receiverEmail: email,
      receiverName: offlineContact.name,
      relationship: offlineContact.relationship,
      optionalPhone: offlineContact.phone.isNotEmpty ? offlineContact.phone : null,
    );

    // If the old contact used an offline_ timestamp ID, remove the old offline record
    if (offlineContact.id.startsWith('offline_')) {
      await ContactService.instance.deleteContact(offlineContact.id);
    }

    return true;
  }
}
