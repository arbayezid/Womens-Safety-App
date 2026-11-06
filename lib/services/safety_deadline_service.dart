import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';
import '../firebase_options.dart';
import '../screens/background_reliability_screen.dart';
import 'auth_service.dart';
import 'contact_service.dart';
import 'emergency_service.dart';
import 'journey_service.dart';
import 'notification_service.dart';
import 'ride_checkin_service.dart';
import 'sos_escalation_service.dart';

// ── Pure deadline rules (unit-tested) ────────────────────────────────────────

/// Kinds of sender-side safety deadlines.
class SafetyDeadlineKind {
  static const String journey = 'journey'; // Safe Journey arrival check + Followed Mode check-ins
  static const String ride = 'ride'; // Ride Check-in overdue
  static const String sosStage1 = 'sos1'; // SOS escalation stage 1 (backup contacts)
  static const String sosStage2 = 'sos2'; // SOS escalation stage 2 (final SMS + call 999 prompt)
}

/// The native backstop fires after the in-app 30 s monitor would have detected the same state,
/// so while the app runs the in-app check always comes first.
const Duration deadlineBackstopOffset = Duration(seconds: 45);

/// SOS stage timers already run in-app; the native copy fires this much later.
const Duration sosStageBackstopOffset = Duration(seconds: 30);

String journeyDeadlineId(String journeyId) => 'journey_$journeyId';
String rideDeadlineId(String rideId) => 'ride_$rideId';
String sosStageDeadlineId(String alertId, int stage) => 'sos${stage}_$alertId';

/// When the next time-based journey check is due (mirrors JourneyService's in-app rules):
/// Followed Mode every 10 min since the last check-in; Safe Journey 5 min after the ETA, and never
/// sooner than 10 min after the last confirmed check (the in-app cooldown).
DateTime nextJourneyCheckAt({
  required bool followed,
  required DateTime startedAt,
  required DateTime expectedArrivalAt,
  DateTime? lastSafetyCheckAt,
}) {
  if (followed) {
    return (lastSafetyCheckAt ?? startedAt).add(const Duration(minutes: 10)).add(deadlineBackstopOffset);
  }
  final afterEta = expectedArrivalAt.add(const Duration(minutes: 5));
  final afterLastCheck = lastSafetyCheckAt?.add(const Duration(minutes: 10));
  final due = (afterLastCheck != null && afterLastCheck.isAfter(afterEta)) ? afterLastCheck : afterEta;
  return due.add(deadlineBackstopOffset);
}

/// Ride overdue = expected duration + 10 min grace (as RideCheckinService._checkOverdueState).
DateTime rideOverdueAt({required DateTime createdAt, required int expectedMinutes}) =>
    createdAt.add(Duration(minutes: expectedMinutes + 10)).add(deadlineBackstopOffset);

DateTime sosStageAt({required DateTime startedAt, required int stageSeconds}) =>
    startedAt.add(Duration(seconds: stageSeconds)).add(sosStageBackstopOffset);

/// One sender-side deadline handed to the native exact-alarm scheduler.
class SafetyDeadline {
  final String id;
  final String kind;
  final String refId;
  final String uid;
  final DateTime fireAt;
  final int promptSeconds;

  /// Escalate at [fireAt] without a 60 s "are you safe?" prompt first (SOS stages).
  final bool direct;
  final String title;
  final String body;

  /// "I'm safe" on the native prompt ends the journey instead of arming another check
  /// (Safe Journey arrival check, see JourneyService.shouldEndJourneyOnSafeConfirm).
  final bool endOnSafe;

  const SafetyDeadline({
    required this.id,
    required this.kind,
    required this.refId,
    required this.uid,
    required this.fireAt,
    this.promptSeconds = 60,
    this.direct = false,
    this.title = '',
    this.body = '',
    this.endOnSafe = false,
  });

  Map<String, dynamic> toArgs({bool replace = false}) => {
        'id': id,
        'kind': kind,
        'refId': refId,
        'uid': uid,
        'fireAt': fireAt.millisecondsSinceEpoch,
        'promptSeconds': promptSeconds,
        'direct': direct,
        'title': title,
        'body': body,
        'endOnSafe': endOnSafe,
        'replace': replace,
      };

  Map<String, dynamic> toFirestore(String state) => {
        'id': id,
        'kind': kind,
        'refId': refId,
        'fireAt': Timestamp.fromDate(fireAt),
        'direct': direct,
        'endOnSafe': endOnSafe,
        'state': state,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}

// ── Service ──────────────────────────────────────────────────────────────────

/// Sender-side safety deadlines that keep working while the app is in the background, locked,
/// swiped away or after a reboot.
///
/// The existing in-app Dart timers remain the primary path. Every timer is also armed as a native
/// exact alarm (Android SafetyDeadlines), persisted in SharedPreferences and in Firestore
/// (`users/{uid}/safety_deadlines/{id}`). When an alarm fires, native code calls back into this
/// service (in the live app, or in a headless engine via [safetyDeadlineBackgroundMain]) which runs
/// the EXISTING escalation code: JourneyService / RideCheckinService / SosEscalationService ->
/// EmergencyService.triggerEmergency. [claim] makes sure only one path escalates.
class SafetyDeadlineService {
  SafetyDeadlineService._internal();
  static final SafetyDeadlineService instance = SafetyDeadlineService._internal();

  static const MethodChannel _channel = MethodChannel('com.smartsafety.smart_safety/deadline');
  static const String _prefReliabilityPromptShown = 'pref_deadline_reliability_prompt_shown';

  final Map<String, int> _armedFireAt = {};
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _reliabilityPromptScheduled = false;

  bool get _isSupported => !kIsWeb && Platform.isAndroid;

  /// UI isolate: receive deadline callbacks from native code.
  void initForApp(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    if (!_isSupported) return;
    _channel.setMethodCallHandler((call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? const {});
      switch (call.method) {
        case 'deadlinePrompt':
          return _onPrompt(args, inApp: true);
        case 'deadlineFired':
          return _onFired(args);
      }
      throw MissingPluginException(call.method);
    });
  }

  Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!_isSupported) return null;
    try {
      return await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[SafetyDeadline] $method failed: $e');
      return null;
    }
  }

  /// Arms (or re-arms) a deadline. Without [replace] a running "are you safe?" check is kept.
  Future<void> arm(SafetyDeadline deadline, {bool replace = false}) async {
    final fireMs = deadline.fireAt.millisecondsSinceEpoch;
    if (!replace && _armedFireAt[deadline.id] == fireMs) return;
    _armedFireAt[deadline.id] = fireMs;
    await _invoke('arm', deadline.toArgs(replace: replace));
    _persist(deadline.uid, deadline.id, deadline.toFirestore('armed'));
    _scheduleReliabilityPrompt();
  }

  /// The app started its own 60 s check; native escalates only if the app dies before it ends.
  Future<void> prompt(String id, DateTime escalateAt) async {
    await _invoke('prompt', {'id': id, 'escalateAt': escalateAt.millisecondsSinceEpoch});
    _persist(null, id, {
      'state': 'prompting',
      'escalateAt': Timestamp.fromDate(escalateAt),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Cancels the alarm and any prompt notification for [id].
  Future<void> clear(String id) async {
    _armedFireAt.remove(id);
    await _invoke('clear', {'id': id});
    _persist(null, id, null);
  }

  /// Returns true for exactly one caller per deadline (in-app timer or native alarm).
  /// Always true where there is no native scheduler (iOS, tests).
  Future<bool> claim(String id) async {
    if (!_isSupported) return true;
    final result = await _invoke('claim', {'id': id});
    final claimed = result is bool ? result : true;
    if (claimed) {
      _armedFireAt.remove(id);
      _persist(null, id, {'state': 'fired', 'updatedAt': FieldValue.serverTimestamp()});
    }
    return claimed;
  }

  /// Native state of [id] ('armed' | 'prompting' | 'fired'), or null.
  Future<String?> stateOf(String id) async {
    final result = await _invoke('get', {'id': id});
    return result is Map ? result['state']?.toString() : null;
  }

  Future<void> clearSosStages(String alertId) async {
    await clear(sosStageDeadlineId(alertId, 1));
    await clear(sosStageDeadlineId(alertId, 2));
  }

  /// The user pressed "Send SOS now" in a safety check: the countdown and the native backstop
  /// for the same check must not send a second SOS.
  Future<void> claimRunningChecks() async {
    final ids = <String>[
      if (JourneyService.instance.activeJourney != null)
        journeyDeadlineId(JourneyService.instance.activeJourney!.id),
      if (RideCheckinService.instance.activeRide != null)
        rideDeadlineId(RideCheckinService.instance.activeRide!.id),
    ];
    for (final id in ids) {
      if (await stateOf(id) == 'prompting') await claim(id);
    }
  }

  Future<bool> canScheduleExactAlarms() async {
    if (!_isSupported) return true;
    return (await _invoke('canScheduleExactAlarms')) != false;
  }

  Future<bool> openExactAlarmSettings() async => (await _invoke('openExactAlarmSettings')) == true;

  /// After a reinstall or data clear: re-arms deadlines still recorded in Firestore. Each one is
  /// re-validated when it fires (ended journeys/rides and resolved alerts are skipped).
  Future<void> resyncFromCloud() async {
    if (!_isSupported || Firebase.apps.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('safety_deadlines')
          .where('state', isEqualTo: 'armed')
          .get()
          .timeout(const Duration(seconds: 8));
      final now = DateTime.now();
      for (final doc in snap.docs) {
        final data = doc.data();
        final fireAt = (data['fireAt'] as Timestamp?)?.toDate();
        if (fireAt == null || fireAt.isBefore(now) || fireAt.difference(now) > const Duration(hours: 24)) {
          continue;
        }
        if (await stateOf(doc.id) != null) continue;
        await arm(SafetyDeadline(
          id: doc.id,
          kind: data['kind']?.toString() ?? '',
          refId: data['refId']?.toString() ?? '',
          uid: user.uid,
          fireAt: fireAt,
          direct: data['direct'] == true,
          endOnSafe: data['endOnSafe'] == true,
        ));
      }
    } catch (e) {
      debugPrint('[SafetyDeadline] Cloud resync skipped: $e');
    }
  }

  void _persist(String? uid, String id, Map<String, dynamic>? data) {
    if (Firebase.apps.isEmpty) return;
    final owner = uid ?? FirebaseAuth.instance.currentUser?.uid;
    if (owner == null || owner.isEmpty) return;
    final ref = FirebaseFirestore.instance.collection('users').doc(owner).collection('safety_deadlines').doc(id);
    final Future<void> write = data == null ? ref.delete() : ref.set(data, SetOptions(merge: true));
    unawaited(write.catchError((Object e) {
      debugPrint('[SafetyDeadline] Firestore persist notice ($id): $e');
    }));
  }

  // ── Callbacks from native code ─────────────────────────────────────────────

  /// Deadline reached: show the "are you safe?" check. Returns 'prompted' (the app shows it),
  /// 'none' (nothing to check any more) or 'native' (native code shows its notification).
  Future<String> _onPrompt(Map<String, dynamic> args, {required bool inApp}) async {
    final kind = args['kind']?.toString() ?? '';
    final refId = args['refId']?.toString() ?? '';
    try {
      switch (kind) {
        case SafetyDeadlineKind.journey:
          if (!inApp) return 'native';
          return await JourneyService.instance.promptFromDeadline(refId) ? 'prompted' : 'native';
        case SafetyDeadlineKind.ride:
          return await RideCheckinService.instance.handleOverdueDeadline(refId, inApp: inApp);
      }
    } catch (e) {
      debugPrint('[SafetyDeadline] Prompt handler error: $e');
    }
    return 'native';
  }

  /// Check unanswered: escalate through the existing pipeline. Returns 'escalated' or 'skipped'.
  Future<String> _onFired(Map<String, dynamic> args) async {
    final kind = args['kind']?.toString() ?? '';
    final refId = args['refId']?.toString() ?? '';
    debugPrint('[SafetyDeadline] Deadline fired: $kind $refId');
    try {
      switch (kind) {
        case SafetyDeadlineKind.journey:
          return await JourneyService.instance.escalateFromDeadline(refId);
        case SafetyDeadlineKind.ride:
          return await RideCheckinService.instance.escalateOverdueFromDeadline(refId);
        case SafetyDeadlineKind.sosStage1:
          return await SosEscalationService.instance.runStageFromDeadline(refId, 1);
        case SafetyDeadlineKind.sosStage2:
          return await SosEscalationService.instance.runStageFromDeadline(refId, 2);
      }
    } catch (e) {
      debugPrint('[SafetyDeadline] Escalation handler error: $e');
    }
    return 'skipped';
  }

  // ── Headless run (app closed) ──────────────────────────────────────────────

  /// Body of the headless entrypoint: prepares the same services the app uses, then tells native
  /// code it is ready to receive the deadline call.
  static Future<void> runHeadless() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
    } catch (e) {
      debugPrint('[SafetyDeadline] Headless Firebase init notice: $e');
    }
    await NotificationService.instance.initForBackgroundIsolate();

    bool? prepared;
    _channel.setMethodCallHandler((call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? const {});
      prepared ??= await _prepareHeadlessContext();
      if (prepared != true) return 'skipped';
      switch (call.method) {
        case 'deadlinePrompt':
          return instance._onPrompt(args, inApp: false);
        case 'deadlineFired':
          final result = await instance._onFired(args);
          await _settleHeadlessWork();
          return result;
      }
      throw MissingPluginException(call.method);
    });
    await _channel.invokeMethod('headlessReady');
  }

  static Future<bool> _prepareHeadlessContext() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await AuthService.instance.prepareForBackgroundTask();
    ContactService.instance.bindUser(user.uid);
    try {
      await ContactService.instance.getContacts().timeout(const Duration(seconds: 10));
    } catch (_) {}
    return true;
  }

  /// Lets the SOS pipeline finish its follow-up work (tracking session, escalation arming,
  /// Firestore writes) before native code destroys the headless engine.
  static Future<void> _settleHeadlessWork() async {
    try {
      await EmergencyService.instance.postDispatchWork.timeout(const Duration(seconds: 45));
    } catch (_) {}
    try {
      await FirebaseFirestore.instance.waitForPendingWrites().timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  // ── One-time setup prompt ──────────────────────────────────────────────────

  void _scheduleReliabilityPrompt() {
    if (_reliabilityPromptScheduled || _navigatorKey == null || !_isSupported) return;
    _reliabilityPromptScheduled = true;
    Future.delayed(const Duration(seconds: 3), _showReliabilityPromptOnce);
  }

  Future<void> _showReliabilityPromptOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefReliabilityPromptShown) ?? false) return;

      final exact = await canScheduleExactAlarms();
      final battery = await Permission.ignoreBatteryOptimizations.isGranted;
      final notifications = await Permission.notification.isGranted;
      if (exact && battery && notifications) {
        await prefs.setBool(_prefReliabilityPromptShown, true);
        return;
      }

      final context = _navigatorKey?.currentContext;
      if (context == null || !context.mounted) return;

      final Future<bool?> dialog = showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Keep safety timers working',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
          content: Text(
            'Your safety timer must be able to alert your guardians even if Woman Guard is closed '
            'or your phone is locked. A few phone settings are needed for that.',
            style: GoogleFonts.poppins(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Later', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Set up', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
      await prefs.setBool(_prefReliabilityPromptShown, true);
      final bool? openSetup = await dialog;
      if (openSetup == true && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BackgroundReliabilityScreen()),
        );
      }
    } catch (e) {
      debugPrint('[SafetyDeadline] Reliability prompt error: $e');
    }
  }
}
