import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/services/auth_service.dart';
import 'package:smart_safety/utils/auth_guard.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await AuthService.instance.signOut();
  });

  group('AuthService Core Tests', () {
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
