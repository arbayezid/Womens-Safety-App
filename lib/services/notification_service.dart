import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';
import '../widgets/intrusive_sos_dialog.dart';
import 'activity_service.dart';
import 'contact_sync_service.dart';

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
  final Map<String, Map<String, dynamic>> _liveActiveAlerts = {};
  final Set<String> _shownAlertIds = {};
  final Set<String> _dismissedAlertIds = {};
  bool _isSosDialogShowing = false;

  StreamSubscription<List<Map<String, dynamic>>>? _requestsSubscription;
  final Set<String> _shownRequestIds = {};

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
        const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );
        const InitializationSettings initSettings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );

        await _localNotifications.initialize(
          initSettings,
          onDidReceiveNotificationResponse: (NotificationResponse response) {
            debugPrint('[LocalNotification] Clicked notification: ${response.payload}');
          },
        );

        // Create high-importance Android Notification Channel for SOS
        const AndroidNotificationChannel sosChannel = AndroidNotificationChannel(
          'sos_emergency_channel',
          'SOS Emergency Alerts',
          description: 'High-priority emergency alerts triggered by mutual contacts.',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
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

        final androidPlugin = _localNotifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          await androidPlugin.createNotificationChannel(sosChannel);
          await androidPlugin.createNotificationChannel(safetyCheckChannel);
        }
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
            _showIntrusiveSosDialog(message.data);
          }
        } else {
          _showLocalNotification(message);
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[FCM App Opened] Message clicked: ${message.data}');
        if (message.data['type'] == 'SOS_ALERT') {
          _showIntrusiveSosDialog(message.data);
        }
      });

      _fcm.onTokenRefresh.listen(syncTokenToFirestore);

      // 4. Obtain and synchronize device FCM Token safely with timeout
      try {
        final token = await _fcm.getToken().timeout(
          const Duration(seconds: 6),
          onTimeout: () {
            debugPrint('[FCM] getToken() timed out after 6s. Continuing.');
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

      // Listen for auth state changes to dynamically re-attach listeners and sync token
      FirebaseAuth.instance.authStateChanges().listen((user) async {
        if (user != null) {
          startSosAlertStreamListener();
          startGuardianRequestListener();
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

    // 2. Mark acknowledged in Firestore sos_alerts doc
    try {
      if (Firebase.apps.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await FirebaseFirestore.instance.collection('sos_alerts').doc(alertId).set({
            'dismissedBy': FieldValue.arrayUnion([user.uid]),
            'acknowledgedBy': FieldValue.arrayUnion([user.uid]),
            'lastRespondedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }
    } catch (e) {
      debugPrint('[NotificationService] Error updating alert dismissed status in Firestore: $e');
    }

    // 3. Log acknowledgement in local activity history
    try {
      ActivityService.instance.logQuickAction('Responded to SOS Alert');
    } catch (_) {}
  }

  /// Subscribes to real-time Cloud Firestore `sos_alerts` collection to receive
  /// instant in-app alerts directly, without requiring deployed Cloud Functions.
  ///
  /// Deduplicates multiple SOS button presses from the same sender and shows
  /// ONLY the single latest alert with timing, and never re-shows dismissed alerts.
  void _cancelSosAlertsSubscriptions() {
    _sosAlertsSubscription?.cancel();
    _sosAlertsSubscription = null;
    _sosAlertsSubUid?.cancel();
    _sosAlertsSubUid = null;
    _sosAlertsSubEmail?.cancel();
    _sosAlertsSubEmail = null;
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

    // 1. Rule-compatible query: recipientUids arrayContains myUid
    _sosAlertsSubUid = FirebaseFirestore.instance
        .collection('sos_alerts')
        .where('recipientUids', arrayContains: myUid)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen(
          (snap) => handleAlertSnapshot('uid', snap),
          onError: (err) => debugPrint('[NotificationService] SOS UID stream error: $err'),
        );

    // 2. Rule-compatible query: recipientEmails arrayContains myEmail
    if (myEmail.isNotEmpty) {
      _sosAlertsSubEmail = FirebaseFirestore.instance
          .collection('sos_alerts')
          .where('recipientEmails', arrayContains: myEmail)
          .where('status', isEqualTo: 'active')
          .snapshots()
          .listen(
            (snap) => handleAlertSnapshot('email', snap),
            onError: (err) => debugPrint('[NotificationService] SOS Email stream error: $err'),
          );
    }
  }

  void _processIncomingSosAlerts(String myUid, String myEmail) {
    final List<Map<String, dynamic>> eligibleAlerts = [];

    for (final entry in _liveActiveAlerts.entries) {
      final alertId = entry.key;
      final data = entry.value['data'] as Map<String, dynamic>;
      final doc = entry.value['doc'];

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

      // Check timestamp: ignore stale alerts older than 60 minutes
      final dynamic rawTime = data['triggeredAt'] ?? data['timestamp'];
      DateTime alertDate = DateTime.now();
      if (rawTime is Timestamp) {
        alertDate = rawTime.toDate();
        if (DateTime.now().difference(alertDate).inMinutes > 60) {
          continue;
        }
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

    if (eligibleAlerts.isEmpty) return;

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

    // Only present if this latest alert hasn't already been displayed
    if (!_shownAlertIds.contains(latestAlertId)) {
      // Mark all older alerts from this sender as processed so they don't trigger subsequently
      for (final a in eligibleAlerts) {
        _shownAlertIds.add(a['alertId'] as String);
      }

      debugPrint('[NotificationService] 🚨 In-App SOS alert (latest of $totalPresses) detected for $myEmail from ${latestData['senderName']}!');

      final alertPayload = {
        'type': 'SOS_ALERT',
        'alertId': latestAlertId,
        'senderName': latestData['senderName'] ?? latestData['sender_name'] ?? 'Emergency Contact',
        'senderEmail': latestData['senderEmail'] ?? latestData['sender_email'] ?? '',
        'senderPhone': latestData['senderPhone'] ?? latestData['sender_phone'] ?? '',
        'address': latestData['location']?['address'] ?? latestData['address'] ?? 'Live GPS Location Available',
        'googleMapsUrl': latestData['google_maps_url'] ?? latestData['location']?['googleMapsUrl'] ?? '',
        'latitude': latestData['latitude']?.toString() ?? latestData['location']?['latitude']?.toString() ?? '',
        'longitude': latestData['longitude']?.toString() ?? latestData['location']?['longitude']?.toString() ?? '',
        'message': latestData['message'] ?? latestData['note'] ?? 'Emergency SOS Alert triggered!',
        'triggeredAt': latestDate.toIso8601String(),
        'alertDate': latestDate,
        'totalPresses': totalPresses,
      };

      // 1. Pop up intrusive fullscreen dialog
      _showIntrusiveSosDialog(alertPayload);

      // 2. Show local heads-up notification banner with sound
      _showLocalSosAlertBanner(
        title: '🚨 INCOMING SOS ALERT: ${latestData['senderName']}!',
        body: '${latestData['senderName']} needs immediate help! Tap to view live location.',
        payload: alertPayload,
      );
    }
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
      'sos_emergency_channel',
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

  /// Displays high-priority heads-up local alert banner for active SOS emergencies
  Future<void> _showLocalSosAlertBanner({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'sos_emergency_channel',
      'SOS Emergency Alerts',
      channelDescription: 'High-priority emergency alerts triggered by mutual contacts.',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      color: Color(0xFFFF3B30),
      fullScreenIntent: true,
    );

    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      platformDetails,
      payload: payload['type'],
    );
  }

  /// Displays high-priority heads-up local alert banner for incoming guardian connection request
  Future<void> showGuardianRequestBanner({
    required String senderName,
    required String senderEmail,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'sos_emergency_channel',
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

  /// Displays the full-featured Intrusive SOS Dialog overlay without stacking multiple dialogs
  void _showIntrusiveSosDialog(Map<String, dynamic> data) {
    final context = _navigatorKey?.currentContext;
    if (context == null) {
      debugPrint('[NotificationService] Navigator context temporarily unavailable, retrying in 500ms...');
      Future.delayed(const Duration(milliseconds: 500), () {
        final retryContext = _navigatorKey?.currentContext;
        if (retryContext != null && retryContext.mounted) {
          _displayDialog(retryContext, data);
        }
      });
      return;
    }

    _displayDialog(context, data);
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
}
