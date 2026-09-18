import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';
import '../models/user_profile_model.dart';

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
        await _loadProfileForUser(user);
      });

      final user = FirebaseAuth.instance.currentUser;
      userNotifier.value = user;
      _authStreamController.add(user);
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

  /// Loads the persisted [UserProfile] associated with the given user account UID,
  /// or seeds an initial profile from Firebase Auth if signing in for the first time.
  Future<void> _loadProfileForUser(User? user) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (user == null) {
        const guestKey = '${_prefsKeyProfilePrefix}guest';
        final savedGuest = prefs.getString(guestKey);
        if (savedGuest != null && savedGuest.isNotEmpty) {
          profileNotifier.value = UserProfile.fromJson(savedGuest);
        } else {
          profileNotifier.value = UserProfile.guest();
        }
        return;
      }

      final key = '$_prefsKeyProfilePrefix${user.uid}';
      final savedJson = prefs.getString(key);

      if (savedJson != null && savedJson.isNotEmpty) {
        final existing = UserProfile.fromJson(savedJson);
        // Ensure photoUrl and email sync with newest Google credentials if null in storage
        final synced = existing.copyWith(
          photoUrl: existing.photoUrl ?? user.photoURL,
          email: existing.email.isEmpty ? (user.email ?? '') : existing.email,
        );
        profileNotifier.value = synced;
      } else {
        // Initial setup for this account
        final initialProfile = UserProfile.fromFirebaseUser(user);
        await prefs.setString(key, initialProfile.toJson());
        profileNotifier.value = initialProfile;
      }
    } catch (e) {
      debugPrint('[AuthService] Error loading profile: $e');
      if (user != null) {
        profileNotifier.value = UserProfile.fromFirebaseUser(user);
      } else {
        profileNotifier.value = UserProfile.guest();
      }
    }
  }

  /// Updates and permanently persists the user's profile both locally and
  /// in Firebase Auth cloud credentials.
  Future<bool> updateProfile(UserProfile updatedProfile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final accountUid = currentUser?.uid ?? 'guest';
      final key = '$_prefsKeyProfilePrefix$accountUid';

      // 1. Permanently store in local preferences partitioned by account UID
      await prefs.setString(key, updatedProfile.toJson());

      // 2. If authenticated with Firebase, synchronize cloud account credentials
      if (_isFirebaseInitialized && currentUser != null) {
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
        } catch (cloudErr) {
          debugPrint('[AuthService] Cloud profile sync notice: $cloudErr');
        }
      }

      // 3. Immediately broadcast to all UI listeners
      profileNotifier.value = updatedProfile;
      userNotifier.value = currentUser;

      debugPrint('[AuthService] ✅ Profile permanently updated for account: $accountUid');
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

  /// Signs the user out, clearing Google credentials and returning to Guest mode.
  Future<void> signOut() async {
    try {
      if (_isFirebaseInitialized) {
        await FirebaseAuth.instance.signOut();
      }
      try {
        await _googleSignIn.signOut();
      } catch (_) {}

      _mockUser = null;
      _isGuestMode = true;
      userNotifier.value = null;
      _authStreamController.add(null);
      profileNotifier.value = UserProfile.guest();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKeyGuestMode, true);
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
