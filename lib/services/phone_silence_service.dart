import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How silent the phone became when a duress alert started.
enum PhoneSilenceResult { silent, vibrate, failed }

/// Silences the whole phone (calls, SMS, WhatsApp, Messenger, imo and every other app) while a
/// duress / Silent Panic alert is active, and restores the user's sound settings afterwards.
///
/// Total silence needs Do Not Disturb access, granted once from Settings. Without it the phone
/// only goes to vibrate.
class PhoneSilenceService {
  PhoneSilenceService._();
  static final PhoneSilenceService instance = PhoneSilenceService._();

  static const MethodChannel _channel = MethodChannel('com.smartsafety.smart_safety/device');

  Future<PhoneSilenceResult> silencePhone() async {
    if (!Platform.isAndroid) return PhoneSilenceResult.failed;
    try {
      final mode = await _channel.invokeMethod<String>('silencePhone');
      switch (mode) {
        case 'silent':
          return PhoneSilenceResult.silent;
        case 'vibrate':
          return PhoneSilenceResult.vibrate;
        default:
          return PhoneSilenceResult.failed;
      }
    } catch (e) {
      debugPrint('[PhoneSilence] Could not silence phone: $e');
      return PhoneSilenceResult.failed;
    }
  }

  Future<void> restorePhoneSound() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('restorePhoneSound');
    } catch (e) {
      debugPrint('[PhoneSilence] Could not restore phone sound: $e');
    }
  }

  /// Whether the user has given Woman Guard Do Not Disturb access.
  Future<bool> hasDndAccess() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasDndAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's Do Not Disturb access screen so the user can allow Woman Guard.
  Future<bool> openDndAccessSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openDndAccessSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
