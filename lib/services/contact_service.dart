import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/contact_model.dart';
import 'activity_service.dart';

/// Service managing emergency contacts purely in cloud storage (Firestore)
/// with real-time in-memory state and secure per-user local disk caching.
///
/// **Per-User Disk Cache**: Contact lists are locally cached in [SharedPreferences]
/// strictly keyed by user UID (`contacts_cache_<uid>`) to ensure zero-latency offline
/// availability during life-threatening emergencies. The cache is updated on cloud sync
/// and completely wiped when the user signs out.
class ContactService extends ChangeNotifier {
  ContactService._internal();

  /// Central singleton instance
  static final ContactService instance = ContactService._internal();

  /// Legacy storage key used only for purging legacy unencrypted data on upgrade/signout
  static const String _legacyStorageKey = 'emergency_contacts_list';

  /// Storage key prefix for per-user local contact disk cache
  static const String _diskCachePrefix = 'contacts_cache_';

  /// Generates the SharedPreferences key for a specific user's contact cache
  static String cacheKeyForUid(String uid) => '$_diskCachePrefix$uid';

  /// Initial sample contacts for offline unit test harness only (never persisted to disk)
  static final List<ContactModel> _defaultContacts = [
    const ContactModel(
      id: 'default_1',
      name: 'Mom',
      email: 'mom@family.local',
      phone: '+8801711000001',
      relationship: 'Family',
      isPrimary: true,
      syncStatus: 'offline_only',
    ),
    const ContactModel(
      id: 'default_2',
      name: 'Dad',
      email: 'dad@family.local',
      phone: '+8801933000003',
      relationship: 'Family',
      isPrimary: true,
      syncStatus: 'offline_only',
    ),
    const ContactModel(
      id: 'default_3',
      name: 'Riya Sharma',
      email: 'riya.sharma@example.com',
      phone: '+8801822000002',
      relationship: 'Best Friend',
      isPrimary: false,
      syncStatus: 'offline_only',
    ),
  ];

  /// Active in-memory cache for zero-latency synchronous reads
  List<ContactModel> _cachedContacts = [];
  bool _isInitialized = false;
  String? _currentBoundUid;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _firestoreSubscription;

  /// Incremented on every local add/update/delete. A cloud fetch that started before a local
  /// mutation carries stale data and must not overwrite the cache (it used to resurrect deleted contacts).
  int _mutationVersion = 0;

  /// Doc IDs deleted locally whose removal the server has not confirmed yet, with deletion time.
  /// Every read path filters them out so stale snapshots, caches or fetches cannot bring them back.
  final Map<String, DateTime> _deletedDocIds = {};

  /// After this long, a server snapshot that still contains the doc wins (the delete was rejected).
  static const Duration _tombstoneLifetime = Duration(minutes: 10);

  List<ContactModel> _withoutDeleted(List<ContactModel> contacts) {
    if (_deletedDocIds.isEmpty) return contacts;
    return contacts.where((c) => !_deletedDocIds.containsKey(c.id)).toList();
  }

  /// Drops tombstones once a server-confirmed result shows the doc is gone (or expired).
  void _settleTombstones(Iterable<String> serverDocIds) {
    if (_deletedDocIds.isEmpty) return;
    final present = serverDocIds.toSet();
    final now = DateTime.now();
    _deletedDocIds.removeWhere((id, deletedAt) =>
        !present.contains(id) || now.difference(deletedAt) > _tombstoneLifetime);
  }

  /// Reactive notifier for real-time UI binding (e.g. ValueListenableBuilder)
  final ValueNotifier<List<ContactModel>> contactsNotifier =
      ValueNotifier<List<ContactModel>>([]);

  /// Synchronous getter of current in-memory contacts
  List<ContactModel> get contacts => List.unmodifiable(_cachedContacts);

  /// Synchronous getter for total contacts count
  int get contactsCount => _cachedContacts.length;

  /// Resets in-memory cache and initialization state (useful for unit testing).
  void resetMemoryCache() {
    _deletedDocIds.clear();
    _cachedContacts = [];
    _isInitialized = false;
    _currentBoundUid = null;
    _emitChange();
  }

  /// Saves current in-memory contacts to SharedPreferences under `contacts_cache_<uid>`
  Future<void> saveToDiskCache(String? uid) async {
    if (uid == null || uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(_cachedContacts.map((c) => c.toMap()).toList());
      await prefs.setString(cacheKeyForUid(uid), jsonString);
      debugPrint('[ContactService] 💾 Saved ${_cachedContacts.length} contacts to disk cache for $uid');
    } catch (e) {
      debugPrint('[ContactService] Error saving contacts disk cache: $e');
    }
  }

  /// Loads cached contacts from SharedPreferences for [uid]
  Future<List<ContactModel>> loadFromDiskCache(String? uid) async {
    if (uid == null || uid.isEmpty) return [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKeyForUid(uid));
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is List) {
          final list = _withoutDeleted(decoded
              .whereType<Map>()
              .map((item) => ContactModel.fromMap(Map<String, dynamic>.from(item)))
              .toList());
          debugPrint('[ContactService] 📂 Loaded ${list.length} contacts from disk cache for $uid');
          return list;
        }
      }
    } catch (e) {
      debugPrint('[ContactService] Error loading contacts disk cache: $e');
    }
    return [];
  }

  /// Dynamically binds the contact service to the authenticated user's Firestore subcollection:
  /// `users/{uid}/contacts`.
  void bindUser(String? uid) {
    if (uid == _currentBoundUid && _isInitialized && _firestoreSubscription != null) return;

    _firestoreSubscription?.cancel();
    _firestoreSubscription = null;
    _cachedContacts = [];
    _currentBoundUid = uid;
    _isInitialized = false;
    _emitChange();

    if (uid == null || uid.isEmpty) return;

    // Immediately load from disk cache so contacts are accessible offline
    loadFromDiskCache(uid).then((cached) {
      if (_currentBoundUid == uid && cached.isNotEmpty && (_cachedContacts.isEmpty || !_isInitialized)) {
        _cachedContacts = cached;
        _isInitialized = true;
        _emitChange();
      }
    });

    if (Firebase.apps.isNotEmpty) {
      _firestoreSubscription = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('contacts')
          .snapshots()
          .listen((snapshot) {
        if (!snapshot.metadata.isFromCache) {
          _settleTombstones(snapshot.docs.map((d) => d.id));
        }
        _cachedContacts = _withoutDeleted(snapshot.docs.map((doc) {
          final data = doc.data();
          return ContactModel.fromMap({
            ...data,
            'id': doc.id,
            'contactUid': data['contactUid'] ?? data['contact_uid'] ?? doc.id,
          });
        }).toList());
        _isInitialized = true;
        _emitChange();
        saveToDiskCache(uid);
      }, onError: (e) {
        debugPrint('[ContactService] Firestore contacts stream notice: $e');
        _firestoreSubscription = null;
        Timer(const Duration(seconds: 4), () {
          if (_currentBoundUid == uid && _firestoreSubscription == null) {
            bindUser(uid);
          }
        });
      });
    }
  }

  /// Updates in-memory contacts directly from a remote snapshot or sync stream
  void syncFromCloud(List<ContactModel> synced) {
    _cachedContacts = _withoutDeleted(List<ContactModel>.from(synced));
    _isInitialized = true;
    _emitChange();
    final uid = _currentBoundUid ?? (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null);
    if (uid != null) {
      saveToDiskCache(uid);
    }
  }

  /// Retrieves all contacts dynamically from Cloud Firestore or active in-memory cache,
  /// falling back to local per-user disk cache when offline.
  Future<List<ContactModel>> getContacts({bool forceRefresh = false}) async {
    if (_isInitialized && !forceRefresh && _cachedContacts.isNotEmpty) {
      return List<ContactModel>.from(_cachedContacts);
    }

    final user = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser : null;
    final uid = user?.uid ?? _currentBoundUid;

    // On app start or offline, load the disk cache FIRST so getContacts returns immediately
    if (_cachedContacts.isEmpty && uid != null && uid.isNotEmpty) {
      final int diskVersionAtStart = _mutationVersion;
      final diskCached = await loadFromDiskCache(uid);
      if (diskCached.isNotEmpty && diskVersionAtStart == _mutationVersion) {
        _cachedContacts = diskCached;
        _isInitialized = true;
        _emitChange();
        if (!forceRefresh) {
          return List<ContactModel>.from(_cachedContacts);
        }
      }
    }

    if (Firebase.apps.isNotEmpty) {
      if (user != null) {
        if (_currentBoundUid != user.uid) {
          bindUser(user.uid);
        }
        final int versionAtStart = _mutationVersion;
        try {
          final snapshot = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('contacts')
              .get(const GetOptions(source: Source.serverAndCache))
              .timeout(const Duration(seconds: 4));

          final List<ContactModel> mapped = [];
          for (final doc in snapshot.docs) {
            if (_deletedDocIds.containsKey(doc.id)) continue;
            final data = doc.data();
            var c = ContactModel.fromMap({
              ...data,
              'id': doc.id,
              'contactUid': data['contactUid'] ?? data['contact_uid'] ?? doc.id,
            });

            // If phone is missing and this is a registered user, attempt auto-resolution from their user profile
            final resolvedUid = c.contactUid;
            if (c.phone.trim().isEmpty &&
                resolvedUid != null &&
                resolvedUid.isNotEmpty &&
                !resolvedUid.startsWith('offline_')) {
              try {
                final userDoc = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(resolvedUid)
                  .get(const GetOptions(source: Source.serverAndCache))
                  .timeout(const Duration(seconds: 1));
                if (userDoc.exists && userDoc.data() != null) {
                  final uData = userDoc.data()!;
                  final resolvedPhone = (uData['phoneNumber'] ?? uData['phone'] ?? '').toString().trim();
                  if (resolvedPhone.isNotEmpty) {
                    c = c.copyWith(phone: resolvedPhone);
                    // Silently sync resolved phone back to contact doc in background.
                    // update() (not set+merge) fails on a missing doc, so a back-fill racing a
                    // delete can never re-create the deleted contact.
                    unawaited(FirebaseFirestore.instance
                        .collection('users')
                        .doc(user.uid)
                        .collection('contacts')
                        .doc(doc.id)
                        .update({
                      'phone': resolvedPhone,
                      'contact_optional_phone': resolvedPhone,
                    }).catchError((_) {}));
                  }
                }
              } catch (_) {}
            }

            mapped.add(c);
          }

          if (versionAtStart != _mutationVersion) {
            debugPrint('[ContactService] Discarding stale cloud fetch (contacts changed while loading)');
            return List<ContactModel>.from(_cachedContacts);
          }
          if (!snapshot.metadata.isFromCache) {
            _settleTombstones(snapshot.docs.map((d) => d.id));
          }
          _cachedContacts = _withoutDeleted(mapped);
          _isInitialized = true;
          _emitChange();
          unawaited(saveToDiskCache(user.uid));
          return List<ContactModel>.from(_cachedContacts);
        } catch (e) {
          debugPrint('[ContactService] Cloud fetch notice: $e');
          return List<ContactModel>.from(_cachedContacts);
        }
      } else {
        // Unauthenticated guest: return current in-memory contacts without writing to disk
        _isInitialized = true;
        _emitChange();
        return List<ContactModel>.from(_cachedContacts);
      }
    }

    // Offline / unit test fallback (when Firebase is not initialized)
    if (!_isInitialized) {
      _cachedContacts = List<ContactModel>.from(_defaultContacts);
      _isInitialized = true;
      _emitChange();
    }
    return List<ContactModel>.from(_cachedContacts);
  }

  /// Adds or updates a contact in Cloud Firestore and instantly notifies all reactive listeners.
  /// Also updates local per-user disk cache for offline accessibility.
  Future<bool> addContact(ContactModel contact) async {
    try {
      final List<ContactModel> current = await getContacts();

      // Avoid duplicates with the same phone number, email, or ID
      final normalizedEmail = contact.email.toLowerCase().trim();
      final cleanPhone = contact.phone.replaceAll(RegExp(r'\s+|-|\(|\)'), '');

      final existingIndex = current.indexWhere((c) {
        if (c.id == contact.id) return true;
        if (contact.contactUid != null &&
            contact.contactUid!.isNotEmpty &&
            c.contactUid == contact.contactUid) {
          return true;
        }
        if (normalizedEmail.isNotEmpty &&
            c.email.toLowerCase().trim() == normalizedEmail) {
          return true;
        }
        if (cleanPhone.isNotEmpty) {
          final cPhone = c.phone.replaceAll(RegExp(r'\s+|-|\(|\)'), '');
          if (cPhone.isNotEmpty &&
              (cPhone == cleanPhone ||
                  cPhone.endsWith(cleanPhone) ||
                  cleanPhone.endsWith(cPhone))) {
            return true;
          }
        }
        return false;
      });

      final contactToSave = contact.email == normalizedEmail
          ? contact
          : contact.copyWith(email: normalizedEmail);

      if (existingIndex >= 0) {
        current[existingIndex] = contactToSave;
      } else {
        current.add(contactToSave);
      }

      // Re-adding a previously deleted contact must make it visible again
      _deletedDocIds.remove(contactToSave.id);
      _mutationVersion++;
      _cachedContacts = current;
      _isInitialized = true;
      _emitChange();
      final uid = _currentBoundUid ?? (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null);
      if (uid != null) {
        unawaited(saveToDiskCache(uid));
      }

      // Dynamically persist to Cloud Firestore scoped strictly to current user's UID
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('contacts')
              .doc(contactToSave.id)
              .set(contactToSave.toMap(), SetOptions(merge: true))
              .timeout(const Duration(seconds: 4));
        }
      }

      debugPrint('[ContactService] Contact added/updated in memory/cloud: ${contact.name}');
      ActivityService.instance.logContactEvent(
        action: existingIndex >= 0 ? 'Updated' : 'Added',
        contactName: contact.name,
      );
      return true;
    } catch (e) {
      debugPrint('[ContactService] Error adding contact: $e');
      return false;
    }
  }

  /// Deletes a contact matching [id], [contactUid], [email], or [phone].
  ///
  /// Instantly removes from in-memory cache, notifies UI listeners, updates disk cache, and deletes
  /// every matching document from Firestore (plus [extraDocIds], e.g. pending placeholders).
  /// Returns false, and restores the contact, when Firestore rejects the delete.
  /// A delete that is still queued offline counts as success: Firestore applies it on reconnect
  /// and already hides the document locally.
  Future<bool> deleteContact(
    String id, {
    String? contactUid,
    String? email,
    String? phone,
    Iterable<String> extraDocIds = const [],
  }) async {
    List<ContactModel>? snapshotBeforeDelete;
    Set<String> docIdsToDelete = {};
    try {
      final List<ContactModel> current = await getContacts();
      snapshotBeforeDelete = List<ContactModel>.from(current);
      final int beforeCount = current.length;
      final normalizedEmail = email?.toLowerCase().trim();
      final cleanPhone = phone?.replaceAll(RegExp(r'\s+|-|\(|\)'), '');

      bool matches(ContactModel c) {
        if (c.id == id) return true;
        if (contactUid != null && contactUid.isNotEmpty) {
          if (c.contactUid == contactUid || c.id == contactUid) return true;
        }
        if (normalizedEmail != null && normalizedEmail.isNotEmpty) {
          if (c.email.toLowerCase().trim() == normalizedEmail) return true;
        }
        if (cleanPhone != null && cleanPhone.isNotEmpty) {
          final cPhone = c.phone.replaceAll(RegExp(r'\s+|-|\(|\)'), '');
          if (cPhone.isNotEmpty &&
              (cPhone == cleanPhone ||
                  cPhone.endsWith(cleanPhone) ||
                  cleanPhone.endsWith(cPhone))) {
            return true;
          }
        }
        return false;
      }

      final matched = current.where(matches).toList();
      final removedName = matched.firstOrNull?.name ?? id;
      current.removeWhere(matches);

      // Every document the UI removes must also be removed in the cloud, otherwise a duplicate
      // (same email/phone under another doc ID) reappears on the next refresh.
      docIdsToDelete = {
        if (id.isNotEmpty) id,
        ...matched.map((c) => c.id),
        ...extraDocIds.where((d) => d.isNotEmpty),
      };
      final now = DateTime.now();
      for (final docId in docIdsToDelete) {
        _deletedDocIds[docId] = now;
      }
      _mutationVersion++;

      _cachedContacts = current;
      _isInitialized = true;
      _emitChange();
      final uid = _currentBoundUid ?? (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null);
      if (uid != null) {
        // Awaited so an app restart right after the delete cannot load the old list from disk
        await saveToDiskCache(uid);
      }

      // Cloud deletion scoped strictly to authenticated user UID
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          final contactsRef = FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('contacts');
          final batch = FirebaseFirestore.instance.batch();
          for (final docId in docIdsToDelete) {
            batch.delete(contactsRef.doc(docId));
          }
          try {
            await batch.commit().timeout(const Duration(seconds: 8));
          } on TimeoutException {
            debugPrint('[ContactService] Delete of $docIdsToDelete queued offline; will sync on reconnect');
          }
        }
      }

      if (current.length < beforeCount) {
        ActivityService.instance.logContactEvent(
          action: 'Deleted',
          contactName: removedName,
        );
      }
      debugPrint('[ContactService] Contact deleted: $docIdsToDelete');
      return true;
    } catch (e) {
      debugPrint('[ContactService] Error deleting contact: $e');
      // Roll back so the list reflects what is really stored in the cloud
      for (final docId in docIdsToDelete) {
        _deletedDocIds.remove(docId);
      }
      if (snapshotBeforeDelete != null) {
        _mutationVersion++;
        _cachedContacts = snapshotBeforeDelete;
        _emitChange();
        final uid = _currentBoundUid ?? (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null);
        if (uid != null) {
          unawaited(saveToDiskCache(uid));
        }
      }
      return false;
    }
  }

  /// Updates an existing contact by matching its [id].
  Future<bool> updateContact(ContactModel contact) async {
    try {
      final List<ContactModel> current = await getContacts();
      final index = current.indexWhere((c) => c.id == contact.id);
      if (index == -1) {
        debugPrint(
            '[ContactService] Contact with id ${contact.id} not found for update.');
        return false;
      }

      current[index] = contact;
      _mutationVersion++;
      _cachedContacts = current;
      _isInitialized = true;
      _emitChange();
      final uid = _currentBoundUid ?? (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null);
      if (uid != null) {
        unawaited(saveToDiskCache(uid));
      }

      // Cloud update in Firestore
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('contacts')
              .doc(contact.id)
              .set(contact.toMap(), SetOptions(merge: true))
              .timeout(const Duration(seconds: 4));
        }
      }

      debugPrint('[ContactService] Contact updated: ${contact.name}');
      ActivityService.instance.logContactEvent(
        action: 'Updated',
        contactName: contact.name,
      );
      return true;
    } catch (e) {
      debugPrint('[ContactService] Error updating contact: $e');
      return false;
    }
  }

  /// Extracts clean phone numbers for SOS SMS dispatch.
  /// Dispatches to all emergency contacts that have a non-empty, valid phone number,
  /// regardless of whether their sync status is Synced App User, Sync Pending, or offline.
  Future<List<String>> getEmergencyPhoneNumbers({bool primaryOnly = false}) async {
    final List<ContactModel> contacts = await getContacts();
    if (contacts.isEmpty) return [];

    List<ContactModel> targetContacts = contacts;
    if (primaryOnly) {
      final primaryContacts = contacts
          .where((c) => c.isPrimary && c.phone.trim().isNotEmpty)
          .toList();
      if (primaryContacts.isNotEmpty) {
        targetContacts = primaryContacts;
      }
    }

    return targetContacts
        .where((c) => c.phone.trim().isNotEmpty)
        .map((c) => c.phone.replaceAll(RegExp(r'\s+'), ''))
        .where((phone) => phone.isNotEmpty)
        .toSet()
        .toList();
  }

  /// Helper to notify both [contactsNotifier] and [ChangeNotifier] listeners
  void _emitChange() {
    contactsNotifier.value = List.unmodifiable(_cachedContacts);
    notifyListeners();
  }

  /// Resets contacts in memory back to initial default list (for test harness).
  Future<bool> resetToDefaults() async {
    _cachedContacts = List<ContactModel>.from(_defaultContacts);
    _emitChange();
    return true;
  }

  /// Clears all contacts from memory, disk cache, and Firestore (for testing or reset).
  Future<bool> clearContacts() async {
    final uid = _currentBoundUid ?? (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null);
    _cachedContacts = [];
    _isInitialized = true;
    _emitChange();
    if (uid != null && uid.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(cacheKeyForUid(uid));
      } catch (_) {}
    }
    if (Firebase.apps.isNotEmpty) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('contacts')
              .get();
          for (final doc in snap.docs) {
            await doc.reference.delete();
          }
        } catch (_) {}
      }
    }
    return true;
  }

  /// Completely cancels Firestore stream subscriptions and purges in-memory caches on logout.
  /// Also scrubs legacy and per-user local SharedPreferences keys to ensure zero leftover physical device data.
  Future<void> purgeOnSignOut() async {
    final oldUid = _currentBoundUid;
    _firestoreSubscription?.cancel();
    _firestoreSubscription = null;
    _deletedDocIds.clear();
    _mutationVersion++;
    _cachedContacts = [];
    _currentBoundUid = null;
    _isInitialized = false;
    _emitChange();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyStorageKey);
      if (oldUid != null && oldUid.isNotEmpty) {
        await prefs.remove(cacheKeyForUid(oldUid));
      }
      final allKeys = prefs.getKeys().where((k) => k.startsWith(_diskCachePrefix)).toList();
      for (final key in allKeys) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('[ContactService] Error purging disk cache: $e');
    }
  }
}
