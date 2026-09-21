import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../firebase_options.dart';
import '../widgets/intrusive_sos_dialog.dart';
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

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  GlobalKey<NavigatorState>? _navigatorKey;
  bool _isInitialized = false;

  StreamSubscription<QuerySnapshot>? _sosAlertsSubscription;
  final Set<String> _shownAlertIds = {};

  StreamSubscription<List<Map<String, dynamic>>>? _requestsSubscription;
  final Set<String> _shownRequestIds = {};

  /// Initializes notification channels, permissions, FCM listeners, and real-time Firestore streams.
  Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    if (_isInitialized) return;
    _navigatorKey = navigatorKey;

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

        final androidPlugin = _localNotifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          await androidPlugin.createNotificationChannel(sosChannel);
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
          _sosAlertsSubscription?.cancel();
          _requestsSubscription?.cancel();
        }
      });

      _isInitialized = true;
    } catch (e) {
      debugPrint('[NotificationService] Initialization error: $e');
    }
  }

  /// Subscribes to real-time Cloud Firestore `sos_alerts` collection to receive
  /// instant in-app alerts directly, without requiring deployed Cloud Functions.
  void startSosAlertStreamListener() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('[NotificationService] Skipping SOS stream listener: user is unauthenticated.');
      return;
    }

    final String myEmail = (user.email ?? '').toLowerCase().trim();
    final String myUid = user.uid;

    _sosAlertsSubscription?.cancel();
    debugPrint('[NotificationService] 🛡️ Starting real-time Firestore SOS stream for $myEmail (UID: $myUid)...');

    _sosAlertsSubscription = FirebaseFirestore.instance
        .collection('sos_alerts')
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final doc = change.doc;
          final data = doc.data();
          if (data == null) continue;

          final senderId = (data['senderId'] ?? data['sender_uid'])?.toString();
          if (senderId == myUid) {
            // Do not alert the sender on their own device
            continue;
          }

          final alertId = doc.id;
          if (_shownAlertIds.contains(alertId)) {
            continue;
          }

          // Check timestamp: ignore stale alerts older than 60 minutes
          final dynamic rawTime = data['triggeredAt'] ?? data['timestamp'];
          if (rawTime is Timestamp) {
            final alertDate = rawTime.toDate();
            if (DateTime.now().difference(alertDate).inMinutes > 60) {
              continue;
            }
          }

          // Check if current user is an intended recipient:
          final List<dynamic> recEmails = (data['recipientEmails'] as List<dynamic>?) ?? [];
          final List<dynamic> recUids = (data['recipientUids'] as List<dynamic>?) ?? [];

          final bool matchesEmail = myEmail.isNotEmpty &&
              recEmails.map((e) => e.toString().toLowerCase().trim()).contains(myEmail);
          final bool matchesUid = recUids.map((u) => u.toString()).contains(myUid);

          // Alert if recipient matches, or if broadcast list is open (e.g. initial testing)
          final bool isRecipient = matchesEmail || matchesUid || (recEmails.isEmpty && recUids.isEmpty);

          if (isRecipient) {
            _shownAlertIds.add(alertId);
            debugPrint('[NotificationService] 🚨 In-App SOS alert detected for $myEmail from ${data['senderName']}!');

            final alertPayload = {
              'type': 'SOS_ALERT',
              'alertId': alertId,
              'senderName': data['senderName'] ?? data['sender_name'] ?? 'Emergency Contact',
              'senderEmail': data['senderEmail'] ?? data['sender_email'] ?? '',
              'senderPhone': data['senderPhone'] ?? data['sender_phone'] ?? '',
              'address': data['location']?['address'] ?? data['address'] ?? 'Live GPS Location Available',
              'googleMapsUrl': data['google_maps_url'] ?? data['location']?['googleMapsUrl'] ?? '',
              'latitude': data['latitude']?.toString() ?? data['location']?['latitude']?.toString() ?? '',
              'longitude': data['longitude']?.toString() ?? data['location']?['longitude']?.toString() ?? '',
              'message': data['message'] ?? data['note'] ?? 'Emergency SOS Alert triggered!',
            };

            // 1. Pop up intrusive fullscreen dialog
            _showIntrusiveSosDialog(alertPayload);

            // 2. Show local heads-up notification banner with sound
            _showLocalSosAlertBanner(
              title: '🚨 INCOMING SOS ALERT: ${data['senderName']}!',
              body: '${data['senderName']} needs immediate help! Tap to view live location.',
              payload: alertPayload,
            );
          }
        }
      }
    }, onError: (err) {
      debugPrint('[NotificationService] Real-time SOS stream error: $err');
    });
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

  /// Displays the full-featured Intrusive SOS Dialog overlay
  void _showIntrusiveSosDialog(Map<String, dynamic> data) {
    final context = _navigatorKey?.currentContext;
    if (context == null) {
      debugPrint('[NotificationService] Navigator context temporarily unavailable, retrying in 500ms...');
      Future.delayed(const Duration(milliseconds: 500), () {
        final retryContext = _navigatorKey?.currentContext;
        if (retryContext != null && retryContext.mounted) {
          showDialog(
            context: retryContext,
            barrierDismissible: false,
            builder: (ctx) => IntrusiveSosDialog(data: data),
          );
        }
      });
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => IntrusiveSosDialog(data: data),
    );
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
}
