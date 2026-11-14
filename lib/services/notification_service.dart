import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../firebase_options.dart';
import '../screens/incident_room_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/journey_model.dart';
import '../models/ride_checkin.dart';
import '../screens/ride_details_screen.dart';
import '../widgets/intrusive_sos_dialog.dart';
import 'activity_service.dart';
import 'contact_sync_service.dart';
import 'guardian_alert_service.dart';
import 'journey_guardian_alerts.dart';
import 'navigation_service.dart';
import 'siren_service.dart';

/// Top-level background notification action handler for flutter_local_notifications.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  debugPrint('[NotificationBackground] Action: ${response.actionId} | payload: ${response.payload}');
  final payloadStr = response.payload;
  if (payloadStr == null || payloadStr.isEmpty) return;

  try {
    final Map<String, dynamic> data = jsonDecode(payloadStr) as Map<String, dynamic>;
    if (response.actionId == 'action_call') {
      final phone = (data['senderPhone'] ?? data['sender_phone'] ?? '').toString().trim();
      if (phone.isNotEmpty) {
        final clean = phone.replaceAll(RegExp(r'\s+'), '');
        final uri = Uri.parse('tel:$clean');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
    } else if (response.actionId == 'action_view_map') {
      final lat = (data['lat'] as num?)?.toDouble() ??
          double.tryParse(data['latitude']?.toString() ?? '');
      final lng = (data['lng'] as num?)?.toDouble() ??
          double.tryParse(data['longitude']?.toString() ?? '');
      if (lat != null && lng != null) {
        await NavigationService.instance.navigateTo(
          destLat: lat,
          destLng: lng,
          destLabel: '${data['senderName'] ?? 'SOS'} (Emergency)',
        );
      }
    }
  } catch (e) {
    debugPrint('[NotificationBackground] Error handling action: $e');
  }
}

/// Top-level background message handler for FCM.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    debugPrint('[FCM Background] Incoming message: ${message.messageId} | type: ${message.data['type']}');
  } catch (e) {
    debugPrint('[FCM Background] Initialization error: $e');
  }
}

/// Service managing Firebase Cloud Messaging (FCM) registrations, real-time Firestore
/// SOS alert streams, foreground notification display, token synchronization, and intrusive SOS alerts.
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  FirebaseMessaging get _fcm => FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  GlobalKey<NavigatorState>? _navigatorKey;
  bool _isInitialized = false;

  StreamSubscription<QuerySnapshot>? _sosAlertsSubscription;
  StreamSubscription<QuerySnapshot>? _sosAlertsSubUid;
  StreamSubscription<QuerySnapshot>? _sosAlertsSubEmail;
  Timer? _heartbeatTimer;
  final Map<String, Map<String, dynamic>> _liveActiveAlerts = {};

  /// Ring keys (`alertId#ringSeq`) this listener already processed (rang or handed to native).
  final Set<String> _shownRingKeys = {};

  /// Ring keys the user dismissed or acknowledged on this device (persisted).
  final Set<String> _dismissedRingKeys = {};

  /// Ring keys whose dialog was already opened automatically on this device (persisted). The
  /// dialog opens on its own at most once per ring key; afterwards only on a user request.
  final Set<String> _presentedRingKeys = {};
  static const int _maxPresentedRingKeys = 300;
  bool _isSosDialogShowing = false;

  /// Label shown to guardians for an alert sent by an unanswered automatic check, so they can
  /// tell it from a button press.
  static String automaticAlertLabel(Object? source) {
    final s = source?.toString().trim() ?? '';
    return 'Automatic alert: no response to a safety check${s.isNotEmpty ? ' ($s)' : ''}';
  }

  /// Ring key of an alert: its ID plus its ring sequence. The same alert rings again only when
  /// the sender deliberately presses SOS again (ringSeq + 1).
  static String sosRingKey(String alertId, Object? ringSeq) => '$alertId#${ringSeqOf(ringSeq)}';

  /// Reads a ring sequence from Firestore / FCM data; missing or invalid counts as 0.
  static int ringSeqOf(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  /// Type-tolerant time parsing (Timestamp, DateTime, epoch ms, ISO or ms string).
  static DateTime? _parseAlertTime(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
      final ms = int.tryParse(raw);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return null;
  }

  /// An active alert (re)pressed at most this long ago is live: full-screen dialog + 2-minute
  /// siren. Older active alerts and ended ones go to the inbox only. Same as LIVE_ALERT_MS in
  /// GuardianAlertService.kt; keep the two in step.
  static const Duration sosLiveWindow = Duration(minutes: 30);

  /// When the alert last rang on purpose: its trigger time, or `ringAt` of the sender's latest
  /// re-press if later. (Not lastUpdatedAt: live location updates move that every few seconds.)
  static DateTime? sosLastRingTime(Map<String, dynamic> data) {
    final triggered = _parseAlertTime(data['triggeredAt'] ?? data['timestamp']);
    final rung = _parseAlertTime(data['ringAt']);
    if (triggered == null) return rung;
    if (rung == null) return triggered;
    return rung.isAfter(triggered) ? rung : triggered;
  }

  /// Whether an alert that is active for this user is still live (pressed within [sosLiveWindow]).
  static bool isSosAlertLive(Map<String, dynamic> data, DateTime now) {
    final last = sosLastRingTime(data);
    return last != null && now.difference(last) <= sosLiveWindow;
  }

  /// True when [myUid] answered "I'm Responding" for the alert's current ring.
  ///
  /// `acknowledgedBy` is never cleared (it halts escalation and lists responders), so on its own it
  /// would silence the guardian for good. An acknowledgement only covers rings up to the moment it
  /// was made: when the sender deliberately re-presses later (`ringAt` after my `acknowledgedAt`),
  /// I am rung again. Both times are server timestamps. If my acknowledgement time is unknown
  /// while a re-ring exists, the alert rings: the local ring-key dismissal still stops repeats of
  /// a ring already answered on this device. Same rule in GuardianAlertService.kt.
  @visibleForTesting
  static bool acknowledgedCurrentRing(Map<String, dynamic> data, String myUid) {
    final acknowledgedBy =
        ((data['acknowledgedBy'] as List<dynamic>?) ?? const []).map((e) => e.toString());
    if (!acknowledgedBy.contains(myUid)) return false;
    final ringAt = _parseAlertTime(data['ringAt']);
    if (ringAt == null) return true; // never re-rung: the acknowledgement covers it
    final ackTimes = data['acknowledgedAt'];
    final ackAt = ackTimes is Map ? _parseAlertTime(ackTimes[myUid]) : null;
    if (ackAt == null) return false;
    return !ringAt.isAfter(ackAt);
  }

  /// Eligibility rules shared with the native GuardianAlertService. Returns the alert's trigger
  /// time when [data] should alert this device, or null when it must be skipped: not active, sent
  /// by me, dismissed or acknowledged by me for this ring (in the cloud or locally for this ring
  /// key; see [acknowledgedCurrentRing]), expired,
  /// without a trigger time, older than 3 hours, or not addressed to me.
  @visibleForTesting
  static DateTime? sosAlertTimeIfEligible({
    required String alertId,
    required Map<String, dynamic> data,
    required String myUid,
    required String myEmail,
    required Set<String> dismissedRingKeys,
    required DateTime now,
  }) {
    final status = (data['status'] ?? '').toString().toLowerCase();
    if (status != 'active') return null;

    final senderId = (data['senderId'] ?? data['sender_uid'])?.toString();
    if (senderId == myUid) return null; // Do not alert the sender on their own device

    if (dismissedRingKeys.contains(sosRingKey(alertId, data['ringSeq']))) return null;

    List<String> uids(Object? raw) => ((raw as List<dynamic>?) ?? const []).map((e) => e.toString()).toList();
    if (uids(data['dismissedBy']).contains(myUid)) return null;
    if (acknowledgedCurrentRing(data, myUid)) return null;

    final expiresAt = _parseAlertTime(data['expiresAt']);
    if (expiresAt != null && expiresAt.isBefore(now)) return null;

    final alertDate = _parseAlertTime(data['triggeredAt'] ?? data['timestamp']);
    if (alertDate == null) return null;

    // Ignore stale alerts last pressed more than 3 hours ago
    if (now.difference(sosLastRingTime(data) ?? alertDate).inHours.abs() > 3) return null;

    // Check if current user is an intended recipient
    final recEmails = ((data['recipientEmails'] as List<dynamic>?) ?? const [])
        .map((e) => e.toString().toLowerCase().trim());
    final bool matchesEmail = myEmail.isNotEmpty && recEmails.contains(myEmail);
    final bool matchesUid = uids(data['recipientUids']).contains(myUid);
    if (!matchesEmail && !matchesUid) return null;

    return alertDate;
  }

  /// Observable reactive notifier emitting the latest active incoming SOS alert payload (or null when none active).
  /// Listened by [HomeScreen] and [IntrusiveSosDialog] for immediate real-time UI reaction without reload.
  final ValueNotifier<Map<String, dynamic>?> activeIncomingSosNotifier =
      ValueNotifier<Map<String, dynamic>?>(null);

  bool get isSosDialogShowing => _isSosDialogShowing;

  StreamSubscription<List<Map<String, dynamic>>>? _requestsSubscription;
  final Set<String> _shownRequestIds = {};

  StreamSubscription? _rideCheckinSubUid;
  StreamSubscription? _rideCheckinSubEmail;
  final Set<String> _notifiedRideKeys = {};

  StreamSubscription? _journeySubUid;
  StreamSubscription? _journeySubEmail;
  final Set<String> _notifiedJourneyKeys = {};

  /// Latest journey documents from each guardian stream ('uid' / 'email'), merged into
  /// [incomingActiveJourneysNotifier].
  final Map<String, Map<String, Map<String, dynamic>>> _guardianJourneyDocs = {};

  /// Re-evaluates the live journey list every minute (ETA countdown, stale sessions dropping off)
  /// even when the traveller's phone stops sending updates.
  Timer? _guardianJourneyClock;

  /// Safe Journeys / Followed Mode sessions currently underway by contacts this user protects.
  /// Shown on the home screen so they stay reachable after the notification is dismissed.
  final ValueNotifier<List<JourneyModel>> incomingActiveJourneysNotifier =
      ValueNotifier<List<JourneyModel>>([]);

  /// Active rides currently underway by contacts this user protects
  final ValueNotifier<List<RideCheckinModel>> incomingActiveRidesNotifier =
      ValueNotifier<List<RideCheckinModel>>([]);

  /// Alerts whose heads-up banner this device posted (removed again once the alert ends).
  final Set<String> _bannerAlertIds = {};

  static int _bannerIdFor(String alertId) => 600000 + (alertId.hashCode & 0xFFFF);

  /// Headless safety-deadline run (app closed): only the local notifications plugin is needed
  /// for status notifications. No listeners, dialogs or FCM.
  Future<void> initForBackgroundIsolate() async {
    try {
      await _localNotifications.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      );
    } catch (e) {
      debugPrint('[NotificationService] Background init notice: $e');
    }
  }

  /// Initializes notification channels, permissions, FCM listeners, and real-time Firestore streams.
  Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    if (_isInitialized) return;
    _navigatorKey = navigatorKey;
    await _loadDismissedAlertIds();
    await _loadPresentedRingKeys();
    // A tap on the native guardian alert notification opens the alert here, silently.
    GuardianAlertService.instance.setAlertOpenedHandler(_openAlertFromNotification);

    try {
      // 1. Initialize local notifications plugin (purely local & offline)
      try {
        const AndroidInitializationSettings androidSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        final DarwinNotificationCategory sosCategory = DarwinNotificationCategory(
          'sos_emergency_category',
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(
              'action_call',
              'Call',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
              },
            ),
            DarwinNotificationAction.plain(
              'action_view_map',
              'View Map',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
              },
            ),
          ],
        );
        final DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
          notificationCategories: [sosCategory],
        );
        final InitializationSettings initSettings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );

        await _localNotifications.initialize(
          initSettings,
          onDidReceiveNotificationResponse: (NotificationResponse response) async {
            debugPrint('[LocalNotification] Clicked notification: action=${response.actionId} | payload=${response.payload}');
            Map<String, dynamic>? parsedPayload;
            if (response.payload != null && response.payload!.isNotEmpty) {
              try {
                parsedPayload = jsonDecode(response.payload!) as Map<String, dynamic>?;
              } catch (_) {}
            }

            // Tapping an SOS notification counts as the guardian opening that alert: silence its
            // siren. Other notifications (rides, journeys, requests) never touch the siren.
            if (parsedPayload?['type'] == 'SOS_ALERT') {
              unawaited(SirenService.instance.stopAlertSiren(parsedPayload?['alertId']?.toString() ?? ''));
            }

            final activeAlert = activeIncomingSosNotifier.value ?? parsedPayload;

            if (response.actionId == 'action_call') {
              final phone = (activeAlert?['senderPhone'] ?? activeAlert?['sender_phone'] ?? '').toString().trim();
              if (phone.isNotEmpty) {
                final clean = phone.replaceAll(RegExp(r'\s+'), '');
                final uri = Uri.parse('tel:$clean');
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (e) {
                  debugPrint('[Notification] Call launch error: $e');
                }
                return;
              }
            } else if (response.actionId == 'action_view_map') {
              final lat = (activeAlert?['lat'] as num?)?.toDouble() ??
                  double.tryParse(activeAlert?['latitude']?.toString() ?? '');
              final lng = (activeAlert?['lng'] as num?)?.toDouble() ??
                  double.tryParse(activeAlert?['longitude']?.toString() ?? '');
              if (lat != null && lng != null) {
                await NavigationService.instance.navigateTo(
                  destLat: lat,
                  destLng: lng,
                  destLabel: '${activeAlert?['senderName'] ?? 'SOS'} (Emergency)',
                );
                return;
              }
            }

            final context = _navigatorKey?.currentContext;
            if (context != null) {
              if (parsedPayload != null && parsedPayload['type'] == 'journey') {
                final journeyId = parsedPayload['journeyId']?.toString() ?? '';
                if (journeyId.isNotEmpty) {
                  GuardianAlertService.instance.openJourney(journeyId);
                  return;
                }
              }

              if (parsedPayload != null && parsedPayload['type'] == 'ride_checkin') {
                final rideId = parsedPayload['rideId']?.toString() ?? '';
                if (rideId.isNotEmpty) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RideDetailsScreen(rideId: rideId),
                    ),
                  );
                  return;
                }
              }

              if (activeAlert != null) {
                final alertId = activeAlert['alertId']?.toString() ?? '';
                if (alertId.isNotEmpty) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => IncidentRoomScreen(
                        alertId: alertId,
                        initialData: activeAlert,
                      ),
                    ),
                  );
                }
              }
            }
          },
          onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
        );

        // High-importance Android Notification Channel with Siren Sound for SOS
        final AndroidNotificationChannel sosChannelV2 = AndroidNotificationChannel(
          'sos_emergency_channel_v2',
          'SOS Emergency Alerts',
          description: 'High-priority emergency alerts with audible siren sound triggered by mutual contacts.',
          importance: Importance.max,
          sound: const RawResourceAndroidNotificationSound('siren'),
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
          enableLights: true,
          ledColor: const Color(0xFFFF3B30),
        );

        // High-importance Android Notification Channel for Safe Journey Dead-Man's safety check
        const AndroidNotificationChannel safetyCheckChannel = AndroidNotificationChannel(
          'safety_check_channel',
          'Safe Journey Safety Checks',
          description: 'High-priority check-in prompts before auto-dispatching emergency SOS.',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );

        // High-Importance Android Notification Channel for Ride Safety Alerts
        final AndroidNotificationChannel rideSafetyAlertsChannel = AndroidNotificationChannel(
          'ride_safety_alerts_channel_v2',
          'Ride Safety Alerts',
          description: 'High-priority alerts when contacts start, update, or complete a ride.',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 400, 200, 400]),
        );

        // Keep legacy channel for backward compatibility
        const AndroidNotificationChannel rideCheckinChannel = AndroidNotificationChannel(
          'ride_checkin_channel',
          'Ride Safety Check-in',
          description: 'Non-intrusive notifications for vehicle plate updates and ride status.',
          importance: Importance.defaultImportance,
          playSound: true,
          enableVibration: true,
        );

        final androidPlugin = _localNotifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          await androidPlugin.createNotificationChannel(sosChannelV2);
          await androidPlugin.createNotificationChannel(safetyCheckChannel);
          await androidPlugin.createNotificationChannel(rideSafetyAlertsChannel);
          await androidPlugin.createNotificationChannel(rideCheckinChannel);
          await androidPlugin.requestNotificationsPermission();
        }
        try {
          await Permission.notification.request();
        } catch (_) {}
      } catch (localErr) {
        debugPrint('[FCM] Local notifications init error: $localErr');
      }

      // 2. Request Notification Permissions with timeout
      try {
        final settings = await _fcm.requestPermission(
          alert: true,
          announcement: false,
          badge: true,
          carPlay: false,
          criticalAlert: true,
          provisional: false,
          sound: true,
        ).timeout(const Duration(seconds: 5));

        debugPrint('[FCM] Permission status: ${settings.authorizationStatus}');
      } catch (permErr) {
        debugPrint('[FCM] Permission request note: $permErr');
      }

      // 3. Register FCM foreground & background click listeners
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('[FCM Foreground] Received: ${message.data}');
        final type = message.data['type'];

        if (type == 'SOS_ALERT') {
          // No siren here: only _ringIfUnclaimed rings, after claiming the ring key.
          final alertId = message.data['alertId']?.toString() ?? '';
          if (alertId.isEmpty) {
            _showIntrusiveSosDialog(message.data);
          } else {
            final ringKey = sosRingKey(alertId, message.data['ringSeq']);
            if (!_shownRingKeys.contains(ringKey)) {
              _shownRingKeys.add(ringKey);
              _autoPresentSosDialog({...message.data, 'ringKey': ringKey});
            }
          }
        } else if (type == 'RIDE_CHECKIN') {
          final rideId = message.data['rideId']?.toString() ?? '';
          final status = (message.data['status'] ?? 'active').toString().toLowerCase();
          final travelerName = message.data['travelerName'] ?? 'Traveler';
          final plate = message.data['plate'] ?? 'Vehicle Plate';
          final rideType = message.data['rideType'] ?? 'Ride';
          showRideCheckinNotification(
            title: status == 'arrived'
                ? '✅ $travelerName arrived safely'
                : '🚗 $travelerName started a $rideType ride — $plate',
            body: status == 'arrived'
                ? 'The ride in vehicle $plate has completed safely.'
                : 'Vehicle: $plate. Tap to view live location & driver details.',
            payload: jsonEncode({'type': 'ride_checkin', 'rideId': rideId}),
          );
          _showInAppRideAlert(
            rideId: rideId,
            travelerName: travelerName,
            rideType: rideType,
            plate: plate,
            status: status,
          );
        } else {
          _showLocalNotification(message);
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[FCM App Opened] Message clicked: ${message.data}');
        if (message.data['type'] == 'SOS_ALERT') {
          // The user tapped the notification: open the alert silently.
          final alertId = message.data['alertId']?.toString() ?? '';
          if (alertId.isNotEmpty) _markPresented(sosRingKey(alertId, message.data['ringSeq']));
          _showIntrusiveSosDialog(message.data);
        } else if (message.data['type'] == 'RIDE_CHECKIN') {
          final rideId = message.data['rideId']?.toString() ?? '';
          if (rideId.isNotEmpty) {
            final context = _navigatorKey?.currentContext;
            if (context != null) {
              if (!context.mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => RideDetailsScreen(rideId: rideId)),
              );
            }
          }
        }
      });

      _fcm.onTokenRefresh.listen(syncTokenToFirestore);

      // 4. Obtain and synchronize device FCM Token safely with timeout
      try {
        final token = await _fcm.getToken().timeout(
          const Duration(seconds: 4),
          onTimeout: () {
            debugPrint('[FCM] getToken() timed out after 4s. Continuing.');
            return null;
          },
        );
        debugPrint('[FCM] Device Token: $token');
        if (token != null) {
          syncTokenToFirestore(token);
        }
      } catch (tokenErr) {
        debugPrint('[FCM] Token fetch error: $tokenErr');
      }

      // 5. Start real-time Firestore stream listener (Direct in-app alerts without cloud functions!)
      startSosAlertStreamListener();
      startGuardianRequestListener();
      startGuardianRideCheckinListener();
      startGuardianJourneyListener();

      // Listen for auth state changes to dynamically re-attach listeners and sync token
      FirebaseAuth.instance.authStateChanges().listen((user) async {
        if (user != null) {
          startSosAlertStreamListener();
          startGuardianRequestListener();
          startGuardianRideCheckinListener();
          startGuardianJourneyListener();
          try {
            final token = await _fcm.getToken().timeout(
              const Duration(seconds: 4),
              onTimeout: () => null,
            );
            if (token != null) {
              await syncTokenToFirestore(token);
            }
          } catch (_) {}
        } else {
          _cancelSosAlertsSubscriptions();
          _requestsSubscription?.cancel();
          _rideCheckinSubUid?.cancel();
          _rideCheckinSubEmail?.cancel();
          _journeySubUid?.cancel();
          _journeySubEmail?.cancel();
          _guardianJourneyClock?.cancel();
          _guardianJourneyClock = null;
          _guardianJourneyDocs.clear();
          incomingActiveJourneysNotifier.value = [];
          activeIncomingSosNotifier.value = null;
          SirenService.instance.stopSiren();
        }
      });

      _isInitialized = true;
    } catch (e) {
      debugPrint('[NotificationService] Initialization error: $e');
    }
  }

  /// Loads previously dismissed SOS alert IDs from [SharedPreferences] to ensure
  /// they never re-appear after the app is closed and reopened.
  Future<void> _loadDismissedAlertIds() async {
    try {
      final String? uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
      final key = uid != null ? 'dismissed_sos_alerts_$uid' : 'dismissed_sos_alerts_default';
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(key) ?? [];
      // Entries saved before ring keys existed are bare alert IDs: they mean ring 0.
      final keys = saved.map((k) => k.contains('#') ? k : sosRingKey(k, 0));
      _dismissedRingKeys.addAll(keys);
      _shownRingKeys.addAll(keys);
    } catch (e) {
      debugPrint('[NotificationService] Error loading dismissed alerts: $e');
    }
  }

  String _presentedPrefsKey() {
    final String? uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
    return 'presented_sos_ring_keys_${uid ?? 'default'}';
  }

  /// Loads the ring keys whose dialog already opened automatically on this device.
  Future<void> _loadPresentedRingKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _presentedRingKeys.addAll(prefs.getStringList(_presentedPrefsKey()) ?? const []);
    } catch (e) {
      debugPrint('[NotificationService] Error loading presented ring keys: $e');
    }
  }

  /// Remembers (in memory and SharedPreferences, capped at 300) that [ringKey]'s dialog was shown.
  void _markPresented(String ringKey) {
    if (ringKey.isEmpty || !_presentedRingKeys.add(ringKey)) return;
    final prefsKey = _presentedPrefsKey();
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final list = prefs.getStringList(prefsKey) ?? <String>[];
        if (list.contains(ringKey)) return;
        list.add(ringKey);
        if (list.length > _maxPresentedRingKeys) {
          list.removeRange(0, list.length - _maxPresentedRingKeys);
        }
        await prefs.setStringList(prefsKey, list);
      } catch (e) {
        debugPrint('[NotificationService] Error saving presented ring key: $e');
      }
    }());
  }

  /// Ring sequence of [alertId] as currently shown, or 0.
  int _currentRingSeqFor(String alertId) {
    final alert = activeIncomingSosNotifier.value;
    return alert != null && alert['alertId'] == alertId ? ringSeqOf(alert['ringSeq']) : 0;
  }

  /// Persistently marks an active SOS alert as dismissed/responded to by the current user.
  /// Prevents this ring of the alert from popping up again on this device or across app
  /// restarts; only a deliberate re-alert by the sender (a new ring sequence) rings again.
  Future<void> dismissAlert(String alertId, {Object? ringSeq}) async {
    final ringKey = sosRingKey(alertId, ringSeq ?? _currentRingSeqFor(alertId));
    _shownRingKeys.add(ringKey);
    _dismissedRingKeys.add(ringKey);
    unawaited(SirenService.instance.stopAlertSiren(alertId));

    if (activeIncomingSosNotifier.value?['alertId'] == alertId) {
      activeIncomingSosNotifier.value = null;
    }

    // 1. Persist locally to SharedPreferences so it never re-shows even across process kill
    try {
      final String? uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
      final key = uid != null ? 'dismissed_sos_alerts_$uid' : 'dismissed_sos_alerts_default';
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(key) ?? [];
      if (!list.contains(ringKey)) {
        list.add(ringKey);
        if (list.length > 200) {
          list.removeRange(0, list.length - 200);
        }
        await prefs.setStringList(key, list);
      }
    } catch (e) {
      debugPrint('[NotificationService] Error saving dismissed alert to prefs: $e');
    }

    // 2. Mark dismissed in Firestore sos_alerts doc (dismissedBy only, does NOT halt escalation)
    try {
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await FirebaseFirestore.instance.collection('sos_alerts').doc(alertId).set({
            'dismissedBy': FieldValue.arrayUnion([user.uid]),
          }, SetOptions(merge: true));
        }
      }
    } catch (e) {
      debugPrint('[NotificationService] Error updating alert dismissed status in Firestore: $e');
    }
  }

  /// Explicitly marks an active SOS alert as acknowledged by the current guardian user ("I'm Responding").
  /// Writes acknowledgedBy and timestamped acknowledgedAt, halting the Smart SOS Escalation sequence.
  Future<void> acknowledgeAlert(String alertId, {Object? ringSeq}) async {
    final ringKey = sosRingKey(alertId, ringSeq ?? _currentRingSeqFor(alertId));
    _shownRingKeys.add(ringKey);
    _dismissedRingKeys.add(ringKey);
    unawaited(SirenService.instance.stopAlertSiren(alertId));

    // 1. Persist locally to SharedPreferences
    try {
      final String? uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
      final key = uid != null ? 'dismissed_sos_alerts_$uid' : 'dismissed_sos_alerts_default';
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(key) ?? [];
      if (!list.contains(ringKey)) {
        list.add(ringKey);
        if (list.length > 200) {
          list.removeRange(0, list.length - 200);
        }
        await prefs.setStringList(key, list);
      }
    } catch (e) {
      debugPrint('[NotificationService] Error saving acknowledged alert to prefs: $e');
    }

    // 2. Mark acknowledged in Firestore sos_alerts doc
    try {
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await FirebaseFirestore.instance.collection('sos_alerts').doc(alertId).set({
            'acknowledgedBy': FieldValue.arrayUnion([user.uid]),
            'acknowledgedAt': {
              user.uid: FieldValue.serverTimestamp(),
            },
            'lastRespondedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          // Log timeline event to events subcollection
          await FirebaseFirestore.instance
              .collection('sos_alerts')
              .doc(alertId)
              .collection('events')
              .add({
            'type': 'guardian_responding',
            'title': 'Guardian Responding',
            'description': '${user.displayName ?? 'Guardian'} acknowledged the alert and confirmed they are responding.',
            'actorName': user.displayName ?? 'Guardian',
            'actorUid': user.uid,
            'timestamp': FieldValue.serverTimestamp(),
          }).timeout(const Duration(seconds: 2));
        }
      }
    } catch (e) {
      debugPrint('[NotificationService] Error updating alert acknowledged status in Firestore: $e');
    }

    // 3. Log acknowledgement in local activity history
    try {
      ActivityService.instance.logQuickAction('Responded to SOS Alert');
    } catch (_) {}
  }

  /// Cancels all active Firestore subscriptions and timers
  void _cancelSosAlertsSubscriptions() {
    _sosAlertsSubscription?.cancel();
    _sosAlertsSubscription = null;
    _sosAlertsSubUid?.cancel();
    _sosAlertsSubUid = null;
    _sosAlertsSubEmail?.cancel();
    _sosAlertsSubEmail = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Subscribes to real-time Cloud Firestore `sos_alerts` collection to receive
  /// instant in-app alerts directly, without requiring deployed Cloud Functions.
  ///
  /// Uses separate rule-compatible queries for recipient UIDs and recipient emails,
  /// deduplicates multiple SOS button presses from the same sender, and shows
  /// ONLY the single latest alert with timing, and never re-shows dismissed alerts.
  void startSosAlertStreamListener() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('[NotificationService] Skipping SOS stream listener: user is unauthenticated.');
      return;
    }

    final String myEmail = (user.email ?? '').toLowerCase().trim();
    final String myUid = user.uid;

    _loadDismissedAlertIds();
    _loadPresentedRingKeys();
    _cancelSosAlertsSubscriptions();
    _liveActiveAlerts.clear();

    debugPrint('[NotificationService] 🛡️ Starting real-time Firestore SOS streams for $myEmail (UID: $myUid)...');

    void handleAlertSnapshot(String sourceKey, QuerySnapshot<Map<String, dynamic>> snapshot) {
      _liveActiveAlerts.removeWhere((key, val) => val['_source'] == sourceKey);
      for (final doc in snapshot.docs) {
        _liveActiveAlerts[doc.id] = {
          '_source': sourceKey,
          'doc': doc,
          'data': doc.data(),
        };
      }
      _processIncomingSosAlerts(myUid, myEmail);
    }

    // 1. Single-field query: recipientUids arrayContains myUid (Zero composite index required!)
    _sosAlertsSubUid = FirebaseFirestore.instance
        .collection('sos_alerts')
        .where('recipientUids', arrayContains: myUid)
        .snapshots()
        .listen(
          (snap) => handleAlertSnapshot('uid', snap),
          onError: (err) {
            debugPrint('[NotificationService] SOS UID stream error: $err');
            _sosAlertsSubUid = null;
          },
        );

    // 2. Single-field query: recipientEmails arrayContains myEmail (Zero composite index required!)
    if (myEmail.isNotEmpty) {
      _sosAlertsSubEmail = FirebaseFirestore.instance
          .collection('sos_alerts')
          .where('recipientEmails', arrayContains: myEmail)
          .snapshots()
          .listen(
            (snap) => handleAlertSnapshot('email', snap),
            onError: (err) {
              debugPrint('[NotificationService] SOS Email stream error: $err');
              _sosAlertsSubEmail = null;
            },
          );
    }

    // 3. Periodic heartbeat timer (every 4 seconds) ensuring real-time resilience and sync
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;
      if (_sosAlertsSubUid == null || (myEmail.isNotEmpty && _sosAlertsSubEmail == null)) {
        startSosAlertStreamListener();
      } else {
        _processIncomingSosAlerts(myUid, myEmail);
      }
    });
  }

  void _processIncomingSosAlerts(String myUid, String myEmail) {
    final List<Map<String, dynamic>> eligibleAlerts = [];
    final now = DateTime.now();

    for (final entry in _liveActiveAlerts.entries) {
      final alertId = entry.key;
      final data = entry.value['data'] as Map<String, dynamic>;
      final doc = entry.value['doc'];

      final alertDate = sosAlertTimeIfEligible(
        alertId: alertId,
        data: data,
        myUid: myUid,
        myEmail: myEmail,
        dismissedRingKeys: _dismissedRingKeys,
        now: now,
      );
      if (alertDate == null) continue;

      eligibleAlerts.add({
        'alertId': alertId,
        'doc': doc,
        'data': data,
        'alertDate': alertDate,
      });
    }

    // Resolved / acknowledged / dismissed alerts: remove their banners from the shade
    final eligibleIds = eligibleAlerts.map((a) => a['alertId'] as String).toSet();
    for (final endedId in _bannerAlertIds.where((id) => !eligibleIds.contains(id)).toList()) {
      _bannerAlertIds.remove(endedId);
      unawaited(_localNotifications.cancel(_bannerIdFor(endedId)));
    }

    if (eligibleAlerts.isEmpty) {
      final ended = activeIncomingSosNotifier.value;
      if (ended != null) {
        activeIncomingSosNotifier.value = null;
        // The sender ended it (or it was answered/dismissed): silence that alert's siren only.
        unawaited(SirenService.instance.stopAlertSiren(ended['alertId']?.toString() ?? ''));
      }
      return;
    }

    // Deduplicate: Sort by alertDate descending so newest is first
    eligibleAlerts.sort((a, b) =>
        (b['alertDate'] as DateTime).compareTo(a['alertDate'] as DateTime));

    // Pick ONLY the single latest active alert
    final latest = eligibleAlerts.first;
    final latestAlertId = latest['alertId'] as String;
    final latestData = latest['data'] as Map<String, dynamic>;
    final latestDate = latest['alertDate'] as DateTime;
    final latestRingSeq = ringSeqOf(latestData['ringSeq']);
    final latestRingKey = sosRingKey(latestAlertId, latestRingSeq);

    // Count total active presses from this sender
    final senderId = (latestData['senderId'] ?? latestData['sender_uid'])?.toString();
    final totalPresses = eligibleAlerts.where((a) {
      final sid = (a['data']['senderId'] ?? a['data']['sender_uid'])?.toString();
      return sid == senderId;
    }).length;

    final alertPayload = {
      'type': 'SOS_ALERT',
      'alertId': latestAlertId,
      'senderUid': senderId ?? latestData['senderUid'] ?? latestData['sender_uid'] ?? '',
      'senderName': latestData['senderName'] ?? latestData['sender_name'] ?? 'Emergency Contact',
      'senderEmail': latestData['senderEmail'] ?? latestData['sender_email'] ?? '',
      'senderPhone': latestData['senderPhone'] ?? latestData['sender_phone'] ?? '',
      'address': latestData['location']?['address'] ?? latestData['address'] ?? 'Live GPS Location Available',
      'googleMapsUrl': latestData['google_maps_url'] ?? latestData['location']?['googleMapsUrl'] ?? '',
      'latitude': latestData['latitude']?.toString() ?? latestData['location']?['latitude']?.toString() ?? '',
      'longitude': latestData['longitude']?.toString() ?? latestData['location']?['longitude']?.toString() ?? '',
      'lat': (latestData['lat'] as num?)?.toDouble() ??
          (latestData['latitude'] as num?)?.toDouble() ??
          (latestData['location']?['latitude'] as num?)?.toDouble(),
      'lng': (latestData['lng'] as num?)?.toDouble() ??
          (latestData['longitude'] as num?)?.toDouble() ??
          (latestData['location']?['longitude'] as num?)?.toDouble(),
      'message': latestData['message'] ?? latestData['note'] ?? 'Emergency SOS Alert triggered!',
      'triggeredAt': latestDate.toIso8601String(),
      'alertDate': latestDate,
      'totalPresses': totalPresses,
      'isDuress': latestData['isDuress'] == true,
      'status': 'active',
      'batteryLevel': (latestData['batteryLevel'] as num?)?.toInt(),
      'liveLocation': latestData['liveLocation'],
      'ringSeq': latestRingSeq,
      'ringKey': latestRingKey,
      'isLive': isSosAlertLive(latestData, now),
      'origin': latestData['origin']?.toString() ?? '',
      'source': latestData['source']?.toString() ?? '',
    };

    // Update active incoming alert notifier for homepage & reactive UI. The heartbeat refreshes
    // it for live data; it can no longer reopen the dialog or re-ring (see below).
    activeIncomingSosNotifier.value = alertPayload;

    // Present and ring at most once per ring key
    if (!_shownRingKeys.contains(latestRingKey)) {
      // Mark all older alerts from this sender as processed so they don't trigger subsequently
      for (final a in eligibleAlerts) {
        _shownRingKeys.add(sosRingKey(a['alertId'] as String, (a['data'] as Map<String, dynamic>)['ringSeq']));
      }

      // Not live (pressed more than 30 minutes ago, e.g. this phone was offline): no dialog and
      // no siren. It stays on the home screen card and in the notification inbox.
      if (alertPayload['isLive'] != true) {
        debugPrint('[NotificationService] SOS $latestRingKey is older than ${sosLiveWindow.inMinutes} min; inbox only');
        return;
      }

      debugPrint('[NotificationService] 🚨 In-App SOS alert (latest of $totalPresses) detected for $myEmail from ${latestData['senderName']}!');

      // 1. Pop up intrusive fullscreen dialog (once per ring key, never with a siren of its own)
      _autoPresentSosDialog(alertPayload);

      // 2. Siren + heads-up banner, unless the native guardian service already rang for this ring
      unawaited(_ringIfUnclaimed(latestAlertId, latestRingKey, latestData, alertPayload));
    }
  }

  /// Plays the siren and posts the banner only if this listener is the first to claim [ringKey].
  /// While the app is not visible the native GuardianAlertService owns alerting (alarm-stream
  /// siren, full-screen notification), so the UI isolate stays quiet to avoid a double siren.
  /// This is the only Dart code that starts the siren for an incoming alert.
  Future<void> _ringIfUnclaimed(
    String alertId,
    String ringKey,
    Map<String, dynamic> latestData,
    Map<String, dynamic> alertPayload,
  ) async {
    final bool appVisible =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!appVisible && await GuardianAlertService.instance.isServiceRunning()) {
      debugPrint('[NotificationService] App in background; native guardian service handles alert $ringKey');
      return;
    }
    if (!await GuardianAlertService.instance.claimAlert(ringKey)) {
      debugPrint('[NotificationService] Alert $ringKey already rang via native guardian service');
      return;
    }

    debugPrint('[NotificationService] 🔔 Ringing alert $alertId (source: ${latestData['source']}, '
        'origin: ${latestData['origin']}, ringSeq: ${ringSeqOf(latestData['ringSeq'])})');
    final bool isAutomatic = latestData['origin'] == 'automatic';

    // Loud alarm-stream siren for 2 minutes; only the guardian or the sender can end it early.
    unawaited(SirenService.instance.startAlertSiren(alertId));
    _bannerAlertIds.add(alertId);
    _showLocalSosAlertBanner(
      title: '🚨 INCOMING SOS ALERT: ${latestData['senderName']}!',
      body: isAutomatic
          ? '${automaticAlertLabel(latestData['source'])}. Tap to view live location & incident command.'
          : '${latestData['senderName']} needs immediate help! Tap to view live location & incident command.',
      payload: alertPayload,
      notificationId: _bannerIdFor(alertId),
    );
  }

  /// Subscribes to incoming connection requests to notify the user in real time.
  void startGuardianRequestListener() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _requestsSubscription?.cancel();
    _requestsSubscription =
        ContactSyncService.instance.streamIncomingRequests().listen((requests) {
      for (final req in requests) {
        final docId = req['docId']?.toString() ?? '';
        if (docId.isNotEmpty && !_shownRequestIds.contains(docId)) {
          _shownRequestIds.add(docId);
          final senderName = req['senderName'] ?? req['sender_name'] ?? 'Someone';
          final senderEmail = req['senderEmail'] ?? req['sender_email'] ?? '';
          showGuardianRequestBanner(
            senderName: senderName.toString(),
            senderEmail: senderEmail.toString(),
          );
        }
      }
    }, onError: (err) {
      debugPrint('[NotificationService] Guardian request stream error: $err');
    });
  }

  /// Displays standard local notification banner when app is in foreground
  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'sos_emergency_channel_v2',
      'SOS Emergency Alerts',
      channelDescription: 'High-priority notifications',
      importance: Importance.max,
      priority: Priority.high,
      color: Color(0xFF5A4FCF),
    );

    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

    await _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      platformDetails,
      payload: message.data['type'],
    );
  }

  /// Displays high-priority heads-up local alert banner for active SOS emergencies with siren sound
  Future<void> _showLocalSosAlertBanner({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
    int? notificationId,
  }) async {
    final Int64List vibrationPattern = Int64List.fromList([0, 1000, 500, 1000, 500, 1000]);

    const List<AndroidNotificationAction> actions = <AndroidNotificationAction>[
      AndroidNotificationAction(
        'action_call',
        'Call',
        showsUserInterface: true,
      ),
      AndroidNotificationAction(
        'action_view_map',
        'View Map',
        showsUserInterface: true,
      ),
    ];

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'sos_emergency_channel_v2',
      'SOS Emergency Alerts',
      channelDescription: 'High-priority emergency alerts triggered by mutual contacts.',
      importance: Importance.max,
      priority: Priority.max,
      sound: const RawResourceAndroidNotificationSound('siren'),
      playSound: true,
      enableVibration: true,
      vibrationPattern: vibrationPattern,
      color: const Color(0xFFFF3B30),
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      ticker: 'EMERGENCY SOS ALERT',
      actions: actions,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'siren.mp3',
      categoryIdentifier: 'sos_emergency_category',
      interruptionLevel: InterruptionLevel.critical,
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final Map<String, dynamic> serializablePayload = {
      'type': 'SOS_ALERT',
      'alertId': payload['alertId']?.toString() ?? '',
      'senderUid': payload['senderUid']?.toString() ?? '',
      'senderName': payload['senderName']?.toString() ?? '',
      'senderEmail': payload['senderEmail']?.toString() ?? '',
      'senderPhone': payload['senderPhone']?.toString() ?? '',
      'latitude': payload['latitude']?.toString() ?? payload['lat']?.toString() ?? '',
      'longitude': payload['longitude']?.toString() ?? payload['lng']?.toString() ?? '',
      'lat': (payload['lat'] as num?)?.toDouble() ?? double.tryParse(payload['latitude']?.toString() ?? ''),
      'lng': (payload['lng'] as num?)?.toDouble() ?? double.tryParse(payload['longitude']?.toString() ?? ''),
      'address': payload['address']?.toString() ?? '',
      'batteryLevel': (payload['batteryLevel'] as num?)?.toInt(),
      'message': payload['message']?.toString() ?? '',
    };
    final String encodedPayload = jsonEncode(serializablePayload);

    await _localNotifications.show(
      notificationId ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      platformDetails,
      payload: encodedPayload,
    );
  }

  /// Displays high-priority heads-up local alert banner for incoming guardian connection request
  Future<void> showGuardianRequestBanner({
    required String senderName,
    required String senderEmail,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'sos_emergency_channel_v2',
      'SOS Emergency Alerts',
      channelDescription: 'Emergency guardian connection requests.',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      color: Color(0xFF5A4FCF),
    );

    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      '📩 Guardian Connection Request',
      '$senderName ($senderEmail) wants to add you as an emergency guardian. Tap to review.',
      platformDetails,
      payload: 'GUARDIAN_REQUEST',
    );
  }

  /// Displays the full-featured Intrusive SOS Dialog overlay with multi-attempt context polling
  void _showIntrusiveSosDialog(Map<String, dynamic> data) {
    int attempts = 0;
    void tryDisplay() {
      final context = _navigatorKey?.currentContext;
      if (context != null && context.mounted) {
        _displayDialog(context, data);
      } else if (attempts < 15) {
        attempts++;
        Future.delayed(const Duration(milliseconds: 300), tryDisplay);
      } else {
        debugPrint('[NotificationService] Navigator context unavailable after 15 attempts.');
      }
    }
    tryDisplay();
  }

  /// Displays the full-featured Intrusive SOS Dialog overlay if there is an active incoming alert
  /// that has not been dismissed. Can be called when [HomeScreen] mounts or returns to foreground.
  ///
  /// Without [userRequested] the dialog opens at most once per ring key on this device; the
  /// "View Details" button and a tap on the alert notification pass [userRequested] = true.
  void showActiveSosDialogIfAvailable(BuildContext context, {bool userRequested = false}) {
    final alert = activeIncomingSosNotifier.value;
    if (alert == null || _isSosDialogShowing) return;
    final ringKey = alert['ringKey'] as String? ?? '';
    if (_dismissedRingKeys.contains(ringKey)) return;
    if (!userRequested && _presentedRingKeys.contains(ringKey)) return;
    // Only live alerts open full screen on their own; older ones wait in the inbox.
    if (!userRequested && alert['isLive'] != true) return;
    _markPresented(ringKey);
    _displayDialog(context, alert);
  }

  /// Opens the dialog for [data] on its own, unless this ring key was already presented or
  /// dismissed on this device.
  void _autoPresentSosDialog(Map<String, dynamic> data) {
    final ringKey = data['ringKey'] as String? ?? '';
    if (_dismissedRingKeys.contains(ringKey) || _presentedRingKeys.contains(ringKey)) return;
    _markPresented(ringKey);
    _showIntrusiveSosDialog(data);
  }

  /// The guardian tapped (or a full-screen launch opened) the native alert notification for
  /// [alertId]: show the alert dialog silently once the alert and a navigator are available.
  void _openAlertFromNotification(String alertId) {
    int attempts = 0;
    void tryOpen() {
      final context = _navigatorKey?.currentContext;
      final alert = activeIncomingSosNotifier.value;
      if (context != null && context.mounted && alert != null && alert['alertId'] == alertId) {
        showActiveSosDialogIfAvailable(context, userRequested: true);
      } else if (attempts < 20) {
        attempts++;
        Future.delayed(const Duration(milliseconds: 500), tryOpen);
      } else {
        debugPrint('[NotificationService] Opened alert $alertId is no longer active here');
      }
    }
    tryOpen();
  }

  void _displayDialog(BuildContext context, Map<String, dynamic> data) {
    if (_isSosDialogShowing) {
      try {
        Navigator.of(context, rootNavigator: true).pop();
      } catch (_) {}
    }

    _isSosDialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => IntrusiveSosDialog(
        data: data,
        // The dialog's own buttons (guardian actions) stop the siren. Closing it because a newer
        // alert replaces it must not: that would cut the new alert's siren short.
        onDismissed: () {
          _isSosDialogShowing = false;
        },
      ),
    ).then((_) {
      _isSosDialogShowing = false;
    });
  }

  /// Synchronizes device FCM token into the authenticated user's Firestore document.
  Future<void> syncTokenToFirestore(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final email = (user.email ?? '').toLowerCase().trim();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'userId': user.uid,
        'fcmToken': token,
        'fcm_token': token,
        'email': email,
        'displayName': user.displayName ?? '',
        'name': user.displayName ?? '',
        'lastActiveAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      debugPrint('[FCM] Token synchronized to users/${user.uid} ($email)');
    } catch (e) {
      debugPrint('[FCM] Token sync to Firestore error: $e');
    }
  }

  /// Notification ID reserved for Safe Journey Dead-Man's safety check
  static const int safetyCheckNotificationId = 999;

  /// Shows a high-priority safety check local notification with sound and vibration
  Future<void> showSafetyCheckNotification({
    required int secondsRemaining,
    required String reason,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'safety_check_channel',
      'Safe Journey Safety Checks',
      channelDescription: 'High-priority check-in prompts before auto-dispatching emergency SOS.',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      ticker: 'Safety Check Alert',
      ongoing: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _localNotifications.show(
      safetyCheckNotificationId,
      '🚨 Safety Check Required ($secondsRemaining s)',
      'Are you safe? ($reason). Tap to confirm or SOS will trigger automatically.',
      details,
      payload: 'safety_check',
    );
  }

  /// Cancels the safety check local notification
  Future<void> cancelSafetyCheckNotification() async {
    await _localNotifications.cancel(safetyCheckNotificationId);
  }

  /// Shows a generic status local notification
  Future<void> showStatusNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'sos_emergency_channel',
      'SOS Emergency Alerts',
      channelDescription: 'Emergency status notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _localNotifications.show(id, title, body, details);
  }

  /// Displays high-priority heads-up notification for ride check-in events
  Future<void> showRideCheckinNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'ride_safety_alerts_channel_v2',
      'Ride Safety Alerts',
      channelDescription: 'High-priority alerts when contacts start, update, or complete a ride.',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 400, 200, 400]),
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFF5A4FCF),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    final notifId = (title.hashCode.abs() % 100000) + 8000;
    await _localNotifications.show(notifId, title, body, details, payload: payload);
  }

  /// Listens to Safe Journeys (and Followed Mode sessions) that list this user as a guardian.
  ///
  /// On Android the native GuardianAlertService watches the same journeys while the app is
  /// closed; both claim each update through [GuardianAlertService.claimAlert], so it is shown once.
  void startGuardianJourneyListener() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final myUid = user.uid;
    final myEmail = (user.email ?? '').toLowerCase().trim();
    final journeys = FirebaseFirestore.instance.collection('journeys');

    _guardianJourneyDocs.clear();
    _guardianJourneyClock?.cancel();
    _guardianJourneyClock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_guardianJourneyDocs.values.any((docs) => docs.isNotEmpty)) {
        _refreshIncomingActiveJourneys(myUid);
      }
    });
    _journeySubUid?.cancel();
    _journeySubUid = journeys.where('guardianUids', arrayContains: myUid).snapshots().listen(
          (snap) => _processGuardianJourneys(snap, myUid, source: 'uid'),
          onError: (err) => debugPrint('[NotificationService] Journey UID stream error: $err'),
        );

    _journeySubEmail?.cancel();
    _journeySubEmail = null;
    if (myEmail.isNotEmpty) {
      _journeySubEmail = journeys.where('guardianEmails', arrayContains: myEmail).snapshots().listen(
            (snap) => _processGuardianJourneys(snap, myUid, source: 'email'),
            onError: (err) => debugPrint('[NotificationService] Journey email stream error: $err'),
          );
    }
  }

  Future<void> _processGuardianJourneys(
    QuerySnapshot<Map<String, dynamic>> snap,
    String myUid, {
    required String source,
  }) async {
    // The home-screen list may use cached data too: better a slightly old card than none.
    _guardianJourneyDocs[source] = {for (final d in snap.docs) d.id: d.data()};
    _refreshIncomingActiveJourneys(myUid);

    // Cached results may be stale (cold start, offline); only notify on server data.
    if (snap.metadata.isFromCache) return;
    final now = DateTime.now();
    for (final doc in snap.docs) {
      final event = journeyGuardianEvent(journeyId: doc.id, data: doc.data(), myUid: myUid, now: now);
      if (event == null || !_notifiedJourneyKeys.add(event.key)) continue;
      if (!await GuardianAlertService.instance.claimAlert(event.key)) continue;
      await _showJourneyNotification(doc.id, event);
    }
  }

  /// Rebuilds [incomingActiveJourneysNotifier] from both guardian streams: journeys needing
  /// attention (alert, followed mode) first, then the most recently started.
  void _refreshIncomingActiveJourneys(String myUid) {
    final merged = <String, Map<String, dynamic>>{
      ...?_guardianJourneyDocs['uid'],
      ...?_guardianJourneyDocs['email'],
    };
    incomingActiveJourneysNotifier.value = activeGuardianJourneys(merged, myUid: myUid, now: DateTime.now());
  }

  /// Journeys in [docs] (id -> data) that [myUid] should see as live on the home screen.
  @visibleForTesting
  static List<JourneyModel> activeGuardianJourneys(
    Map<String, Map<String, dynamic>> docs, {
    required String myUid,
    required DateTime now,
  }) {
    final journeys = <JourneyModel>[];
    for (final e in docs.entries) {
      if (!isJourneyLiveForGuardian(data: e.value, myUid: myUid, now: now)) continue;
      try {
        journeys.add(JourneyModel.fromMap(e.value, e.key));
      } catch (err) {
        debugPrint('[NotificationService] Skipping malformed journey ${e.key}: $err');
      }
    }
    int urgency(JourneyModel j) => j.status == JourneyStatus.alert ? 0 : (j.isFollowedMode ? 1 : 2);
    journeys.sort((a, b) {
      final byUrgency = urgency(a).compareTo(urgency(b));
      return byUrgency != 0 ? byUrgency : b.startedAt.compareTo(a.startedAt);
    });
    return journeys;
  }

  Future<void> _showJourneyNotification(String journeyId, JourneyGuardianEvent event) async {
    final androidDetails = AndroidNotificationDetails(
      'journey_guardian_alerts_channel',
      'Safe Journey Alerts',
      channelDescription: 'When people you protect start, finish or need help on a Safe Journey.',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 400, 200, 400]),
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFF5A4FCF),
      styleInformation: BigTextStyleInformation(event.body),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    try {
      await _localNotifications.show(
        // One notification per journey: "arrived" replaces "started".
        300000 + (journeyId.hashCode & 0xFFFF),
        event.title,
        event.body,
        NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: jsonEncode({'type': 'journey', 'journeyId': journeyId}),
      );
    } catch (e) {
      debugPrint('[NotificationService] Could not show Safe Journey notification: $e');
    }
  }

  /// Listens to ride_checkins collection where current user is a trusted guardian
  void startGuardianRideCheckinListener() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final myUid = user.uid;
    final myEmail = (user.email ?? '').toLowerCase().trim();

    _rideCheckinSubUid?.cancel();
    _rideCheckinSubUid = FirebaseFirestore.instance
        .collection('ride_checkins')
        .where('guardianIds', arrayContains: myUid)
        .snapshots()
        .listen(
          (snap) => _processIncomingRideCheckins(snap.docs, myUid),
          onError: (err) => debugPrint('[NotificationService] Ride UID stream error: $err'),
        );

    if (myEmail.isNotEmpty) {
      _rideCheckinSubEmail?.cancel();
      _rideCheckinSubEmail = FirebaseFirestore.instance
          .collection('ride_checkins')
          .where('guardianEmails', arrayContains: myEmail)
          .snapshots()
          .listen(
            (snap) => _processIncomingRideCheckins(snap.docs, myUid),
            onError: (err) => debugPrint('[NotificationService] Ride email stream error: $err'),
          );
    }
  }

  void _processIncomingRideCheckins(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String myUid,
  ) {
    final List<RideCheckinModel> activeRides = [];
    final now = DateTime.now();

    for (final doc in docs) {
      final data = doc.data();
      final rideId = doc.id;
      final senderId = data['userId']?.toString();
      if (senderId == myUid) continue; // Skip sender on their own device

      final status = (data['status'] ?? '').toString().toLowerCase();
      final travelerName = data['userName'] ?? 'Traveler';
      final rideType = data['rideType'] ?? 'Ride';
      final plate = data['plateFormatted'] ?? 'Vehicle Plate';

      DateTime? eventTime;
      final rawTime = data['lastUpdatedAt'] ?? data['createdAt'];
      if (rawTime is Timestamp) {
        eventTime = rawTime.toDate();
      } else if (rawTime is String) {
        eventTime = DateTime.tryParse(rawTime);
      }

      if (status == 'active') {
        try {
          activeRides.add(RideCheckinModel.fromMap(data, rideId));
        } catch (_) {}
      }

      // Do not notify for stale non-active rides (older than 20 minutes)
      if (status != 'active' && eventTime != null && now.difference(eventTime).inMinutes > 20) {
        continue;
      }

      // 1. New active ride
      final activeKey = '${rideId}_active';
      if (status == 'active' && !_notifiedRideKeys.contains(activeKey)) {
        _notifiedRideKeys.add(activeKey);
        showRideCheckinNotification(
          title: '🚗 $travelerName started a $rideType ride — $plate',
          body: 'Vehicle: $plate. Tap to view live location & driver details.',
          payload: jsonEncode({'type': 'ride_checkin', 'rideId': rideId}),
        );
        _showInAppRideAlert(
          rideId: rideId,
          travelerName: travelerName,
          rideType: rideType,
          plate: plate,
          status: status,
        );
      }

      // 2. Arrived safely
      final arrivedKey = '${rideId}_arrived';
      if (status == 'arrived' && !_notifiedRideKeys.contains(arrivedKey)) {
        _notifiedRideKeys.add(arrivedKey);
        showRideCheckinNotification(
          title: '✅ $travelerName arrived safely.',
          body: 'The ride in vehicle $plate has completed safely.',
          payload: jsonEncode({'type': 'ride_checkin', 'rideId': rideId}),
        );
        _showInAppRideAlert(
          rideId: rideId,
          travelerName: travelerName,
          rideType: rideType,
          plate: plate,
          status: status,
        );
      }

      // 3. Overdue
      final overdueKey = '${rideId}_overdue';
      if (status == 'overdue' && !_notifiedRideKeys.contains(overdueKey)) {
        _notifiedRideKeys.add(overdueKey);
        showRideCheckinNotification(
          title: '⚠️ Ride Overdue: $travelerName',
          body: 'Ride in vehicle $plate is overdue by 10+ minutes.',
          payload: jsonEncode({'type': 'ride_checkin', 'rideId': rideId}),
        );
        _showInAppRideAlert(
          rideId: rideId,
          travelerName: travelerName,
          rideType: rideType,
          plate: plate,
          status: status,
        );
      }
    }

    incomingActiveRidesNotifier.value = activeRides;
  }

  void _showInAppRideAlert({
    required String rideId,
    required String travelerName,
    required String rideType,
    required String plate,
    required String status,
  }) {
    final context = _navigatorKey?.currentContext;
    if (context == null || !context.mounted) return;

    if (status == 'active') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1E1B4B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFF4338CA),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.local_taxi_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🚗 $travelerName started a ride',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '$rideType • $plate',
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        color: Colors.white70,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'TRACK LIVE',
            textColor: const Color(0xFF38BDF8),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RideDetailsScreen(rideId: rideId),
                ),
              );
            },
          ),
        ),
      );
    } else if (status == 'arrived') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF065F46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFF059669),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '✅ $travelerName arrived safely',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Ride in $plate completed safely',
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'VIEW',
            textColor: Colors.white,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RideDetailsScreen(rideId: rideId),
                ),
              );
            },
          ),
        ),
      );
    }
  }
}
