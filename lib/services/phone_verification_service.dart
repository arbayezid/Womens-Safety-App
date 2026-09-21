import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'auth_service.dart';

enum PhoneVerificationStep { enterPhone, enterOtp, success, failure }

/// Service responsible for Firebase Phone Authentication, OTP verification,
/// account linking, and persisting verified credentials & FCM tokens to Cloud Firestore.
class PhoneVerificationService {
  PhoneVerificationService._internal();
  static final PhoneVerificationService instance = PhoneVerificationService._internal();

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  String? _verificationId;
  int? _resendToken;

  String? get currentVerificationId => _verificationId;

  /// Checks whether the active user has a verified phone number attached to their profile.
  Future<bool> isUserPhoneVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    // 1. Check direct Firebase Auth credentials
    if (user.phoneNumber != null && user.phoneNumber!.trim().isNotEmpty) {
      return true;
    }

    // 2. Check local synchronized profile
    if (AuthService.instance.currentProfile.isPhoneVerified &&
        AuthService.instance.currentProfile.phone.isNotEmpty) {
      return true;
    }

    // 3. Fallback check from Cloud Firestore document
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists) {
        final data = doc.data();
        if (data?['isPhoneVerified'] == true &&
            (data?['phoneNumber'] as String?)?.isNotEmpty == true) {
          return true;
        }
      }
    } catch (e) {
      debugPrint('[PhoneVerification] Error verifying Firestore record: $e');
    }

    return false;
  }

  /// Sends a 6-digit SMS verification code to the target phone number (E.164 format).
  Future<void> sendOtp({
    required String phoneNumber,
    required Function(String verificationId) onCodeSent,
    required Function(String errorMessage) onError,
    required VoidCallback onAutoVerified,
  }) async {
    try {
      debugPrint('[PhoneVerification] Requesting OTP for $phoneNumber');
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(seconds: 60),
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint('[PhoneVerification] Automatic SMS code auto-retrieval completed.');
          final ok = await _linkOrUpdateCredential(credential, phoneNumber);
          if (ok) {
            onAutoVerified();
          } else {
            onError('Auto-verification failed during account linking.');
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('[PhoneVerification] Verification failed: ${e.code} - ${e.message}');
          String message = 'Phone verification failed.';
          if (e.code == 'operation-not-allowed') {
            message = 'Phone Authentication is not enabled in Firebase Console. Please enable "Phone" under Authentication > Sign-in method.';
          } else if (e.code == 'invalid-phone-number') {
            message = 'The phone number format is invalid. Please check the country code and digits.';
          } else if (e.code == 'too-many-requests') {
            message = 'Too many requests. Please wait a few minutes before trying again.';
          } else if (e.message != null) {
            message = e.message!;
          }
          onError(message);
        },
        codeSent: (String verificationId, int? resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          debugPrint('[PhoneVerification] Code sent successfully. ID: $verificationId');
          onCodeSent(verificationId);
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
          debugPrint('[PhoneVerification] Auto retrieval timeout.');
        },
      );
    } catch (e) {
      debugPrint('[PhoneVerification] General error sending OTP: $e');
      onError('Unable to request OTP: $e');
    }
  }

  /// Validates the entered 6-digit SMS OTP against the verification session ID.
  Future<bool> verifyOtp({
    required String smsCode,
    required String phoneNumber,
    required Function(String error) onError,
  }) async {
    if (_verificationId == null) {
      onError('Verification session has expired. Please request a new code.');
      return false;
    }

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode.trim(),
      );

      return await _linkOrUpdateCredential(credential, phoneNumber);
    } on FirebaseAuthException catch (e) {
      debugPrint('[PhoneVerification] FirebaseAuthException: ${e.code} - ${e.message}');
      if (e.code == 'invalid-verification-code') {
        onError('The entered OTP is incorrect. Please double-check the 6-digit code.');
      } else if (e.code == 'session-expired') {
        onError('The verification code has expired. Please tap "Resend Code".');
      } else {
        onError(e.message ?? 'Verification failed.');
      }
      return false;
    } catch (e) {
      debugPrint('[PhoneVerification] Unexpected OTP error: $e');
      onError('Verification error: $e');
      return false;
    }
  }

  /// Links the verified phone credential with the current user session and synchronizes Firestore.
  Future<bool> _linkOrUpdateCredential(PhoneAuthCredential credential, String phone) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      // 1. Link Phone Credential to existing Google/Email user session
      try {
        await user.linkWithCredential(credential);
      } on FirebaseAuthException catch (e) {
        if (e.code == 'provider-already-linked') {
          await user.updatePhoneNumber(credential);
        } else if (e.code == 'credential-already-in-use') {
          await user.updatePhoneNumber(credential);
        } else {
          debugPrint('[PhoneVerification] Link notice: ${e.code}');
          await user.updatePhoneNumber(credential);
        }
      }

      // 2. Fetch fresh device FCM Token
      String? fcmToken;
      try {
        fcmToken = await FirebaseMessaging.instance.getToken();
      } catch (fcmErr) {
        debugPrint('[PhoneVerification] FCM token fetch warning: $fcmErr');
      }

      // 3. Atomically upsert verified record in Cloud Firestore `users/{uid}`
      await _firestore.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'name': user.displayName ?? AuthService.instance.displayName,
        'email': user.email ?? '',
        'phoneNumber': phone.trim(),
        'isPhoneVerified': true,
        'fcmToken': fcmToken,
        'safetyScore': 95,
        'lastActiveAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 4. Update reactive local AuthService profile
      final updatedProfile = AuthService.instance.currentProfile.copyWith(
        phone: phone.trim(),
        isPhoneVerified: true,
        fcmToken: fcmToken,
      );
      await AuthService.instance.updateProfile(updatedProfile);

      debugPrint('[PhoneVerification] Phone successfully verified and synchronized to cloud: $phone');
      return true;
    } catch (e) {
      debugPrint('[PhoneVerification] Error finalizing profile sync: $e');
      return false;
    }
  }
}
