import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/contact_model.dart';
import 'activity_service.dart';

/// Singleton Service to manage emergency contacts with persistence via [SharedPreferences]
/// and reactive updates via [ChangeNotifier] and [contactsNotifier].
///
/// Supports instant in-memory CRUD operations, reactive UI notifications, and
/// automatic default seeding for first-time app launches.
class ContactService extends ChangeNotifier {
  ContactService._internal();

  /// Central singleton instance
  static final ContactService instance = ContactService._internal();

  /// SharedPreferences key for storing serialized contacts list
  static const String _storageKey = 'emergency_contacts_list';

  /// Initial sample contacts with valid emails and Bangladesh phone numbers (+8801...)
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

  /// Reactive notifier for real-time UI binding (e.g. ValueListenableBuilder)
  final ValueNotifier<List<ContactModel>> contactsNotifier =
      ValueNotifier<List<ContactModel>>([]);

  /// Synchronous getter of current in-memory contacts
  List<ContactModel> get contacts => List.unmodifiable(_cachedContacts);

  /// Synchronous getter for total contacts count
  int get contactsCount => _cachedContacts.length;

  /// Resets in-memory cache and initialization state (useful for unit testing).
  void resetMemoryCache() {
    _cachedContacts = [];
    _isInitialized = false;
    _emitChange();
  }

  /// Retrieves all contacts from [SharedPreferences] or in-memory cache.
  ///
  /// If the storage is uninitialized or empty, it populates the initial default contacts.
  Future<List<ContactModel>> getContacts({bool forceRefresh = false}) async {
    if (_isInitialized && !forceRefresh) {
      return List<ContactModel>.from(_cachedContacts);
    }

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      if (!prefs.containsKey(_storageKey)) {
        debugPrint('[ContactService] Initializing default emergency contacts...');
        await _saveContactsList(prefs, _defaultContacts);
        _cachedContacts = List<ContactModel>.from(_defaultContacts);
        _isInitialized = true;
        _emitChange();
        return List<ContactModel>.from(_defaultContacts);
      }

      final List<String>? jsonList = prefs.getStringList(_storageKey);
      if (jsonList == null || jsonList.isEmpty) {
        _cachedContacts = [];
        _isInitialized = true;
        _emitChange();
        return [];
      }

      _cachedContacts = jsonList
          .map((item) {
            try {
              return ContactModel.fromJson(item);
            } catch (e) {
              debugPrint('[ContactService] Error decoding contact JSON: $e');
              return null;
            }
          })
          .whereType<ContactModel>()
          .toList();

      _isInitialized = true;
      _emitChange();
      return List<ContactModel>.from(_cachedContacts);
    } catch (e) {
      debugPrint('[ContactService] Error reading contacts: $e');
      return List<ContactModel>.from(_cachedContacts);
    }
  }

  /// Adds or updates a contact, persisting locally and instantly notifying all reactive listeners.
  ///
  /// Returns `true` if operation was successful, otherwise `false`.
  Future<bool> addContact(ContactModel contact) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
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

      if (existingIndex >= 0) {
        current[existingIndex] = contact;
      } else {
        current.add(contact);
      }

      _cachedContacts = current;
      _emitChange();

      final bool success = await _saveContactsList(prefs, current);
      debugPrint('[ContactService] Contact added/updated: ${contact.name} ($success)');
      if (success) {
        ActivityService.instance.logContactEvent(
          action: existingIndex >= 0 ? 'Updated' : 'Added',
          contactName: contact.name,
        );
      }
      return success;
    } catch (e) {
      debugPrint('[ContactService] Error adding contact: $e');
      return false;
    }
  }

  /// Deletes a contact matching [id], [contactUid], [email], or [phone].
  ///
  /// Instantly removes from in-memory cache and notifies UI listeners in real time.
  Future<bool> deleteContact(
    String id, {
    String? contactUid,
    String? email,
    String? phone,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<ContactModel> current = await getContacts();

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

      final contactToRemove = current.where(matches).firstOrNull;
      final removedName = contactToRemove?.name ?? id;
      current.removeWhere(matches);

      if (current.length == beforeCount) {
        debugPrint(
            '[ContactService] Contact with id $id not found for deletion (already absent).');
        return true;
      }

      _cachedContacts = current;
      _emitChange();

      final bool success = await _saveContactsList(prefs, current);
      debugPrint('[ContactService] Contact deleted: $id ($success)');
      if (success) {
        ActivityService.instance.logContactEvent(
          action: 'Deleted',
          contactName: removedName,
        );
      }
      return success;
    } catch (e) {
      debugPrint('[ContactService] Error deleting contact: $e');
      return false;
    }
  }

  /// Updates an existing contact by matching its [id].
  Future<bool> updateContact(ContactModel contact) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<ContactModel> current = await getContacts();

      final index = current.indexWhere((c) => c.id == contact.id);
      if (index == -1) {
        debugPrint(
            '[ContactService] Contact with id ${contact.id} not found for update.');
        return false;
      }

      current[index] = contact;
      _cachedContacts = current;
      _emitChange();

      final bool success = await _saveContactsList(prefs, current);
      debugPrint('[ContactService] Contact updated: ${contact.name} ($success)');
      if (success) {
        ActivityService.instance.logContactEvent(
          action: 'Updated',
          contactName: contact.name,
        );
      }
      return success;
    } catch (e) {
      debugPrint('[ContactService] Error updating contact: $e');
      return false;
    }
  }

  /// Extracts clean phone numbers for SOS SMS dispatch.
  Future<List<String>> getEmergencyPhoneNumbers({bool primaryOnly = false}) async {
    final List<ContactModel> contacts = await getContacts();
    if (contacts.isEmpty) return [];

    List<ContactModel> targetContacts = contacts;
    if (primaryOnly) {
      final primaryContacts = contacts.where((c) => c.isPrimary).toList();
      if (primaryContacts.isNotEmpty) {
        targetContacts = primaryContacts;
      }
    }

    return targetContacts
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

  /// Internal helper to serialize and save contacts list to [SharedPreferences].
  Future<bool> _saveContactsList(
    SharedPreferences prefs,
    List<ContactModel> contacts,
  ) async {
    final List<String> encoded = contacts.map((c) => c.toJson()).toList();
    return await prefs.setStringList(_storageKey, encoded);
  }

  /// Resets contacts back to default initial list (useful for tests or app reset).
  Future<bool> resetToDefaults() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _cachedContacts = List<ContactModel>.from(_defaultContacts);
    _emitChange();
    return await _saveContactsList(prefs, _defaultContacts);
  }

  /// Clears all stored contacts.
  Future<bool> clearContacts() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _cachedContacts = [];
    _emitChange();
    return await prefs.setStringList(_storageKey, <String>[]);
  }
}
