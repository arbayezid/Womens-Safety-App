import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../models/contact_model.dart';
import 'auth_service.dart';
import 'contact_service.dart';
import 'guardian_link_logic.dart';
import 'guardian_link_migration_service.dart';

/// Service managing consent-based, one-way guardian links, email-based user lookup,
/// connection requests, and live Firestore streams.
///
/// Direction: the sender of a request is protected; the accepter becomes their
/// guardian. Only the sender's `users/{uid}/contacts` list gains an entry. The
/// accepter sees the link in [protectedPeopleNotifier] ("People I Protect").
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
  StreamSubscription? _subSentRequests;
  Timer? _heartbeatTimer;

  final Map<String, Map<String, dynamic>> _docsByReceiverId = {};
  final Map<String, Map<String, dynamic>> _docsByReceiverUid = {};
  final Map<String, Map<String, dynamic>> _docsByReceiverEmail = {};
  final Map<String, Map<String, dynamic>> _docsByReceiverEmailCamel = {};
  final Map<String, Map<String, dynamic>> _requestsMap = {};

  /// Request IDs whose guardian link is being ended ([stopProtecting] in flight).
  final Set<String> _endingRequestIds = {};
  final StreamController<List<Map<String, dynamic>>> _broadcastRequestsController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  /// Reactive notifier for real-time UI binding
  final ValueNotifier<List<Map<String, dynamic>>> incomingRequestsNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  /// Synchronously accessible list of current pending incoming requests
  List<Map<String, dynamic>> get currentPendingRequests =>
      List.unmodifiable(incomingRequestsNotifier.value);

  /// People who added the current user as their guardian (accepted incoming requests).
  /// Read-only: the current user receives their alerts but they are NOT the current
  /// user's guardians.
  final ValueNotifier<List<ProtectedPerson>> protectedPeopleNotifier =
      ValueNotifier<List<ProtectedPerson>>(const []);

  /// Incoming request states kept in memory: pending ones feed the request cards,
  /// accepted ones feed "People I Protect".
  static bool _isTrackedStatus(Object? status) => status == 'pending' || status == 'accepted';

  /// Ensures active listener to Firebase Auth state, real-time requests, and auto-sync heartbeat.
  void initialize() {
    _initAuthAndRequestsListener();
    _startHeartbeatTimer();
    final uid = _currentUid;
    final email = _currentEmail;
    if (uid != null || email != null) {
      _startRequestsListeners(uid ?? '', email ?? '');
      refreshIncomingRequests();
    }
    if (uid != null) {
      unawaited(GuardianLinkMigrationService.instance.runOnceForUser(uid, email ?? ''));
    }
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    // Periodic auto-sync guarantees real-time UI updates without requiring manual reload
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final user = _auth.currentUser;
      if (user != null) {
        refreshIncomingRequests();
        ContactService.instance.getContacts(forceRefresh: true);
      }
    });
  }

  void _initAuthAndRequestsListener() {
    if (!_isFirebaseReady) return;
    try {
      _authSubscription?.cancel();
      _authSubscription = _auth.authStateChanges().listen((user) {
        if (user != null) {
          final uid = user.uid;
          final email = (user.email ?? '').toLowerCase().trim();
          _startRequestsListeners(uid, email);
          _startHeartbeatTimer();
          refreshIncomingRequests();
          unawaited(GuardianLinkMigrationService.instance.runOnceForUser(uid, email));
        } else {
          _cancelRequestsSubscriptions();
          _clearAllRequests();
        }
      }, onError: (e) {
        debugPrint('[ContactSync] Auth state listener notice: $e');
      });
    } catch (e) {
      debugPrint('[ContactSync] Auth listener init notice: $e');
    }
  }

  void _cancelRequestsSubscriptions() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subSentRequests?.cancel();
    _subSentRequests = null;
    _subUid?.cancel();
    _subUidSnake?.cancel();
    _subEmail?.cancel();
    _subEmailCamel?.cancel();
    _subUid = null;
    _subUidSnake = null;
    _subEmail = null;
    _subEmailCamel = null;
  }

  void _clearAllRequests() {
    _docsByReceiverId.clear();
    _docsByReceiverUid.clear();
    _docsByReceiverEmail.clear();
    _docsByReceiverEmailCamel.clear();
    _requestsMap.clear();
    _endingRequestIds.clear();
    _notifyIncomingRequests();
  }

  /// Cancels all active Firestore subscriptions and clears in-memory pending request state.
  void purgeOnSignOut() {
    _cancelRequestsSubscriptions();
    _clearAllRequests();
  }

  void _startRequestsListeners(String uid, String email) {
    _cancelRequestsSubscriptions();
    final normalizedEmail = email.toLowerCase().trim();

    if (uid.isNotEmpty) {
      _subUid = _firestore
          .collection('connection_requests')
          .where('receiverId', isEqualTo: uid)
          .snapshots()
          .listen(
            (snap) {
              _docsByReceiverId.clear();
              for (final doc in snap.docs) {
                final data = doc.data();
                if (_isTrackedStatus(data['status'])) {
                  _docsByReceiverId[doc.id] = {'docId': doc.id, ...data};
                }
              }
              _updateMergedRequests();
            },
            onError: (e) {
              debugPrint('[ContactSync] receiverId listener error: $e');
              _subUid = null;
            },
          );

      _subUidSnake = _firestore
          .collection('connection_requests')
          .where('receiver_uid', isEqualTo: uid)
          .snapshots()
          .listen(
            (snap) {
              _docsByReceiverUid.clear();
              for (final doc in snap.docs) {
                final data = doc.data();
                if (_isTrackedStatus(data['status'])) {
                  _docsByReceiverUid[doc.id] = {'docId': doc.id, ...data};
                }
              }
              _updateMergedRequests();
            },
            onError: (e) {
              debugPrint('[ContactSync] receiver_uid listener error: $e');
              _subUidSnake = null;
            },
          );

      // Real-time listener for requests SENT by the current user:
      // When the recipient accepts or declines, this updates the contact list instantly without reload!
      _subSentRequests = _firestore
          .collection('connection_requests')
          .where('senderId', isEqualTo: uid)
          .snapshots()
          .listen(
            (snap) {
              bool needsRefresh = false;
              for (final doc in snap.docs) {
                final status = doc.data()['status'];
                if (status == 'accepted' || status == 'rejected' || status == 'cancelled') {
                  needsRefresh = true;
                }
              }
              if (needsRefresh) {
                ContactService.instance.getContacts(forceRefresh: true);
              }
            },
            onError: (e) {
              debugPrint('[ContactSync] senderId listener notice: $e');
              _subSentRequests = null;
            },
          );
    }

    if (normalizedEmail.isNotEmpty) {
      _subEmail = _firestore
          .collection('connection_requests')
          .where('receiver_email', isEqualTo: normalizedEmail)
          .snapshots()
          .listen(
            (snap) {
              _docsByReceiverEmail.clear();
              for (final doc in snap.docs) {
                final data = doc.data();
                if (_isTrackedStatus(data['status'])) {
                  _docsByReceiverEmail[doc.id] = {'docId': doc.id, ...data};
                }
              }
              _updateMergedRequests();
            },
            onError: (e) {
              debugPrint('[ContactSync] receiver_email listener notice: $e');
              _subEmail = null;
            },
          );

      _subEmailCamel = _firestore
          .collection('connection_requests')
          .where('receiverEmail', isEqualTo: normalizedEmail)
          .snapshots()
          .listen(
            (snap) {
              _docsByReceiverEmailCamel.clear();
              for (final doc in snap.docs) {
                final data = doc.data();
                if (_isTrackedStatus(data['status'])) {
                  _docsByReceiverEmailCamel[doc.id] = {'docId': doc.id, ...data};
                }
              }
              _updateMergedRequests();
            },
            onError: (e) {
              debugPrint('[ContactSync] receiverEmail listener notice: $e');
              _subEmailCamel = null;
            },
          );
    }
  }

  void _updateMergedRequests() {
    final Map<String, Map<String, dynamic>> merged = {};
    for (final map in [
      _docsByReceiverId,
      _docsByReceiverUid,
      _docsByReceiverEmail,
      _docsByReceiverEmailCamel,
    ]) {
      merged.addAll(map);
    }

    // Links being ended right now stay hidden even if a refresh still reads them as accepted
    merged.removeWhere((id, _) => _endingRequestIds.contains(id));

    _requestsMap
      ..clear()
      ..addAll(merged);
    _notifyIncomingRequests();
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
    _notifyProtectedPeople();
  }

  void _notifyProtectedPeople() {
    final records = _requestsMap.entries
        .map((e) => GuardianRequestRecord.fromMap(e.key, e.value))
        .toList();
    final people = derivePeopleIProtect(
      records,
      myUid: _currentUid ?? '',
      myEmail: _currentEmail ?? '',
    );
    if (!listEquals(people, protectedPeopleNotifier.value)) {
      protectedPeopleNotifier.value = List.unmodifiable(people);
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
          .timeout(const Duration(seconds: 10));

      if (query.docs.isEmpty) {
        // Fallback check with trimmed original casing
        query = await _firestore
            .collection('users')
            .where('email', isEqualTo: rawEmail.trim())
            .limit(1)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 8));
      }

      if (query.docs.isEmpty) {
        // Fallback check with user_email field
        query = await _firestore
            .collection('users')
            .where('user_email', isEqualTo: normalized)
            .limit(1)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 8));
      }

      if (query.docs.isEmpty) {
        // Fallback check with email_lowercase field
        query = await _firestore
            .collection('users')
            .where('email_lowercase', isEqualTo: normalized)
            .limit(1)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 8));
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
  /// [isPrimary] makes the new contact the user's only Primary contact.
  Future<void> sendConnectionRequest({
    String? receiverUid,
    required String receiverEmail,
    required String receiverName,
    required String relationship,
    String? optionalPhone,
    bool isBackup = false,
    bool isPrimary = false,
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
          .timeout(const Duration(seconds: 6));
      if (existingReq.exists && existingReq.data()?['status'] == 'pending') {
        throw Exception('A connection request is already pending for this user.');
      }
    } catch (e) {
      if (e.toString().contains('already pending')) rethrow;
      debugPrint('[ContactSync] Existing request check notice: $e');
    }

    // 3. Write new pending connection request to Firestore (with 15s timeout and offline queuing)
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
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 15));
      debugPrint('[ContactSync] ✅ Connection request uploaded to Firestore: $requestId');
    } catch (e) {
      debugPrint('[ContactSync] ⚠️ Firestore connection request queued in offline cache: $e');
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
      isPrimary: isPrimary,
      isBackup: isBackup,
    );

    try {
      await _firestore
          .collection('users')
          .doc(senderId)
          .collection('contacts')
          .doc(contactId)
          .set(contactModel.toMap(), SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[ContactSync] Firestore contact write queued in offline cache: $e');
    }

    // 5. Always persist locally in SharedPreferences for offline SMS fallback
    await ContactService.instance.addContact(contactModel);
    if (isPrimary) {
      // Unsets the previous Primary contact, if any (only one primary at a time)
      await ContactService.instance.setPrimaryContact(contactId);
    }
    unawaited(ContactService.instance.getContacts(forceRefresh: true));
    unawaited(refreshIncomingRequests());

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
    bool isPrimary = false,
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
      isPrimary: isPrimary,
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
    if (isPrimary) {
      await ContactService.instance.setPrimaryContact(contactId);
    }
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

      Future<QuerySnapshot<Map<String, dynamic>>?> safeGet(Query<Map<String, dynamic>> q) async {
        try {
          return await q
              .get(const GetOptions(source: Source.serverAndCache))
              .timeout(const Duration(seconds: 8));
        } catch (e) {
          debugPrint('[ContactSync] Safe get notice: $e');
          return null;
        }
      }

      final futures = <Future<void>>[];

      if (uid != null && uid.isNotEmpty) {
        futures.add(safeGet(_firestore.collection('connection_requests').where('receiverId', isEqualTo: uid)).then((snap) {
          if (snap != null) {
            _docsByReceiverId.clear();
            for (final doc in snap.docs) {
              if (_isTrackedStatus(doc.data()['status'])) {
                _docsByReceiverId[doc.id] = {'docId': doc.id, ...doc.data()};
              }
            }
          }
        }));
        futures.add(safeGet(_firestore.collection('connection_requests').where('receiver_uid', isEqualTo: uid)).then((snap) {
          if (snap != null) {
            _docsByReceiverUid.clear();
            for (final doc in snap.docs) {
              if (_isTrackedStatus(doc.data()['status'])) {
                _docsByReceiverUid[doc.id] = {'docId': doc.id, ...doc.data()};
              }
            }
          }
        }));
      }

      if (normalizedEmail.isNotEmpty) {
        futures.add(safeGet(_firestore.collection('connection_requests').where('receiver_email', isEqualTo: normalizedEmail)).then((snap) {
          if (snap != null) {
            _docsByReceiverEmail.clear();
            for (final doc in snap.docs) {
              if (_isTrackedStatus(doc.data()['status'])) {
                _docsByReceiverEmail[doc.id] = {'docId': doc.id, ...doc.data()};
              }
            }
          }
        }));
        futures.add(safeGet(_firestore.collection('connection_requests').where('receiverEmail', isEqualTo: normalizedEmail)).then((snap) {
          if (snap != null) {
            _docsByReceiverEmailCamel.clear();
            for (final doc in snap.docs) {
              if (_isTrackedStatus(doc.data()['status'])) {
                _docsByReceiverEmailCamel[doc.id] = {'docId': doc.id, ...doc.data()};
              }
            }
          }
        }));
      }

      await Future.wait(futures);
      _updateMergedRequests();
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
  /// One-way link: the current user (receiver B) becomes the guardian of the sender A.
  /// Exactly one direction is written: B is added to A's `users/A/contacts`. Nothing is
  /// added to B's own guardian list; A appears in B's "People I Protect"
  /// ([protectedPeopleNotifier]), derived from this accepted request.
  Future<void> acceptRequest(String requestId) async {
    // 0. Optimistic UI: the card leaves "pending" and the sender shows in "People I Protect"
    final optimistic = _requestsMap[requestId];
    if (optimistic != null) {
      _requestsMap[requestId] = {...optimistic, 'status': 'accepted'};
    }
    _notifyIncomingRequests();

    final reqDoc = await _firestore.collection('connection_requests').doc(requestId).get();
    if (!reqDoc.exists) return;

    final data = reqDoc.data()!;
    final senderId = (data['sender_uid'] ?? data['senderId']) as String;
    final String receiverId = ((data['receiver_uid'] ?? data['receiverId'])?.toString().isNotEmpty == true)
        ? (data['receiver_uid'] ?? data['receiverId']) as String
        : (_currentUid ?? '');
    if (receiverId.isEmpty) return;

    final relationship = (data['relationship'] as String?) ?? 'Guardian';

    final currentUserName = AuthService.instance.displayName;
    final currentUserEmail = _currentEmail ?? '';
    var currentUserPhone = AuthService.instance.currentProfile.phone;

    // Fallback: resolve the current user's phone from their Firestore profile if not loaded
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

    // 2. Write the single direction of the link: guardian B into protected user A's list
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
        // No primary flag: only the owner chooses their Primary contact (merge keeps it)
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

      // No reverse write: the sender is NOT added to the current user's guardian list.

      await batch.commit();
      debugPrint('[ContactSync] 🛡️ $receiverId is now a guardian of $senderId (one-way)');
    } catch (e) {
      debugPrint('[ContactSync] Guardian link write notice: $e');
    }

    unawaited(refreshIncomingRequests());
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
    unawaited(ContactService.instance.getContacts(forceRefresh: true));
    unawaited(refreshIncomingRequests());
  }

  // ── People I Protect: reverse invite and ending a link ──────────────────────

  /// One-tap invite: asks [person], whom the current user already protects, to become the
  /// current user's guardian too.
  ///
  /// Uses the normal consent flow: [person] receives a request and only gets the current
  /// user's SOS alerts after accepting. Until then the contact shows as "Sync Pending".
  /// Throws an [Exception] with a user-facing message when the request cannot be sent.
  Future<void> addProtectedPersonAsContact(
    ProtectedPerson person, {
    required String relationship,
  }) async {
    if (person.uid.isEmpty && person.email.trim().isEmpty) {
      throw Exception('This account has no email or ID to send a request to.');
    }
    await sendConnectionRequest(
      receiverUid: person.uid.isNotEmpty ? person.uid : null,
      receiverEmail: person.email,
      receiverName: person.name,
      relationship: relationship,
    );
  }

  /// Ends the current user's role as guardian of [person] ("Stop protecting").
  ///
  /// 1. Removes the current user from [person]'s guardian list (`users/{person}/contacts/{me}`)
  ///    so [person]'s SOS alerts no longer go to the current user.
  /// 2. Marks every active request from [person] to the current user as rejected, which drops
  ///    them from "People I Protect".
  ///
  /// Does NOT touch the current user's own contact list: if [person] is also the current
  /// user's emergency contact, they stay one.
  /// Returns false (and restores the list) when the server refuses the change.
  Future<bool> stopProtecting(ProtectedPerson person) async {
    final myUid = _currentUid;
    if (myUid == null || myUid.isEmpty || person.uid.isEmpty) return false;
    final myEmail = _currentEmail ?? '';

    final requestIds = {
      ...activeRequestIdsFrom(
        person.uid,
        _requestsMap.entries.map((e) => GuardianRequestRecord.fromMap(e.key, e.value)),
        myUid: myUid,
        myEmail: myEmail,
      ),
      if (person.requestId.isNotEmpty) person.requestId,
    };

    // 0. Optimistic UI: drop the person from "People I Protect" right away
    _endingRequestIds.addAll(requestIds);
    final removedEntries = <String, Map<String, dynamic>>{};
    for (final id in requestIds) {
      final entry = _requestsMap.remove(id);
      if (entry != null) removedEntries[id] = entry;
    }
    _notifyIncomingRequests();

    const opTimeout = Duration(seconds: 8);
    try {
      // 1. Leave their guardian list (and any email placeholder they kept for the current user)
      final theirContacts = _firestore.collection('users').doc(person.uid).collection('contacts');
      final batch = _firestore.batch()..delete(theirContacts.doc(myUid));
      if (myEmail.isNotEmpty) {
        batch.delete(theirContacts.doc('pending_${guardianEmailKey(myEmail)}'));
      }
      try {
        await batch.commit().timeout(opTimeout);
      } on TimeoutException {
        debugPrint('[ContactSync] Leaving ${person.uid}\'s guardian list queued offline');
      }
    } catch (e) {
      debugPrint('[ContactSync] ❌ Could not stop protecting ${person.uid}: $e');
      _endingRequestIds.removeAll(requestIds);
      _requestsMap.addAll(removedEntries);
      _notifyIncomingRequests();
      unawaited(refreshIncomingRequests());
      return false;
    }

    // 2. End the request(s) so the link no longer shows on either side
    for (final id in requestIds) {
      final ref = _firestore.collection('connection_requests').doc(id);
      try {
        await ref.update({
          'status': 'rejected',
          'endedByGuardian': true,
          'respondedAt': FieldValue.serverTimestamp(),
        }).timeout(opTimeout);
      } on TimeoutException {
        debugPrint('[ContactSync] Ending request $id queued offline');
      } catch (e) {
        debugPrint('[ContactSync] Could not mark request $id as ended, deleting it: $e');
        try {
          await ref.delete().timeout(opTimeout);
        } catch (_) {}
      }
    }

    debugPrint('[ContactSync] 🛡️ Stopped protecting ${person.uid}');
    // The local cache now holds the ended requests, so a refresh can no longer bring them back
    _endingRequestIds.removeAll(requestIds);
    unawaited(refreshIncomingRequests());
    return true;
  }

  /// Permanently removes a guardian/contact from the user's own Firestore list, this
  /// direction's connection requests, and local device storage. The other user's own
  /// guardian list is not changed (one-way links).
  ///
  /// Returns false when the contact could not be removed from the user's own list.
  Future<bool> deleteSyncedContact(
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

    // 1. Remove from the user's own list first (memory, disk cache and every matching cloud doc).
    // This is the single source the UI and the SOS dispatch read from, so once it succeeds the
    // contact can no longer reappear or receive alerts.
    final removed = await ContactService.instance.deleteContact(
      contactId,
      contactUid: resolvedUid,
      email: normalizedEmail,
      phone: resolvedPhone,
      extraDocIds: [
        if (resolvedUid != null && resolvedUid.isNotEmpty) resolvedUid,
        if (safeEmailKey.isNotEmpty) 'pending_$safeEmailKey',
      ],
    );
    if (!removed) {
      debugPrint('[ContactSync] ❌ Could not delete contact $contactId from own list');
      return false;
    }

    // 2. Best-effort cleanup of the partner's list and connection requests. These may be denied by
    // security rules or be offline; neither affects the user's own (already updated) list.
    if (uid != null) {
      unawaited(_cleanUpAfterDelete(
        uid: uid,
        resolvedUid: resolvedUid,
        normalizedEmail: normalizedEmail,
        safeEmailKey: safeEmailKey,
      ));
    }
    unawaited(refreshIncomingRequests());

    debugPrint('[ContactSync] 🗑️ Permanently deleted contact: $contactId / $resolvedUid / $normalizedEmail');
    return true;
  }

  Future<void> _cleanUpAfterDelete({
    required String uid,
    required String? resolvedUid,
    required String normalizedEmail,
    required String safeEmailKey,
  }) async {
    const opTimeout = Duration(seconds: 5);

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
          await doc.reference.delete().timeout(opTimeout);
        }
      } catch (e) {
        debugPrint('[ContactSync] Error cleaning up contacts by email: $e');
      }
    }

    // One-way links: removing a guardian ends only the "they guard me" direction. The partner's
    // own guardian list is theirs alone, EXCEPT for the reverse entry that older app versions
    // wrongly wrote there on accept. That entry is removed only when the server proves the
    // partner never asked the current user to be their guardian.
    if (resolvedUid != null && resolvedUid.isNotEmpty) {
      final partnerChoseMe = await _hasActiveRequestFrom(resolvedUid, uid);
      if (partnerChoseMe == false) {
        try {
          await _firestore
              .collection('users')
              .doc(resolvedUid)
              .collection('contacts')
              .doc(uid)
              .delete()
              .timeout(opTimeout);
        } catch (e) {
          debugPrint('[ContactSync] Notice removing legacy reverse entry ($resolvedUid): $e');
        }
      }
    }

    // Delete only this direction's request records (me -> partner). The partner's own requests
    // to me describe the other direction and stay untouched.
    final List<String> requestIdsToDelete = {
      if (resolvedUid != null && resolvedUid.isNotEmpty) '${uid}_$resolvedUid',
      if (safeEmailKey.isNotEmpty) '${uid}_$safeEmailKey',
    }.toList();

    for (final reqId in requestIdsToDelete) {
      try {
        await _firestore.collection('connection_requests').doc(reqId).delete().timeout(opTimeout);
      } catch (e) {
        // If delete rule prevented deletion, cancel it
        try {
          await _firestore.collection('connection_requests').doc(reqId).update({
            'status': 'cancelled',
            'respondedAt': FieldValue.serverTimestamp(),
          }).timeout(opTimeout);
        } catch (_) {}
      }
    }
  }

  /// Whether [partnerUid] has a pending or accepted request asking [myUid] to be their guardian,
  /// read from the server. Returns null when this cannot be determined (offline, denied).
  Future<bool?> _hasActiveRequestFrom(String partnerUid, String myUid) async {
    final myEmail = _currentEmail ?? '';
    final queries = <Query<Map<String, dynamic>>>[
      _firestore
          .collection('connection_requests')
          .where('senderId', isEqualTo: partnerUid)
          .where('receiverId', isEqualTo: myUid),
      if (myEmail.isNotEmpty)
        _firestore
            .collection('connection_requests')
            .where('senderId', isEqualTo: partnerUid)
            .where('receiver_email', isEqualTo: myEmail),
    ];
    try {
      for (final query in queries) {
        final snap = await query
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 5));
        final active = snap.docs.any((d) {
          final status = d.data()['status'];
          return status == 'pending' || status == 'accepted';
        });
        if (active) return true;
      }
      return false;
    } catch (e) {
      debugPrint('[ContactSync] Could not check requests from $partnerUid: $e');
      return null;
    }
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
      isPrimary: offlineContact.isPrimary,
    );

    // If the old contact used an offline_ timestamp ID, remove the old offline record
    if (offlineContact.id.startsWith('offline_')) {
      await ContactService.instance.deleteContact(offlineContact.id);
    }

    return true;
  }
}
