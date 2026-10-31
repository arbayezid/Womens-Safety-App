import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

enum PhoneClaimStatus {
  /// The number now belongs to (or already belonged to) the signed-in account.
  claimed,

  /// The number is registered to a different account.
  takenByAnotherAccount,

  /// The input is not a recognisable phone number.
  invalidNumber,

  /// Could not reach the server (offline) or another error occurred.
  failed,
}

class PhoneClaimResult {
  final PhoneClaimStatus status;

  /// Normalized E.164 number (e.g. +8801XXXXXXXXX) when the input was valid.
  final String? normalizedPhone;

  const PhoneClaimResult(this.status, [this.normalizedPhone]);

  bool get isClaimed => status == PhoneClaimStatus.claimed;

  /// User-facing explanation for a failed claim.
  String get message {
    switch (status) {
      case PhoneClaimStatus.claimed:
        return '';
      case PhoneClaimStatus.takenByAnotherAccount:
        return 'This phone number is already registered to another account. One number can only be used by one account.';
      case PhoneClaimStatus.invalidNumber:
        return 'Enter a valid phone number, e.g. 01XXXXXXXXX or +8801XXXXXXXXX.';
      case PhoneClaimStatus.failed:
        return 'Could not check the phone number. Please check your internet connection and try again.';
    }
  }
}

/// Guarantees that a phone number belongs to at most one account.
///
/// Each number is a document `phone_numbers/{+E164}` holding the owner's uid. Firestore security
/// rules only allow creating such a document for yourself and never reassigning it, so the first
/// account to claim a number keeps it until it releases it (changes or removes its number) - even
/// when two accounts try at the same moment. Works on the free Spark plan (no Cloud Functions).
class PhoneRegistryService {
  PhoneRegistryService._internal();
  static final PhoneRegistryService instance = PhoneRegistryService._internal();

  static const String collection = 'phone_numbers';

  /// Converts any accepted spelling of a number to one canonical E.164 key, so `01711000001`,
  /// `8801711000001` and `+880 1711-000001` are recognised as the same number.
  /// Returns null when the input is not a valid phone number.
  static String? normalize(String raw) {
    var cleaned = raw.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return null;
    final hasPlus = cleaned.startsWith('+');
    cleaned = cleaned.replaceAll('+', '');
    if (!hasPlus && cleaned.startsWith('00')) {
      cleaned = cleaned.substring(2);
    } else if (!hasPlus) {
      // Bangladesh local formats: 01XXXXXXXXX (11 digits) and 1XXXXXXXXX (10 digits)
      if (cleaned.length == 11 && cleaned.startsWith('01')) {
        cleaned = '88$cleaned';
      } else if (cleaned.length == 10 && cleaned.startsWith('1')) {
        cleaned = '880$cleaned';
      } else if (!(cleaned.length == 13 && cleaned.startsWith('8801'))) {
        // No country code and not a Bangladesh number: cannot be made unambiguous
        return null;
      }
    }
    // E.164 allows at most 15 digits; shorter than 8 is not a real subscriber number
    if (cleaned.length < 8 || cleaned.length > 15 || cleaned.startsWith('0')) return null;
    return '+$cleaned';
  }

  bool get _ready => Firebase.apps.isNotEmpty;

  /// Registers [rawPhone] to the signed-in account and releases [previousRawPhone] (if it is a
  /// different number owned by this account). An empty [rawPhone] only releases the old number.
  Future<PhoneClaimResult> claimForCurrentUser(String rawPhone, {String? previousRawPhone}) async {
    final user = _ready ? FirebaseAuth.instance.currentUser : null;
    if (user == null) return const PhoneClaimResult(PhoneClaimStatus.failed);

    final previousKey = (previousRawPhone == null || previousRawPhone.trim().isEmpty)
        ? null
        : normalize(previousRawPhone);

    if (rawPhone.trim().isEmpty) {
      if (previousKey != null) await _releaseIfOwned(previousKey, user.uid);
      return const PhoneClaimResult(PhoneClaimStatus.claimed, '');
    }

    final key = normalize(rawPhone);
    if (key == null) return const PhoneClaimResult(PhoneClaimStatus.invalidNumber);

    final firestore = FirebaseFirestore.instance;
    final ref = firestore.collection(collection).doc(key);
    try {
      // Server read: a cached answer could miss another account's claim
      final snap = await ref.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 10));
      final owner = snap.data()?['uid']?.toString();
      if (snap.exists && owner != user.uid) {
        debugPrint('[PhoneRegistry] $key already belongs to another account');
        return PhoneClaimResult(PhoneClaimStatus.takenByAnotherAccount, key);
      }

      final batch = firestore.batch();
      if (!snap.exists) {
        batch.set(ref, {
          'uid': user.uid,
          'phoneNumber': key,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      if (previousKey != null && previousKey != key) {
        final previous = await firestore
            .collection(collection)
            .doc(previousKey)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        if (previous.exists && previous.data()?['uid'] == user.uid) {
          batch.delete(previous.reference);
        }
      }
      await batch.commit().timeout(const Duration(seconds: 10));
      debugPrint('[PhoneRegistry] $key registered to ${user.uid}');
      return PhoneClaimResult(PhoneClaimStatus.claimed, key);
    } on FirebaseException catch (e) {
      debugPrint('[PhoneRegistry] Claim error for $key: ${e.code} ${e.message}');
      // permission-denied usually means another account claimed the number between our read and
      // write; confirm it, so missing (undeployed) security rules are not reported as "taken".
      if (e.code == 'permission-denied') {
        try {
          final recheck = await ref.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 10));
          if (recheck.exists && recheck.data()?['uid'] != user.uid) {
            return PhoneClaimResult(PhoneClaimStatus.takenByAnotherAccount, key);
          }
        } catch (_) {}
      }
      return PhoneClaimResult(PhoneClaimStatus.failed, key);
    } catch (e) {
      debugPrint('[PhoneRegistry] Claim error for $key: $e');
      return PhoneClaimResult(PhoneClaimStatus.failed, key);
    }
  }

  /// Returns false only when [rawPhone] is confirmed to belong to another account.
  Future<bool> isAvailableForCurrentUser(String rawPhone) async {
    final user = _ready ? FirebaseAuth.instance.currentUser : null;
    final key = normalize(rawPhone);
    if (user == null || key == null) return true;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(collection)
          .doc(key)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      return !snap.exists || snap.data()?['uid'] == user.uid;
    } catch (e) {
      debugPrint('[PhoneRegistry] Availability check failed for $key: $e');
      return true;
    }
  }

  /// Registers a number saved before this rule existed, so it cannot be taken by a new account.
  /// Silent best effort; a number another account already holds is left untouched.
  Future<void> registerExistingNumber(String rawPhone) async {
    if (rawPhone.trim().isEmpty) return;
    final result = await claimForCurrentUser(rawPhone);
    if (result.status == PhoneClaimStatus.takenByAnotherAccount) {
      debugPrint('[PhoneRegistry] Existing profile number ${result.normalizedPhone} is held by another account');
    }
  }

  Future<void> _releaseIfOwned(String key, String uid) async {
    try {
      final ref = FirebaseFirestore.instance.collection(collection).doc(key);
      final snap = await ref.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 10));
      if (snap.exists && snap.data()?['uid'] == uid) {
        await ref.delete().timeout(const Duration(seconds: 10));
        debugPrint('[PhoneRegistry] Released $key');
      }
    } catch (e) {
      debugPrint('[PhoneRegistry] Release of $key failed: $e');
    }
  }
}
