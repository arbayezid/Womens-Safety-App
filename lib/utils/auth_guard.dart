import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/login_required_bottom_sheet.dart';

/// Helper utility that guards sensitive or cloud-backed features.
///
/// If user is already authenticated, the action runs immediately.
/// If user is in Guest mode, prompts the user to sign in with Google.
class AuthGuard {
  AuthGuard._();

  /// Runs [onAuthenticated] if the user is signed in.
  /// Otherwise, intercepts the user with [LoginRequiredBottomSheet].
  ///
  /// If the user logs in successfully inside the sheet, [onAuthenticated]
  /// is executed seamlessly.
  static Future<void> run(
    BuildContext context, {
    required FutureOr<void> Function() onAuthenticated,
    String actionName = 'use this feature',
    String? customSubtitle,
  }) async {
    if (AuthService.instance.isAuthenticated) {
      await onAuthenticated();
      return;
    }

    final bool? loggedIn = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LoginRequiredBottomSheet(
        actionName: actionName,
        customSubtitle: customSubtitle,
      ),
    );

    if (loggedIn == true && AuthService.instance.isAuthenticated) {
      await onAuthenticated();
    }
  }
}
