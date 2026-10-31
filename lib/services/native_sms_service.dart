import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of one recipient of a native SMS dispatch.
class SmsSendResult {
  final String recipient;

  /// One of `sent`, `pending`, `failed` or `permission_denied`.
  final String status;
  final String? error;

  const SmsSendResult({required this.recipient, required this.status, this.error});

  /// The mobile network accepted the message.
  bool get isSent => status == 'sent';

  /// Handed to the radio but not confirmed within the timeout; Android keeps retrying it.
  bool get isPending => status == 'pending';

  bool get isPermissionDenied => status == 'permission_denied';

  @override
  String toString() => 'SmsSendResult($recipient: $status${error != null ? ' - $error' : ''})';
}

/// Sends SOS SMS from the user's own SIM through the app's native SmsSender (dual-SIM aware,
/// multipart, with real sent confirmations) and opens the SMS app as a fallback.
class NativeSmsService {
  NativeSmsService._internal();
  static final NativeSmsService instance = NativeSmsService._internal();

  static const MethodChannel _channel = MethodChannel('com.smartsafety.smart_safety/sms');

  bool get _isSupported => !kIsWeb && Platform.isAndroid;

  /// Sends [message] to every recipient and waits up to [timeout] for the network confirmations.
  /// Returns null when the native sender is unavailable (non-Android or tests).
  Future<List<SmsSendResult>?> send(
    List<String> recipients,
    String message, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!_isSupported || recipients.isEmpty) return null;
    try {
      final raw = await _channel.invokeListMethod<Map<dynamic, dynamic>>('sendSms', {
        'recipients': recipients,
        'message': message,
        'timeoutMs': timeout.inMilliseconds,
      });
      final results = (raw ?? const [])
          .map((m) => SmsSendResult(
                recipient: m['recipient']?.toString() ?? '',
                status: m['status']?.toString() ?? 'failed',
                error: m['error']?.toString(),
              ))
          .toList();
      debugPrint('[NativeSms] Results: $results');
      return results;
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[NativeSms] Native SMS dispatch error: $e');
      return recipients.map((r) => SmsSendResult(recipient: r, status: 'failed', error: '$e')).toList();
    }
  }

  /// Opens the default SMS app with all [recipients] and [message] pre-filled (or posts a
  /// notification that does so when the app is in the background).
  /// Returns `opened`, `notified` or `failed`.
  Future<String> openComposer(List<String> recipients, String message) async {
    if (!_isSupported || recipients.isEmpty) return 'failed';
    try {
      final outcome = await _channel.invokeMethod<String>('openComposer', {
        'recipients': recipients,
        'message': message,
      });
      debugPrint('[NativeSms] SMS composer fallback: $outcome');
      return outcome ?? 'failed';
    } catch (e) {
      debugPrint('[NativeSms] SMS composer fallback error: $e');
      return 'failed';
    }
  }
}
