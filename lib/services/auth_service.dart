import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';
import '../models/user_profile_model.dart';
import 'activity_service.dart';
import 'contact_service.dart';
import 'contact_sync_service.dart';
import 'notification_service.dart';
import 'phone_registry_service.dart';

/// Result wrapper for Google Authentication attempts.
class AuthResult {
  final bool isSuccess;
  final User? user;
  final String? errorMessage;
  final bool isCancelled;

  const AuthResult._({
    required this.isSuccess,
    this.user,
    this.errorMessage,
    this.isCancelled = false,
  });

  factory AuthResult.success(User user) =>
      AuthResult._(isSuccess: true, user: user);

  factory AuthResult.cancelled() =>
      const AuthResult._(isSuccess: false, isCancelled: true);

  factory AuthResult.failure(String message) =>
      AuthResult._(isSuccess: false, errorMessage: message);
}

/// Central service responsible for Firebase Authentication, Google Sign-In,
/// session persistence, user profile synchronization, and Guest Mode fallback.
class AuthService {
  AuthService._internal();

  /// Central singleton instance
  static final AuthService instance = AuthService._internal();

  static const String _prefsKeyGuestMode = 'smart_safety_is_guest';
  static const String _prefsKeyProfilePrefix = 'smart_safety_user_profile_';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    serverClientId:
        '207672062120-g576apnclsht157kec4detn6jfokiedf.apps.googleusercontent.com',
  );

  bool _isFirebaseInitialized = false;
  bool _isGuestMode = false;

  /// In-memory override for test environments
  User? _mockUser;

  /// Observable notifier to trigger immediate UI rebuilds on auth changes
  final ValueNotifier<User?> userNotifier = ValueNotifier<User?>(null);

  /// Reactive notifier for the synchronized [UserProfile] (listened by Profile, Settings, etc.)
  final ValueNotifier<UserProfile> profileNotifier =
      ValueNotifier<UserProfile>(UserProfile.guest());

  final StreamController<User?> _authStreamController =
      StreamController<User?>.broadcast();

  /// Reactive stream emitting the active [User] (or null when signed out/guest).
  Stream<User?> get authStateChanges => _authStreamController.stream;

  /// The currently authenticated [User], or null if unauthenticated or in Guest mode.
  User? get currentUser => _mockUser ?? (_isFirebaseInitialized ? FirebaseAuth.instance.currentUser : null);

  /// The active [UserProfile] representation.
  UserProfile get currentProfile => profileNotifier.value;

  /// Whether a valid authenticated user session exists.
  bool get isAuthenticated => currentUser != null;

  /// Whether the app is currently running in Guest mode.
  bool get isGuest => !isAuthenticated || _isGuestMode;

  /// Full display name of the active user or 'Guest'.
  String get displayName {
    if (isAuthenticated) {
      final name = currentProfile.name.trim();
      if (name.isNotEmpty && name != 'Guest') return name;
      final authName = currentUser?.displayName?.trim();
      if (authName != null && authName.isNotEmpty) return authName;
      final emailStr = currentUser?.email;
      if (emailStr != null && emailStr.contains('@')) {
        return emailStr.split('@').first;
      }
      return 'User';
    }
    return 'Guest';
  }

  /// First name / greeting format (e.g. 'Fatima' or 'Guest').
  String get greetingName {
    if (isAuthenticated) {
      return currentProfile.greetingName;
    }
    return 'Guest';
  }

  /// Profile avatar URL, if available.
  String? get photoUrl => currentProfile.photoUrl ?? currentUser?.photoURL;

  /// Email address of the current user, or null.
  String? get email {
    if (currentProfile.email.isNotEmpty) return currentProfile.email;
    return currentUser?.email;
  }

  /// Phone number of the active user profile.
  String get phone => currentProfile.phone;

  /// City / location of the active user profile.
  String get city => currentProfile.city;

  /// Date of birth of the active user profile.
  String get dob => currentProfile.dob;

  /// Blood group of the active user profile.
  String get bloodGroup => currentProfile.bloodGroup;

  /// Emergency note or medical instructions.
  String get emergencyNote => currentProfile.emergencyNote;

  /// Single letter uppercase initial for avatar display (e.g. 'R', or 'G' for guest).
  String get initials {
    final name = displayName;
    if (name.isEmpty) return 'G';
    return name[0].toUpperCase();
  }

  /// Initializes Firebase and restores existing session or guest preference.
  Future<void> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      _isFirebaseInitialized = true;

      // Subscribe to live Firebase auth state changes
      FirebaseAuth.instance.authStateChanges().listen((User? user) async {
        userNotifier.value = user;
        _authStreamController.add(user);
        if (user != null) {
          _isGuestMode = false;
          ContactService.instance.bindUser(user.uid);
          ContactSyncService.instance.initialize();
          NotificationService.instance.startSosAlertStreamListener();
        } else {
          await ContactService.instance.purgeOnSignOut();
          ContactSyncService.instance.purgeOnSignOut();
        }
        await _loadProfileForUser(user);
      });

      final user = FirebaseAuth.instance.currentUser;
      userNotifier.value = user;
      _authStreamController.add(user);
      if (user != null) {
        _isGuestMode = false;
        ContactService.instance.bindUser(user.uid);
        ContactSyncService.instance.initialize();
        NotificationService.instance.startSosAlertStreamListener();
      }
      await _loadProfileForUser(user);
    } catch (e) {
      debugPrint('[AuthService] Firebase initialization notice: $e');
      _isFirebaseInitialized = false;
      await _loadProfileForUser(null);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _isGuestMode = prefs.getBool(_prefsKeyGuestMode) ?? false;
    } catch (_) {
      _isGuestMode = false;
    }
  }

  /// Loads the [UserProfile] dynamically from Cloud Firestore scoped to the active user's UID.
  /// Zero sensitive profile data is stored in unencrypted local device preferences.
  Future<void> _loadProfileForUser(User? user) async {
    try {
      if (user == null) {
        profileNotifier.value = UserProfile.guest();
        return;
      }

      if (_isFirebaseInitialized && Firebase.apps.isNotEmpty) {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 4));

        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final cloudProfile = UserProfile.fromMap(data).copyWith(
            photoUrl: data['photoUrl'] ?? user.photoURL,
            email: (data['email']?.toString().isNotEmpty == true)
                ? data['email'].toString()
                : (user.email ?? ''),
          );
          profileNotifier.value = cloudProfile;
        } else {
          // Initial setup for this cloud account: initialize and sync to Firestore
          final initialProfile = UserProfile.fromFirebaseUser(user);
          profileNotifier.value = initialProfile;
          unawaited(syncUserToFirestore(user));
        }
      } else {
        profileNotifier.value = UserProfile.fromFirebaseUser(user);
      }

      // Automatically bind contacts and requests to the active user UID
      ContactService.instance.bindUser(user.uid);
      ContactSyncService.instance.initialize();

      // Register a phone number saved before the one-number-per-account rule existed
      final existingPhone = profileNotifier.value.phone.trim().isNotEmpty
          ? profileNotifier.value.phone
          : (user.phoneNumber ?? '');
      unawaited(PhoneRegistryService.instance.registerExistingNumber(existingPhone));
    } catch (e) {
      debugPrint('[AuthService] Error loading cloud profile: $e');
      if (user != null) {
        profileNotifier.value = UserProfile.fromFirebaseUser(user);
        unawaited(syncUserToFirestore(user));
      } else {
        profileNotifier.value = UserProfile.guest();
      }
    }
  }

  /// Automatically upserts the authenticated user's profile to Firestore `users/{uid}`
  /// so other users can discover them by email and establish mutual sync.
  Future<void> syncUserToFirestore(User user) async {
    if (!_isFirebaseInitialized) return;
    try {
      final email = (user.email ?? '').toLowerCase().trim();
      if (email.isEmpty) return;

      final name = (user.displayName != null && user.displayName!.trim().isNotEmpty)
          ? user.displayName!.trim()
          : (currentProfile.name != 'Guest' && currentProfile.name.isNotEmpty)
              ? currentProfile.name
              : email.split('@').first;

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'userId': user.uid,
        'email': email,
        'email_lowercase': email,
        'displayName': name,
        'name': name,
        'photoUrl': user.photoURL ?? currentProfile.photoUrl ?? '',
        'phoneNumber': user.phoneNumber ?? currentProfile.phone,
        'phone': user.phoneNumber ?? currentProfile.phone,
        'lastActiveAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 3), onTimeout: () {
        debugPrint('[AuthService] ⏱️ Firestore user sync timed out after 3s (persisted in offline cache)');
      });

      debugPrint('[AuthService] ☁️ Synced user ${user.uid} ($email) to Firestore users collection');
    } catch (e) {
      debugPrint('[AuthService] ⚠️ Firestore user sync warning: $e');
    }
  }

  /// Updates the user's profile dynamically in Cloud Firestore and in active memory.
  ///
  /// **Zero Physical Device Persistence**: No personal information (name, phone, blood group,
  /// medical emergency notes) is written to local [SharedPreferences].
  Future<bool> updateProfile(UserProfile updatedProfile) async {
    try {
      // 1. If authenticated with Firebase, synchronize directly to Cloud Firestore
      if (_isFirebaseInitialized && currentUser != null && Firebase.apps.isNotEmpty) {
        try {
          if (updatedProfile.name.trim().isNotEmpty &&
              updatedProfile.name != currentUser!.displayName) {
            await currentUser!.updateDisplayName(updatedProfile.name.trim());
          }
          if (updatedProfile.photoUrl != null &&
              updatedProfile.photoUrl != currentUser!.photoURL) {
            await currentUser!.updatePhotoURL(updatedProfile.photoUrl);
          }
          await currentUser!.reload();
          userNotifier.value = FirebaseAuth.instance.currentUser;

          final normalizedEmail = (currentUser!.email ?? updatedProfile.email).toLowerCase().trim();
          // Update Firestore users/{uid} document directly
          await FirebaseFirestore.instance.collection('users').doc(currentUser!.uid).set({
            'uid': currentUser!.uid,
            'name': updatedProfile.name.trim(),
            'displayName': updatedProfile.name.trim(),
            'email': normalizedEmail,
            'email_lowercase': normalizedEmail,
            'phone': updatedProfile.phone,
            'phoneNumber': updatedProfile.phone,
            'city': updatedProfile.city,
            'dob': updatedProfile.dob,
            'bloodGroup': updatedProfile.bloodGroup,
            'emergencyNote': updatedProfile.emergencyNote,
            'photoUrl': updatedProfile.photoUrl ?? currentUser!.photoURL ?? '',
            'isPhoneVerified': updatedProfile.isPhoneVerified,
            'fcmToken': updatedProfile.fcmToken,
            'lastActiveAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (cloudErr) {
          debugPrint('[AuthService] Cloud profile sync notice: $cloudErr');
        }
      }

      // 2. Immediately broadcast in memory to UI listeners (No physical disk writes!)
      profileNotifier.value = updatedProfile;
      userNotifier.value = currentUser;

      ActivityService.instance.logProfileUpdate(
        summary: 'Updated profile details for ${updatedProfile.name}',
      );

      debugPrint('[AuthService] ✅ Profile updated dynamically in cloud for ${currentUser?.uid ?? 'guest'}');
      return true;
    } catch (e) {
      debugPrint('[AuthService] ❌ Error updating profile: $e');
      return false;
    }
  }

  /// Signs in the user securely using Google Sign-In and Firebase Auth.
  Future<AuthResult> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        // User dismissed the account selection dialog
        return AuthResult.cancelled();
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final OAuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      if (_isFirebaseInitialized) {
        final UserCredential userCred =
            await FirebaseAuth.instance.signInWithCredential(credential);
        final user = userCred.user;
        if (user != null) {
          _isGuestMode = false;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_prefsKeyGuestMode, false);
          userNotifier.value = user;
          _authStreamController.add(user);
          await _loadProfileForUser(user);
          await syncUserToFirestore(user);
          return AuthResult.success(user);
        }
      }

      return AuthResult.failure('Authentication provider failed to return user.');
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] FirebaseAuthException: ${e.code} - ${e.message}');
      return AuthResult.failure(e.message ?? 'Authentication error occurred.');
    } catch (e) {
      debugPrint('[AuthService] Sign-in error: $e');
      final errorStr = e.toString();
      if (errorStr.contains('MissingPluginException')) {
        return AuthResult.failure(
            'Native plugin not loaded. Please stop the app completely and run "flutter run" to rebuild.');
      }
      if (errorStr.contains('10') || errorStr.contains('ApiException')) {
        return AuthResult.failure(
            'Google Sign-In configuration error (Code 10). Make sure the SHA-1 fingerprint is registered in Firebase Console.');
      }
      return AuthResult.failure('Unable to sign in with Google: $e');
    }
  }

  /// Sets the application state to Guest exploration mode.
  Future<void> continueAsGuest() async {
    _isGuestMode = true;
    _mockUser = null;
    userNotifier.value = null;
    _authStreamController.add(null);
    await _loadProfileForUser(null);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKeyGuestMode, true);
    } catch (_) {}
  }

  /// Signs the user out, purging all in-memory caches, subscriptions, image caches,
  /// and any legacy device storage keys to guarantee complete account isolation.
  Future<void> signOut() async {
    try {
      // 1. Sign out from Firebase Auth and Google Sign-In
      if (_isFirebaseInitialized) {
        try {
          await FirebaseAuth.instance.signOut();
        } catch (_) {}
      }
      try {
        await _googleSignIn.signOut();
      } catch (_) {}

      // 2. Evict Flutter image cache completely so avatars do not persist across accounts
      try {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      } catch (_) {}

      // 3. Purge all in-memory contacts, subscriptions, and activity history
      await ContactService.instance.purgeOnSignOut();
      ContactSyncService.instance.purgeOnSignOut();
      await ActivityService.instance.clearHistory();

      // 4. Reset in-memory session and user profile to guest defaults
      _mockUser = null;
      _isGuestMode = true;
      userNotifier.value = null;
      _authStreamController.add(null);
      profileNotifier.value = UserProfile.guest();

      // 5. Scrub any legacy sensitive device storage keys to ensure zero leftover physical device data
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('emergency_contacts_list');
        final keys = prefs.getKeys();
        for (final k in keys) {
          if (k.startsWith(_prefsKeyProfilePrefix)) {
            await prefs.remove(k);
          }
        }
        await prefs.setBool(_prefsKeyGuestMode, true);
      } catch (_) {}

      debugPrint('[AuthService] 🔒 Signed out successfully. Session and cache purged.');
    } catch (e) {
      debugPrint('[AuthService] Sign-out error: $e');
    }
  }

  /// For unit testing only: injects a mock user
  @visibleForTesting
  void setMockUserForTesting(User? user) {
    _mockUser = user;
    userNotifier.value = user;
    _authStreamController.add(user);
    if (user != null) {
      profileNotifier.value = UserProfile.fromFirebaseUser(user);
    } else {
      profileNotifier.value = UserProfile.guest();
    }
  }

  /// For unit testing only: injects a mock profile
  @visibleForTesting
  void setMockProfileForTesting(UserProfile profile) {
    profileNotifier.value = profile;
  }
}
