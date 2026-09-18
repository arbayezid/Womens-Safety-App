import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/contact_model.dart';
import 'activity_service.dart';

/// Singleton Service to manage emergency contacts with persistence via [SharedPreferences].
///
/// Supports CRUD operations and automatic default seeding for first-time app launches.
class ContactService {
  ContactService._internal();

  /// Central singleton instance
  static final ContactService instance = ContactService._internal();

  /// SharedPreferences key for storing serialized contacts list
  static const String _storageKey = 'emergency_contacts_list';

  /// Initial sample contacts with valid Bangladesh phone numbers (+8801...)
  static final List<ContactModel> _defaultContacts = [
    const ContactModel(
      id: 'default_1',
      name: 'Mom',
      phone: '+8801711000001',
      relationship: 'Family',
      isPrimary: true,
    ),
    const ContactModel(
      id: 'default_2',
      name: 'Dad',
      phone: '+8801933000003',
      relationship: 'Family',
      isPrimary: true,
    ),
    const ContactModel(
      id: 'default_3',
      name: 'Riya Sharma',
      phone: '+8801822000002',
      relationship: 'Best Friend',
      isPrimary: false,
    ),
  ];

  /// Retrieves all contacts from [SharedPreferences].
  ///
  /// If the storage is uninitialized or empty, it populates the initial default contacts.
  Future<List<ContactModel>> getContacts() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      if (!prefs.containsKey(_storageKey)) {
        debugPrint('[ContactService] Initializing default emergency contacts...');
        await _saveContactsList(prefs, _defaultContacts);
        return List<ContactModel>.from(_defaultContacts);
      }

      final List<String>? jsonList = prefs.getStringList(_storageKey);
      if (jsonList == null || jsonList.isEmpty) {
        return [];
      }

      return jsonList
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
    } catch (e) {
      debugPrint('[ContactService] Error reading contacts: $e');
      return [];
    }
  }

  /// Adds a new contact and persists the updated list.
  ///
  /// Returns `true` if operation was successful, otherwise `false`.
  Future<bool> addContact(ContactModel contact) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<ContactModel> current = await getContacts();

      // Avoid duplicates with the same phone number or ID
      final existingIndex = current.indexWhere(
        (c) => c.id == contact.id || c.phone.replaceAll(RegExp(r'\s+'), '') == contact.phone.replaceAll(RegExp(r'\s+'), ''),
      );

      if (existingIndex >= 0) {
        // Update existing rather than adding duplicate
        current[existingIndex] = contact;
      } else {
        current.add(contact);
      }

      final bool success = await _saveContactsList(prefs, current);
      debugPrint('[ContactService] Contact added: ${contact.name} ($success)');
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

  /// Deletes a contact by [id].
  ///
  /// Returns `true` if contact was found and deleted, otherwise `false`.
  Future<bool> deleteContact(String id) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<ContactModel> current = await getContacts();

      final int beforeCount = current.length;
      final contactToRemove = current.where((c) => c.id == id).firstOrNull;
      final removedName = contactToRemove?.name ?? id;
      current.removeWhere((c) => c.id == id);

      if (current.length == beforeCount) {
        debugPrint('[ContactService] Contact with id $id not found for deletion.');
        return false;
      }

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
  ///
  /// Returns `true` if contact was updated successfully.
  Future<bool> updateContact(ContactModel contact) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<ContactModel> current = await getContacts();

      final index = current.indexWhere((c) => c.id == contact.id);
      if (index == -1) {
        debugPrint('[ContactService] Contact with id ${contact.id} not found for update.');
        return false;
      }

      current[index] = contact;
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
  ///
  /// If [primaryOnly] is `true`, extracts numbers of primary contacts first.
  /// If no primary contacts exist, falls back to returning all saved contact numbers.
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
        .toSet() // Remove duplicates
        .toList();
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
    return await _saveContactsList(prefs, _defaultContacts);
  }

  /// Clears all stored contacts.
  Future<bool> clearContacts() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return await prefs.setStringList(_storageKey, <String>[]);
  }
}
