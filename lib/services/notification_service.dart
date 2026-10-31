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
import '../screens/ride_details_screen.dart';
import '../widgets/intrusive_sos_dialog.dart';
import 'activity_service.dart';
import 'contact_sync_service.dart';
import 'guardian_alert_service.dart';
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
  final Set<String> _shownAlertIds = {};
  final Set<String> _dismissedAlertIds = {};
  bool _isSosDialogShowing = false;

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

  /// Initializes notification channels, permissions, FCM listeners, and real-time Firestore streams.
  Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    if (_isInitialized) return;
    _navigatorKey = navigatorKey;
    await _loadDismissedAlertIds();

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
            // Stop siren immediately when notification is tapped
            SirenService.instance.stopSiren();

            Map<String, dynamic>? parsedPayload;
            if (response.payload != null && response.payload!.isNotEmpty) {
              try {
                parsedPayload = jsonDecode(response.payload!) as Map<String, dynamic>?;
              } catch (_) {}
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

        // Standard Importance Android Notification Channel for Ride Safety Check-ins (Non-intrusive)
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
          final alertId = message.data['alertId']?.toString() ?? '';
          if (alertId.isEmpty || !_shownAlertIds.contains(alertId)) {
            if (alertId.isNotEmpty) _shownAlertIds.add(alertId);
            SirenService.instance.startSiren();
            _showIntrusiveSosDialog(message.data);
          }
        } else {
          _showLocalNotification(message);
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[FCM App Opened] Message clicked: ${message.data}');
        if (message.data['type'] == 'SOS_ALERT') {
          SirenService.instance.startSiren();
          _showIntrusiveSosDialog(message.data);
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

      // Listen for auth state changes to dynamically re-attach listeners and sync token
      FirebaseAuth.instance.authStateChanges().listen((user) async {
        if (user != null) {
          startSosAlertStreamListener();
          startGuardianRequestListener();
          startGuardianRideCheckinListener();
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
      _dismissedAlertIds.addAll(saved);
      _shownAlertIds.addAll(saved);
    } catch (e) {
      debugPrint('[NotificationService] Error loading dismissed alerts: $e');
    }
  }

  /// Persistently marks an active SOS alert as dismissed/responded to by the current user.
  /// Prevents this alert from ever popping up again on this device or across app restarts.
  Future<void> dismissAlert(String alertId) async {
    _shownAlertIds.add(alertId);
    _dismissedAlertIds.add(alertId);
    SirenService.instance.stopSiren();

    if (activeIncomingSosNotifier.value?['alertId'] == alertId) {
      activeIncomingSosNotifier.value = null;
    }

    // 1. Persist locally to SharedPreferences so it never re-shows even across process kill
    try {
      final String? uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
      final key = uid != null ? 'dismissed_sos_alerts_$uid' : 'dismissed_sos_alerts_default';
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(key) ?? [];
      if (!list.contains(alertId)) {
        list.add(alertId);
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
  Future<void> acknowledgeAlert(String alertId) async {
    _shownAlertIds.add(alertId);
    _dismissedAlertIds.add(alertId);
    SirenService.instance.stopSiren();

    // 1. Persist locally to SharedPreferences
    try {
      final String? uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
      final key = uid != null ? 'dismissed_sos_alerts_$uid' : 'dismissed_sos_alerts_default';
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(key) ?? [];
      if (!list.contains(alertId)) {
        list.add(alertId);
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

    for (final entry in _liveActiveAlerts.entries) {
      final alertId = entry.key;
      final data = entry.value['data'] as Map<String, dynamic>;
      final doc = entry.value['doc'];

      // Only process actively running alerts
      final status = (data['status'] ?? '').toString().toLowerCase();
      if (status != 'active') {
        continue;
      }

      final senderId = (data['senderId'] ?? data['sender_uid'])?.toString();
      if (senderId == myUid) {
        // Do not alert the sender on their own device
        continue;
      }

      // Check if already dismissed locally
      if (_dismissedAlertIds.contains(alertId)) {
        continue;
      }

      // Check if dismissed in cloud by my UID
      final List<dynamic> dismissedBy = (data['dismissedBy'] as List<dynamic>?) ?? [];
      if (dismissedBy.map((e) => e.toString()).contains(myUid)) {
        _dismissedAlertIds.add(alertId);
        continue;
      }

      // Robust timestamp parsing (Timestamp, DateTime, int, or String)
      final dynamic rawTime = data['triggeredAt'] ?? data['timestamp'];
      DateTime alertDate = DateTime.now();
      if (rawTime is Timestamp) {
        alertDate = rawTime.toDate();
      } else if (rawTime is DateTime) {
        alertDate = rawTime;
      } else if (rawTime is int) {
        alertDate = DateTime.fromMillisecondsSinceEpoch(rawTime);
      } else if (rawTime is String) {
        final parsed = DateTime.tryParse(rawTime);
        if (parsed != null) {
          alertDate = parsed;
        } else {
          final ms = int.tryParse(rawTime);
          if (ms != null) {
            alertDate = DateTime.fromMillisecondsSinceEpoch(ms);
          }
        }
      }

      // Ignore stale alerts older than 3 hours
      if (DateTime.now().difference(alertDate).inHours.abs() > 3) {
        continue;
      }

      // Check if current user is an intended recipient
      final List<dynamic> recEmails = (data['recipientEmails'] as List<dynamic>?) ?? [];
      final List<dynamic> recUids = (data['recipientUids'] as List<dynamic>?) ?? [];

      final bool matchesEmail = myEmail.isNotEmpty &&
          recEmails.map((e) => e.toString().toLowerCase().trim()).contains(myEmail);
      final bool matchesUid = recUids.map((u) => u.toString()).contains(myUid);
      final bool isRecipient = matchesEmail || matchesUid;

      if (!isRecipient) continue;

      eligibleAlerts.add({
        'alertId': alertId,
        'doc': doc,
        'data': data,
        'alertDate': alertDate,
      });
    }

    if (eligibleAlerts.isEmpty) {
      if (activeIncomingSosNotifier.value != null) {
        activeIncomingSosNotifier.value = null;
        SirenService.instance.stopSiren();
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
    };

    // Update active incoming alert notifier for homepage & reactive UI
    activeIncomingSosNotifier.value = alertPayload;

    // Only present notification / modal once per unique active alert
    if (!_shownAlertIds.contains(latestAlertId)) {
      // Mark all older alerts from this sender as processed so they don't trigger subsequently
      for (final a in eligibleAlerts) {
        _shownAlertIds.add(a['alertId'] as String);
      }

      debugPrint('[NotificationService] 🚨 In-App SOS alert (latest of $totalPresses) detected for $myEmail from ${latestData['senderName']}!');

      // 1. Pop up intrusive fullscreen dialog
      _showIntrusiveSosDialog(alertPayload);

      // 2. Siren + heads-up banner, unless the native guardian service already rang for this alert
      unawaited(_ringIfUnclaimed(latestAlertId, latestData, alertPayload));
    }
  }

  /// Plays the siren and posts the banner only if this listener is the first to claim the alert.
  /// While the app is not visible the native GuardianAlertService owns alerting (alarm-stream
  /// siren, full-screen notification), so the UI isolate stays quiet to avoid a double siren.
  Future<void> _ringIfUnclaimed(
    String alertId,
    Map<String, dynamic> latestData,
    Map<String, dynamic> alertPayload,
  ) async {
    final bool appVisible =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!appVisible && await GuardianAlertService.instance.isServiceRunning()) {
      debugPrint('[NotificationService] App in background; native guardian service handles alert $alertId');
      return;
    }
    if (!await GuardianAlertService.instance.claimAlert(alertId)) {
      debugPrint('[NotificationService] Alert $alertId already ringing via native guardian service');
      return;
    }

    SirenService.instance.startSiren();
    _showLocalSosAlertBanner(
      title: '🚨 INCOMING SOS ALERT: ${latestData['senderName']}!',
      body: '${latestData['senderName']} needs immediate help! Tap to view live location & incident command.',
      payload: alertPayload,
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
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
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
  void showActiveSosDialogIfAvailable(BuildContext context) {
    final alert = activeIncomingSosNotifier.value;
    if (alert == null || _isSosDialogShowing) return;
    final alertId = alert['alertId']?.toString() ?? '';
    if (alertId.isNotEmpty && _dismissedAlertIds.contains(alertId)) return;
    _displayDialog(context, alert);
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
        onDismissed: () {
          _isSosDialogShowing = false;
          SirenService.instance.stopSiren();
        },
      ),
    ).then((_) {
      _isSosDialogShowing = false;
      SirenService.instance.stopSiren();
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

  /// Displays non-intrusive notification for ride check-in events
  Future<void> showRideCheckinNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'ride_checkin_channel',
      'Ride Safety Check-in',
      channelDescription: 'Non-intrusive notifications for vehicle plate updates and ride status.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    final notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _localNotifications.show(notifId, title, body, details, payload: payload);
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
    for (final doc in docs) {
      final data = doc.data();
      final rideId = doc.id;
      final senderId = data['userId']?.toString();
      if (senderId == myUid) continue; // Skip sender on their own device

      final status = (data['status'] ?? '').toString().toLowerCase();
      final travelerName = data['userName'] ?? 'Traveler';
      final rideType = data['rideType'] ?? 'Ride';
      final plate = data['plateFormatted'] ?? 'Vehicle Plate';

      // 1. New active ride
      final activeKey = '${rideId}_active';
      if (status == 'active' && !_notifiedRideKeys.contains(activeKey)) {
        _notifiedRideKeys.add(activeKey);
        showRideCheckinNotification(
          title: '$travelerName started a $rideType ride — $plate',
          body: 'Vehicle: $plate. Tap to view live location & driver details.',
          payload: jsonEncode({'type': 'ride_checkin', 'rideId': rideId}),
        );
      }

      // 2. Arrived safely
      final arrivedKey = '${rideId}_arrived';
      if (status == 'arrived' && !_notifiedRideKeys.contains(arrivedKey)) {
        _notifiedRideKeys.add(arrivedKey);
        showRideCheckinNotification(
          title: '$travelerName arrived safely.',
          body: 'The ride in vehicle $plate has completed safely.',
          payload: jsonEncode({'type': 'ride_checkin', 'rideId': rideId}),
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
      }
    }
  }
}
