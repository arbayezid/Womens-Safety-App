import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';

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
/// session persistence, and Guest Mode fallback.
class AuthService {
  AuthService._internal();

  /// Central singleton instance
  static final AuthService instance = AuthService._internal();

  static const String _prefsKeyGuestMode = 'smart_safety_is_guest';

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

  final StreamController<User?> _authStreamController =
      StreamController<User?>.broadcast();

  /// Reactive stream emitting the active [User] (or null when signed out/guest).
  Stream<User?> get authStateChanges => _authStreamController.stream;

  /// The currently authenticated [User], or null if unauthenticated or in Guest mode.
  User? get currentUser => _mockUser ?? (_isFirebaseInitialized ? FirebaseAuth.instance.currentUser : null);

  /// Whether a valid authenticated user session exists.
  bool get isAuthenticated => currentUser != null;

  /// Whether the app is currently running in Guest mode.
  bool get isGuest => !isAuthenticated || _isGuestMode;

  /// Full display name of the active user or 'Guest'.
  String get displayName {
    if (isAuthenticated) {
      final name = currentUser?.displayName?.trim();
      if (name != null && name.isNotEmpty) return name;
      final email = currentUser?.email;
      if (email != null && email.contains('@')) {
        return email.split('@').first;
      }
      return 'User';
    }
    return 'Guest';
  }

  /// First name / greeting format (e.g. 'Rahat' or 'Guest').
  String get greetingName {
    final full = displayName;
    if (full == 'Guest' || full == 'User') return full;
    final parts = full.split(' ');
    return parts.isNotEmpty ? parts.first : full;
  }

  /// Google profile avatar URL, if available.
  String? get photoUrl => currentUser?.photoURL;

  /// Email address of the current user, or null.
  String? get email => currentUser?.email;

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
      FirebaseAuth.instance.authStateChanges().listen((User? user) {
        userNotifier.value = user;
        _authStreamController.add(user);
      });

      userNotifier.value = FirebaseAuth.instance.currentUser;
      _authStreamController.add(FirebaseAuth.instance.currentUser);
    } catch (e) {
      debugPrint('[AuthService] Firebase initialization notice: $e');
      _isFirebaseInitialized = false;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _isGuestMode = prefs.getBool(_prefsKeyGuestMode) ?? false;
    } catch (_) {
      _isGuestMode = false;
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
  }
}
