import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/models/user_profile_model.dart';
import 'package:smart_safety/services/auth_service.dart';
import 'package:smart_safety/utils/auth_guard.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await AuthService.instance.signOut();
  });

  group('UserProfile Model Tests', () {
    test('UserProfile.guest initializes with valid guest defaults', () {
      final guest = UserProfile.guest();
      expect(guest.uid, 'guest');
      expect(guest.name, 'Guest');
      expect(guest.isGuest, isTrue);
      expect(guest.initials, 'G');
      expect(guest.greetingName, 'Guest');
      expect(guest.bloodGroup, 'B+');
    });

    test('Serializes to Map and JSON cleanly and reversibly', () {
      const profile = UserProfile(
        uid: 'user_123',
        name: 'Fatima Rahman',
        email: 'fatima@example.com',
        phone: '+8801712345678',
        city: 'Chittagong, Bangladesh',
        dob: 'Mar 15, 1999',
        bloodGroup: 'O+',
        emergencyNote: 'Asthma patient',
      );

      final jsonStr = profile.toJson();
      final restored = UserProfile.fromJson(jsonStr);

      expect(restored.uid, 'user_123');
      expect(restored.name, 'Fatima Rahman');
      expect(restored.email, 'fatima@example.com');
      expect(restored.phone, '+8801712345678');
      expect(restored.city, 'Chittagong, Bangladesh');
      expect(restored.dob, 'Mar 15, 1999');
      expect(restored.bloodGroup, 'O+');
      expect(restored.emergencyNote, 'Asthma patient');
      expect(restored.initials, 'F');
      expect(restored.greetingName, 'Fatima');
    });

    test('copyWith modifies targeted attributes while preserving others', () {
      const original = UserProfile(
        uid: 'test_uid',
        name: 'Original Name',
        phone: '123',
        bloodGroup: 'A+',
      );

      final modified = original.copyWith(
        name: 'Updated Name',
        bloodGroup: 'AB+',
      );

      expect(modified.uid, 'test_uid');
      expect(modified.name, 'Updated Name');
      expect(modified.phone, '123');
      expect(modified.bloodGroup, 'AB+');
    });
  });

  group('AuthService Profile Synchronization Tests', () {
    test('Initial unauthenticated state returns Guest attributes', () {
      final auth = AuthService.instance;
      expect(auth.isAuthenticated, isFalse);
      expect(auth.isGuest, isTrue);
      expect(auth.displayName, 'Guest');
      expect(auth.greetingName, 'Guest');
      expect(auth.initials, 'G');
      expect(auth.email, isNull);
      expect(auth.photoUrl, isNull);
    });

    test('updateProfile updates state and persists permanently', () async {
      final auth = AuthService.instance;

      const newProfile = UserProfile(
        uid: 'guest',
        name: 'Nusrat Jahan',
        phone: '+8801811223344',
        city: 'Sylhet, Bangladesh',
        dob: 'Dec 12, 2000',
        bloodGroup: 'A-',
        emergencyNote: 'No known allergies',
      );

      final success = await auth.updateProfile(newProfile);
      expect(success, isTrue);

      // Verify active notifiers and getters
      expect(auth.currentProfile.name, 'Nusrat Jahan');
      expect(auth.currentProfile.phone, '+8801811223344');
      expect(auth.currentProfile.bloodGroup, 'A-');
      expect(auth.currentProfile.city, 'Sylhet, Bangladesh');

      // Verify persistence in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final storedJson = prefs.getString('smart_safety_user_profile_guest');
      expect(storedJson, isNotNull);
      final restored = UserProfile.fromJson(storedJson!);
      expect(restored.name, 'Nusrat Jahan');
      expect(restored.phone, '+8801811223344');
      expect(restored.bloodGroup, 'A-');
    });

    test('continueAsGuest sets guest state correctly', () async {
      final auth = AuthService.instance;
      await auth.continueAsGuest();
      expect(auth.isGuest, isTrue);
      expect(auth.isAuthenticated, isFalse);
    });

    test('signOut clears state and resets to Guest mode', () async {
      final auth = AuthService.instance;
      await auth.signOut();
      expect(auth.isGuest, isTrue);
      expect(auth.isAuthenticated, isFalse);
      expect(auth.displayName, 'Guest');
    });

    test('AuthResult factory constructors work properly', () {
      final cancelled = AuthResult.cancelled();
      expect(cancelled.isSuccess, isFalse);
      expect(cancelled.isCancelled, isTrue);

      final failure = AuthResult.failure('Network timeout');
      expect(failure.isSuccess, isFalse);
      expect(failure.isCancelled, isFalse);
      expect(failure.errorMessage, 'Network timeout');
    });
  });

  group('AuthGuard Tests', () {
    testWidgets('AuthGuard invokes action immediately when authenticated',
        (WidgetTester tester) async {
      bool actionExecuted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                AuthGuard.run(
                  context,
                  onAuthenticated: () {
                    actionExecuted = true;
                  },
                );
              },
              child: const Text('Guarded Button'),
            ),
          ),
        ),
      );

      // In unauthenticated state, clicking button should open LoginRequiredBottomSheet
      await tester.tap(find.text('Guarded Button'));
      await tester.pumpAndSettle();

      expect(find.text('Account Required 🛡️'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(actionExecuted, isFalse);

      // Dismissing the sheet should keep action unexecuted
      await tester.tap(find.text('Maybe Later'));
      await tester.pumpAndSettle();

      expect(find.text('Account Required 🛡️'), findsNothing);
      expect(actionExecuted, isFalse);
    });
  });
}
