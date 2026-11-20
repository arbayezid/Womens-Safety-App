# ১১. Defence প্রস্তুতি: সম্ভাব্য প্রশ্ন ও উত্তর

> প্রতিটি উত্তর বর্তমান code অনুযায়ী। Kotlin ফাইলের পূর্ণ path: `android/app/src/main/kotlin/com/smartsafety/smart_safety/`। উত্তরগুলো মুখে বলার মতো করে লেখা।

---

## ক. সাধারণ / ধারণাগত প্রশ্ন

**১. এই app কেন বানালেন?**
বাংলাদেশে বিপদের মুহূর্তে ফোন আনলক করে কাউকে কল করা সময়সাপেক্ষ, আর internet সবসময় থাকে না। Woman Guard-এ এক tap-এ নিজের SIM থেকে location সহ SMS যায় আর app-ব্যবহারকারী guardian-এর ফোনে siren বাজে। `EmergencyService.triggerEmergency()` এর কেন্দ্র (`lib/services/emergency_service.dart`)।

**২. App-এর মূল feature কী কী?**
One-tap SOS, guardian alert (siren + full-screen), live tracking, smart escalation, Safe Journey, Followed Mode, Ride Check-in with plate OCR, ESP32 pendant, shake ও fall detection, siren, fake call, duress PIN + camouflage calculator, safety map। পূর্ণ তালিকা `01_PROJECT_AND_TECH_STACK_BN.md` §১.৪।

**৩. আপনার app অন্যদের থেকে আলাদা কোথায়?**
(ক) Internet ছাড়া SOS — নিজের SIM, dual-SIM retry (`SmsSender.kt`); (খ) Duress PIN দিলে app calculator হয়ে যায় আর চুপচাপ SOS যায় (`PinSecurityService.triggerDuressPipeline()`); (গ) বাংলা BRTA number plate OCR (Tesseract `ben` + ML Kit + ঐচ্ছিক Gemini, `RideOcrService.recognizePlate()`); (ঘ) নিজের বানানো ESP32 pendant, app বন্ধ থাকলেও কাজ করে (`PendantLinkService.kt`); (ঙ) app বন্ধ থাকলেও timer চলে (`SafetyDeadlines.kt` exact alarm + headless Dart)।

**৪. Target user কে?**
সুরক্ষিত ব্যক্তি (যিনি SOS পাঠান) ও guardian (যিনি request accept করেন)। Link one-way: request পাঠানো ব্যক্তি protected, accept-কারী guardian (`ContactSyncService` class doc)।

**৫. Real-life impact কী?**
SOS যেহেতু সাধারণ SMS, তাই guardian-এর ফোনে app না থাকলেও বার্তা পৌঁছায়; SMS-এ ছোট Google Maps link থাকে (code comment: "opens on any phone (smartphone browser or Maps app)", `buildSmsMapsLink()`)। App-ব্যবহারকারী guardian live location ও siren পান। (নির্ভুলতা: impact মাঠপর্যায়ে মাপা হয়নি — এটা design-এর উদ্দেশ্য।)

**৬. Guest mode-এ কী করা যায়?**
Dashboard, map, settings দেখা যায়; কিন্তু SOS, Safe Journey, Being Followed, Ride Check-in চাপলে `AuthGuard.run()` login sheet দেখায় (`lib/utils/auth_guard.dart`)। Guest-এর cloud alert হয় না (`SosCloudDispatcher.triggerCloudSos()` user null হলে `null`)।

**৭. App কি পুলিশের সাথে সরাসরি যুক্ত?**
না। Incident Room ও SOS dialog-এ "Call 999" বোতাম আছে যা dialer খোলে (`incident_room_screen.dart`, `_callPhone('999')`); আর map-এ ৬৯টি police location (safe zone data) আছে। স্বয়ংক্রিয় পুলিশ-সংযোগ নেই।

**৮. আপনি একা developer — team-এ অন্যজনের ভূমিকা?**
(এটি code থেকে বলা যায় না; git log-এ ৫০টি commit সবই একজন author-এর নামে। নিজের উত্তর প্রস্তুত রাখুন।)

---

## খ. Flutter প্রশ্ন

**৯. StatelessWidget আর StatefulWidget-এর পার্থক্য? আপনার app-এ উদাহরণ?**
Stateless-এর নিজের পরিবর্তনশীল state নেই; Stateful-এর `State` object থাকে, `setState()` দিলে rebuild। উদাহরণ: `SmartSafetyApp` StatelessWidget (`lib/main.dart`); `HomeScreen` StatefulWidget — `_isSOSLoading` বদলাতে `setState` (`home_screen.dart`, line ~247)।

**১০. Widget lifecycle বলুন — আপনার code-এ কোথায় ব্যবহার করেছেন?**
`createState → initState → build → (didUpdateWidget) → dispose`। `HomeScreen.initState()`-এ service শুরু ও listener যোগ (`activeSafetyCheckNotifier.addListener`), `dispose()`-এ `removeListener` ও `_pulseController.dispose()` (`home_screen.dart`, line ~81-186)।

**১১. Future আর Stream-এর পার্থক্য?**
Future = একবার একটা ফল (যেমন `Geolocator.getCurrentPosition()`); Stream = সময়ের সাথে অনেকগুলো মান (যেমন `Geolocator.getPositionStream()` বা Firestore `snapshots()`)। Live tracking Stream দিয়ে (`live_tracking_service.dart`, line ~131), SOS-এর একবারের location Future দিয়ে।

**১২. async/await কেন? `unawaited` কেন ব্যবহার করেছেন?**
async কাজের (network, GPS) জন্য UI আটকে না রেখে অপেক্ষা। `unawaited()` দিয়ে ইচ্ছাকৃতভাবে অপেক্ষা না করে কাজ চালু রাখা — যেমন SOS-এ journey link করা (`emergency_service.dart`, line ~867), যাতে SMS দেরি না হয়।

**১৩. State management কোনটা ব্যবহার করেছেন? Provider/Bloc কেন নয়?**
কোনো state-management package নেই। Singleton service + `ValueNotifier`/`ValueListenableBuilder` + `ChangeNotifier` + `setState`। কারণ: অনেক state UI-র বাইরে (notification callback, headless engine, native channel) থেকে বদলায়; singleton service-এ সরাসরি পৌঁছানো যায়। উদাহরণ: camouflage পুরো app-এ `ValueListenableBuilder<bool>` (`lib/main.dart`, line ~177)।

**১৪. `runZonedGuarded` কেন?**
যে error কোনো try/catch ধরেনি সেগুলোও ধরে Crashlytics-এ পাঠাতে (`lib/main.dart`, `main()` line ~40, `_reportUncaughtError`)।

**১৫. `WidgetsBinding.instance.addPostFrameCallback` কেন?**
প্রথম frame আঁকার পরে ভারী কাজ (permission, BLE, notification init) — যাতে user সাদা screen না দেখে (`main.dart`, line ~106-110)।

**১৬. `IndexedStack` কেন?**
Bottom tab বদলালে Map/Contacts screen-এর state হারায় না (`home_screen.dart`, line ~720)।

**১৭. MethodChannel কী, কোথায় ব্যবহার করেছেন?**
Dart থেকে Android native (Kotlin) code ডাকার পথ। যেমন `com.smartsafety.smart_safety/sms` channel-এ `sendSms` (`native_sms_service.dart` → `AppChannels.kt`)। মোট ৬টি channel।

**১৮. `@pragma('vm:entry-point')` কেন?**
Release build-এ tree-shaking যাতে এই function মুছে না দেয়, কারণ native code নাম ধরে ডাকে — `safetyDeadlineBackgroundMain()` (`main.dart`, line ~45), `firebaseMessagingBackgroundHandler`, `notificationTapBackground`, background service-এর `onStart`।

**১৯. Headless Flutter engine কী?**
UI ছাড়া Dart চালানো। App বন্ধ থাকা অবস্থায় safety timer বা pendant SOS এলে `DeadlineDartRunner.kt` নতুন `FlutterEngine` তৈরি করে `safetyDeadlineBackgroundMain` চালায় — একই Dart SOS pipeline।

**২০. Theme কীভাবে?**
`AppTheme.lightTheme` (Material 3), Poppins font (`google_fonts`), রং `lib/core/app_colors.dart`।

**২১. Navigation কীভাবে করেছেন? named route?**
Named route নেই; `Navigator.push(MaterialPageRoute)`, `PageRouteBuilder`, `showModalBottomSheet`। Notification থেকে navigate করতে global `rootNavigatorKey`।

**২২. Test লিখেছেন?**
হ্যাঁ, `test/`-এ ৪২টি Dart test ফাইল (যেমন `shake_detector_test.dart`, `fall_detection_test.dart`, `sos_escalation_test.dart`) এবং ২টি Firestore rules test (`.mjs`)। Pure logic আলাদা class/static function-এ রাখা হয়েছে যাতে Firebase/device ছাড়াই test করা যায় — যেমন `ShakeDetector`, `FallDetectionEngine`, `LiveTrackingService.shouldWriteUpdate`, `SosPacketFilter` (কয়েকটিতে `@visibleForTesting` annotation)। `flutter analyze` → No issues found।

---

## গ. Firebase প্রশ্ন

**২৩. Firebase কেন?**
Auth, real-time database, offline cache একসাথে, free Spark plan, server লিখতে হয় না।

**২৪. Firestore আর Realtime Database-এর পার্থক্য? কোনটা নিলেন কেন?**
Firestore document/collection মডেল, শক্তিশালী query (`arrayContains`), ভালো security rules, offline persistence। এই app শুধু Firestore ব্যবহার করে (`cloud_firestore`); `arrayContains` query দিয়ে guardian alert খোঁজা হয় (`recipientUids`)।

**২৫. Authentication কীভাবে কাজ করে?**
`GoogleSignIn.signIn()` → token → `GoogleAuthProvider.credential()` → `FirebaseAuth.signInWithCredential()` → `users/{uid}` sync (`auth_service.dart`, line ~391-419)।

**২৬. Security rules ব্যাখ্যা করুন — SOS alert কে পড়তে পারে?**
শুধু sender বা recipient (`recipientUids`-এ uid বা `recipientEmails`-এ email)। Create-এ `status == 'active'`, `triggeredAt == request.time`, `expiresAt` ≤ ৩ ঘণ্টা; delete নিষিদ্ধ (`firestore.rules`, line ~162-277)।

**২৭. Guardian কি SOS-এর location বদলাতে পারে?**
না। Recipient শুধু `status` (শুধু `'resolved'`), `resolvedAt`, `dismissedBy`, `acknowledgedBy`, `acknowledgedAt`, `lastRespondedAt` বদলাতে পারে (line ~247-257)।

**২৮. কেউ কি ভুয়া সময় দিয়ে SOS বানাতে পারে?**
না — `triggeredAt == request.time` বাধ্যতামূলক, তাই client-কে `FieldValue.serverTimestamp()` দিতে হয় (line ~194)।

**২৯. Free plan-এর সীমা কীভাবে সামলেছেন?**
Location write throttle (৩০ সেকেন্ড/২৫ মিটার/১২০ সেকেন্ড heartbeat), FCM server-এর বদলে Firestore listener, on-device OCR, OSM map, report query limit ১০০। (দুর্বলতা: contact heartbeat ৪ সেকেন্ড — বেশি read।)

**৩০. Cloud Functions আছে, তাহলে ব্যবহার হয় না কেন?**
`functions/index.js` FCM push-এর জন্য লেখা, কিন্তু Cloud Functions-এর জন্য Blaze plan লাগে — code-এর comment-ই বলে "on Spark the app performs this write itself"। App এর উপর নির্ভর করে না; guardian alert আসে Firestore listener দিয়ে।

**৩১. Offline-এ Firestore write কী হয়?**
Firestore local cache-এ queue রাখে, online হলে পাঠায়। App ৩ সেকেন্ডের বেশি অপেক্ষা করে না (`sos_cloud_dispatcher.dart`, line ~277-279)।

**৩২. FCM token কোথায় রাখেন, কেন?**
`users/{uid}.fcmToken` ও `fcm_token` (`NotificationService.syncTokenToFirestore()`); Cloud Function থাকলে push পাঠাতে লাগত।

**৩৩. Composite index কেন লাগে?**
একাধিক field-এ filter/sort করলে। `firestore.indexes.json`-এ যেমন `sos_alerts`: `recipientUids (CONTAINS) + triggeredAt (DESC)`।

**৩৪. Firebase Storage কিসে?**
শুধু Ride Check-in-এর plate photo ও screenshot — `ride_checkins/$userId/$rideId/plate.jpg` (`RideCheckinService.uploadRideImage()`)। Storage rules repo-তে নেই।

**৩৫. Crashlytics কখন চালু?**
শুধু release/profile build-এ: `setCrashlyticsCollectionEnabled(!kDebugMode)` (`main.dart`, line ~83)।

---

## ঘ. Code-specific প্রশ্ন

**৩৬. SOS বোতামের code কোথায়?**
UI: `lib/screens/home_screen.dart` → `_SOSButton` (tap) → `_HomeScreenState._onSOSPressed()` → `_executeSOSPipeline()` → `EmergencyService.instance.triggerEmergency(source: 'SOS Button', origin: SosOrigin.manual)`।

**৩৭. SOS বোতাম কি long-press নাকি tap?**
একবার tap (`GestureDetector(onTap: widget.onPressed)`, line ~2347)। কোনো countdown নেই। তবে "I'm safe" দিতে ২ সেকেন্ড চেপে রাখতে হয় (`_HoldToConfirmButton.holdDuration`)।

**৩৮. Location কীভাবে নেওয়া হয়?**
`geolocator`: `isLocationServiceEnabled()` → `checkPermission()`/`requestPermission()` → `getCurrentPosition(accuracy: high, timeLimit: 5s)` → ব্যর্থ হলে medium ৩ সেকেন্ড → `getLastKnownPosition()`; মোট ১০ সেকেন্ড সীমা (`EmergencyService._getCurrentLocation()`, line ~1323-1374)।

**৩৯. SOS পাঠাতে কোন package/method?**
Android-এ নিজস্ব Kotlin `SmsSender` (`SmsManager.sendTextMessage` / `sendMultipartTextMessage`) — MethodChannel `sms` দিয়ে (`NativeSmsService.send()`); fallback `telephony` plugin-এর `sendSms()`; শেষ fallback Messages app composer। Cloud alert: `FirebaseFirestore...collection('sos_alerts').doc().set()`।

**৪০. Internet না থাকলে কী হবে?**
SMS যায় (SIM)। Cloud alert local queue-এ থাকে, online হলে যায়। Snackbar: "SMS sent to X of Y contact(s). The app alert will send when you are online."

**৪১. GPS বন্ধ থাকলে?**
Last known position চেষ্টা; না পেলে SMS-এ "Location unavailable"; পরে ৯০ সেকেন্ডের মধ্যে fix পেলে follow-up SMS "EMERGENCY UPDATE: ..." (`_sendLocationFollowUp()`)।

**৪২. SMS permission না দিলে?**
Default Messages app recipient ও message সহ খুলে যায় — user শুধু Send চাপবেন (`SmsSender.openComposer()`); app background-এ থাকলে notification "Tap to send your SOS SMS"।

**৪৩. কোনো contact না থাকলে?**
SOS হয় না; snackbar "No emergency contacts configured. Please add emergency contacts first." ও "Contacts" বোতাম।

**৪৪. দুবার SOS চাপলে কি দুটো alert যায়?**
না। `SosGate` — চলমান run শেয়ার হয়; live alert থাকলে বোতাম চাপলে action sheet আসে। ESP32/manual press live alert-এ `reRing()` (ringSeq +1) করে, নতুন document নয়। Automatic trigger live alert থাকলে কিছুই করে না।

**৪৫. SMS-এ কী লেখা যায়?**
`'EMERGENCY! $name needs help. Live location: https://maps.google.com/?q=LAT,LNG  Time: 10:42 PM, 30 Oct 2026'` (`buildSosSmsMessage()`)।

**৪৬. Bangladesh-এর নম্বর format কীভাবে?**
`01XXXXXXXXX` (১১ অঙ্ক) → `+8801XXXXXXXXX`; `8801…` (১৩) → `+8801…`; `008801…` → `+8801…` (`formatRecipientPhone()`)।

**৪৭. Dual-SIM ফোনে SMS কোন SIM থেকে যায়?**
Default SMS SIM আগে; ব্যর্থ হলে অন্য SIM (READ_PHONE_STATE থাকলে তালিকা পায়) (`SmsSender.candidateSubscriptions()`)। কারণ Samsung-এ "Ask every time" থাকলে `SmsManager.getDefault()` চুপচাপ ব্যর্থ হয়।

**৪৮. Guardian alert কীভাবে পায় — FCM?**
না। Guardian-এর ফোনে native foreground service `GuardianAlertService.kt` Firestore-এ `whereArrayContains("recipientUids", uid)` ও `recipientEmails` listener রাখে; নতুন eligible alert এলে `AlertSirenPlayer` (alarm stream, ২ মিনিট) ও full-screen notification।

**৪৯. App বন্ধ থাকলেও guardian কীভাবে শোনে?**
`GuardianAlertService` foreground service (`stopWithTask="false"`), `GuardianWatchdogReceiver` প্রতি ১০ মিনিটে alarm দিয়ে restart/reconnect, `GuardianBootReceiver` boot-এর পর চালু।

**৫০. Guardian একই alert-এ বারবার siren শুনবে না কেন?**
Ring key `alertId#ringSeq` — `AlertRegistry.tryClaim()` প্রথমবারই true; sender ইচ্ছা করে আবার চাপলে ringSeq বাড়ে, তখন আবার বাজে।

**৫১. পুরনো alert দেরিতে পৌঁছালে?**
৩০ মিনিটের বেশি পুরনো হলে siren নয়, "Missed SOS" বা "SOS from X is still active" সাধারণ notification (`LIVE_ALERT_MS`, `notifyEarlierAlerts()`)।

**৫২. Guardian "I'm Responding" চাপলে কী হয়?**
`acknowledgedBy` arrayUnion, `acknowledgedAt.{uid}` server time, `lastRespondedAt`, timeline event `guardian_responding` (`NotificationService.acknowledgeAlert()`); sender-এর escalation থেমে যায়।

**৫৩. Escalation-এর সময় কী?**
Stage 1 = ১৮০ সেকেন্ড / ৩ মিনিট (backup contact SMS + recipient যোগ) (`EscalationConfig`)। পূর্বে থাকা ৮ মিনিটের Stage 2 বাদ দেওয়া হয়েছে।

**৫৪. Backup contact কী?**
`isBackup: true` contact প্রথম SOS round-এ বাদ থাকে, ৩ মিনিটে কেউ সাড়া না দিলে তাদের জানানো হয়; শুধু backup থাকলে প্রথম round-এই সবাই।

**৫৫. Primary contact কী করে?**
SOS-এ primary-কে সবার আগে SMS (তালিকার প্রথমে) — `ContactService.primaryFirst()`। একজনই primary (`setPrimaryContact()`)।

**৫৬. Live location কত ঘন ঘন update হয়?**
Position stream (`distanceFilter: 5`); Firestore write কমপক্ষে ৩০ সেকেন্ড পরপর, ২৫ মিটার নড়লে, বা ১২০ সেকেন্ড heartbeat (`LiveTrackingService.shouldWriteUpdate()`)।

**৫৭. SOS কতক্ষণ active থাকে?**
`expiresAt` = তৈরির সময় + ২ ঘণ্টা (`sosAlertLifetime`); প্রতিটি location update-এ আবার +২ ঘণ্টা। Sender "I'm safe" দিলে `resolved`।

**৫৮. Contact কীভাবে add হয়?**
Email দিয়ে `users` খোঁজা → পাওয়া গেলে uid-সহ `connection_requests` (pending), না পেলে email-key দিয়ে request, error হলে offline contact (`add_contact_dialog.dart` → `ContactSyncService`)।

**৫৯. Guardian link one-way কেন?**
আগে mutual ছিল, ফলে guardian-এর SOS-ও protected-এর কাছে যেত। এখন accept করলে শুধু sender-এর `contacts`-এ guardian যোগ হয় (`acceptRequest()`); পুরনো data-র জন্য `GuardianLinkMigrationService`।

**৬০. Safe Journey-তে কোন কোন অবস্থায় check আসে?**
GPS ৫ মিনিট বন্ধ, ETA + ৫ মিনিট পার, route থেকে ৫০০ মিটার দূরে বা পরপর ৪ বার দূরত্ব বৃদ্ধি, ১০ মিনিটে < ৩০ মিটার নড়াচড়া (`JourneyService.evaluateSafetyTriggers()`)।

**৬১. Arrival কীভাবে বোঝে?**
গন্তব্যের ১০০ মিটারের মধ্যে এলে (`haversineDistance` ≤ 100) `completeJourney()`।

**৬২. Route কোথা থেকে আসে?**
`routing.openstreetmap.de` (OSRM) — `routed-car` বা `routed-foot` profile (`RouteService.fetchRoute()`); place search `photon.komoot.io` (Bangladesh bbox)।

**৬৩. Followed Mode-এ check-in কত পরপর? শব্দ হয় কেন না?**
প্রতি ৫ মিনিট (`followedCheckInterval`); channel `followed_mode_checks_channel`-এ `playSound: false` — যাতে অনুসরণকারী শুনতে না পায়।

**৬৪. Number plate কীভাবে পড়েন?**
ML Kit Latin → (key থাকলে) Gemini → Tesseract বাংলা (`ben.traineddata`) একাধিক processed image-এ → `PlateVoting.decide()` দিয়ে vote (`RideOcrService.recognizePlate()`)।

**৬৫. Gemini কেন, Cloud Vision নয় কেন?**
Cloud Vision-এর জন্য billing লাগে; Gemini free-tier key (`--dart-define-from-file=secrets.json`)। Key না থাকলে বা offline হলে on-device OCR। মোট ৩০ সেকেন্ড budget, model ১২ সেকেন্ড করে।

**৬৬. Ride overdue কখন?**
`createdAt + expectedMinutes + 10 মিনিট` পার হলে → status `overdue`, SMS, ৬০ সেকেন্ডের check → উত্তর না দিলে `RIDE_OVERDUE_SOS`।

**৬৭. App বন্ধ থাকলে journey/ride timer কীভাবে কাজ করে?**
প্রতিটি timer native exact alarm হিসেবেও arm (`SafetyDeadlineService.arm()` → `SafetyDeadlines.kt`)। বাজলে native "are you safe?" notification, উত্তর না পেলে headless Dart engine-এ SOS। `claim()` নিশ্চিত করে একবারই।

**৬৮. ESP32 কীভাবে কাজ করে?**
ESP32 BLE server (service `4fafc201-…`, SOS characteristic `beb5483e-…`); GPIO 4-এর বোতাম চাপলে `"SOS"` notify। Android-এ `PendantLinkService.kt` সংযুক্ত থাকে, `SosPacketFilter` (৩ সেকেন্ড settle, ৩০ সেকেন্ড cooldown) পার হলে `DeadlineDartRunner` → `triggerEmergency(source: 'ESP32 Hardware')`।

**৬৯. Pendant কি নিজে SMS পাঠায়?**
না। Pendant শুধু BLE signal দেয়; SMS ও cloud alert ফোন থেকে যায়। ফোন কাছে (BLE range) থাকতে হবে।

**৭০. ভুলবশত pendant চাপলে বা চেপে ধরে রাখলে?**
App ৩০ সেকেন্ডের মধ্যে দ্বিতীয় SOS নেয় না, একই sequence দুবার নেয় না, connect-এর প্রথম ৩ সেকেন্ড ignore। (Firmware-এ শুধু ২৫০ ms debounce।)

**৭১. Shake detection-এর নিয়ম?**
১৫০০ ms-এর মধ্যে ৩টি shake, প্রতিটি gravity থেকে > ১৬ m/s² বিচ্যুতি, মাঝে ≥ ২৫০ ms; তারপর ৫ সেকেন্ড countdown (`ShakeDetector`, `ShakeSosService`)। Default বন্ধ।

**৭২. Fall detection algorithm?**
তিন ধাপ: free-fall (< 0.5g, ≥ ৮০ ms) → ১ সেকেন্ডের মধ্যে impact (> 2.5g) → ২ সেকেন্ড stillness (g ± 0.3g); তারপর ৩০ সেকেন্ড countdown (`FallDetectionEngine`)। Default বন্ধ।

**৭৩. Duress PIN কী?**
দ্বিতীয় একটি PIN; কেউ জোর করে PIN চাইলে এটা দিলে app calculator হয়ে যায়, siren ছাড়া silent SOS যায়: "SILENT EMERGENCY: ... Do NOT call her phone! ..." (`triggerDuressPipeline()`)।

**৭৪. PIN কীভাবে সংরক্ষিত?**
১৬-character random salt (`Random.secure()`) + SHA-256(`'$salt:$pin'`), SharedPreferences-এ (`hashPin()`)। ৪ অঙ্ক।

**৭৫. Camouflage থেকে বের হবেন কীভাবে?**
Calculator-এ Real PIN টাইপ করে `=` (`CamouflageCalculatorScreen._onEquals()`)।

**৭৬. Siren কেন silent mode-এও বাজে?**
Alarm audio stream ব্যবহার (`AndroidUsageType.alarm` / `USAGE_ALARM`) এবং alarm volume max করা হয়, শেষে আগের volume ফেরত (`SirenService`, `SirenVolume.kt`)।

**৭৭. Fake call-এর voice কোথা থেকে?**
নিজের recording → bundled বাংলা clip (বর্তমানে placeholder) → Android TextToSpeech ইংরেজি।

**৭৮. Battery কম হলে কী হয়?**
≤ ১০% ও charging না হলে একবার SMS: "<name>'s phone battery is critical (X%). Last known GPS: <link>" (`BatteryAlertService`), default চালু।

**৭৯. Safe zone data কোথা থেকে?**
App-এর ভিতরে `assets/data/safe_zones.json` — ১৮৬টি স্থান (hospital ৮৭, police ৬৯, fire_service ১৯, toll_plaza ৫, clinic ৪, govt_service ২); internet ছাড়াও কাজ করে।

**৮০. Unsafe spot report কীভাবে কাজ করে?**
Map থেকে report → `safety_reports` (type, lat/lng, geohash5/6); geohash6 cell-ভিত্তিক risk score, ২০০ মিটারের মধ্যে গেলে warning (১৫ মিনিট cooldown)।

**৮১. Guardian journey-তে কী দেখে?**
Notification ("🚶 X started a Safe Journey"), home-এ incoming journey card, `JourneyTrackingScreen`-এ live map; "watching" চিহ্ন দিলে traveler দেখেন।

**৮২. Activity history কোথায় থাকে?**
`users/{uid}/activity_logs` (Firestore) + offline cache; SOS entry মোছা যায় না (rules)।

**৮৩. একটি phone নম্বর দুই account-এ দেওয়া যায়?**
না — `phone_numbers/{+E164}` create-only, অন্যের হলে claim ব্যর্থ (`PhoneRegistryService.claimForCurrentUser()`)।

---

## ঙ. Tricky / সমালোচনামূলক প্রশ্ন (সৎ কিন্তু শক্ত উত্তর)

**৮৪. iOS-এ কি app কাজ করে?**
সৎ উত্তর: app মূলত Android-এর জন্য তৈরি। iOS-এ automatic SMS প্ল্যাটফর্মগতভাবে সম্ভব নয়, native background listener ও exact-alarm নেই, আর `Info.plist`-এ একটা XML ত্রুটি আছে (`~ipad` orientation array বন্ধ হয়নি) — তাই iOS build test করা হয়নি। এটা future work।

**৮৫. FCM push না থাকলে guardian-এর ফোন sleep-এ থাকলে alert দেরি হবে না?**
Android-এ foreground service + প্রতি ১০ মিনিটের watchdog Firestore reconnect করে; শুধু server data-তে ring; দেরি হলে "missed/late" notification। তবে Doze/OEM battery saver-এ কিছু দেরি সম্ভব — তাই reliability setup (battery optimization, Samsung guide, full-screen permission) দেখানো হয়। Blaze plan-এ FCM high-priority push আরও নির্ভরযোগ্য হতো।

**৮৬. Guardian accept না করলেও কি alert পায়?**
সৎ উত্তর: SMS যায় phone number থাকলেই (consent ছাড়া, যেমন সাধারণ SMS)। Cloud alert-এ pending contact-এর email-ও `recipientEmails`-এ যায়, তাই সেই email-এর app user app খোলা অবস্থায় দেখতে পারেন। এটা জানা gap; সমাধান — শুধু `synced` contact-কে cloud recipient করা।

**৮৭. Security rules-এ কোনো দুর্বলতা আছে?**
হ্যাঁ: `users` সব login user readable; `safety_reports` update খোলা; ride guardian অনেক field বদলাতে পারে। SOS alert, contacts, activity log, phone registry অংশ কড়া। উন্নতির পরিকল্পনা `06_ISSUES_BN.md`-এ।

**৮৮. Settings-এ "Live location sharing" বন্ধ করলে কী হয়?**
সৎ উত্তর: এখন কিছুই না — toggle শুধু save হয়, কোনো service পড়ে না। একই অবস্থা "Push notifications"-এর। এগুলো কার্যকর করা বাকি।

**৮৯. Map-এর heatmap কি আসল data?**
Firestore-এ active report থাকলে আসল; না থাকলে বা error হলে code ঢাকার কিছু hard-coded seed report দেখায় (`_getDhakaSeedReports()`) — demo-র জন্য। এটা স্পষ্টভাবে বলা উচিত।

**৯০. Escalation-এ 999 prompt কি রাখা হয়েছে?**
না, ৮ মিনিটের Stage 2 (999 prompt) বাদ দেওয়া হয়েছে। এখন Incident Room ও SOS ডায়ালগ থেকে সরাসরি ৯৯৯-এ কল করার বোতাম ব্যবহার করা যায়, আর এস্কেলেশন শুধুমাত্র ৩ মিনিটে ব্যাকআপ কন্টাক্টদের অ্যালার্ট করার কাজ করে।

**৯১. ৪ সেকেন্ড পরপর Firestore query — খরচ বেশি না?**
হ্যাঁ, `ContactSyncService` heartbeat প্রতি ৪ সেকেন্ডে request ও contact refresh করে — Spark-এর দৈনিক read সীমায় চাপ দিতে পারে। Real-time listener ইতিমধ্যে আছে, তাই heartbeat কমানো বা বাদ দেওয়া উন্নতি।

**৯২. PIN brute-force করা যায় না?**
৪ অঙ্কের PIN-এর ১০,০০০ সম্ভাবনা; hash salted হলেও rooted ফোনে offline brute-force সম্ভব। UI-তে ভুল PIN-এ শুধু error দেখায়। উন্নতি: secure storage, slow hash, লম্বা PIN, lockout।

**৯৩. Gemini API key কি নিরাপদ?**
Build-time-এ APK-তে ঢুকে যায়, তাই extract করা সম্ভব। Free-tier key, quota-সীমিত; production-এ backend proxy দরকার। Key না দিলেও app কাজ করে (on-device OCR)।

**৯৪. Release APK কীভাবে sign করা?**
এখন debug key দিয়ে (`signingConfigs.getByName("debug")`) — Play Store-এর আগে নিজস্ব keystore লাগবে।

**৯৫. Cloud Functions-এ bug আছে?**
হ্যাঁ, `onSosAlertTriggered`-এ `contactUids` undefined; তবে Functions Spark-এ deploy হয় না এবং app এর উপর নির্ভর করে না।

**৯৬. SOS document অনির্দিষ্টভাবে বড় হতে পারে?**
`recentTrail` arrayUnion দিয়ে বাড়ে; খুব দীর্ঘ SOS-এ ১ MB সীমায় পৌঁছাতে পারে। সমাধান: শেষ N বিন্দু রাখা।

**৯৭. Volume button দিয়ে SOS আছে?**
না, code-এ নেই। Hardware trigger হিসেবে ESP32 pendant, shake ও fall আছে।

**৯৮. Phone OTP verification আছে?**
Code আছে (`PhoneVerificationService`, `PhoneVerificationModal`), কিন্তু UI-তে কোথাও যুক্ত নয় — dead code। Phone number শুধু one-account-per-number registry দিয়ে রক্ষিত, OTP যাচাই নয়।

---

## চ. তুলনামূলক প্রশ্ন (শুধু code-এ থাকা feature)

**৯৯. Google-এর Personal Safety / সাধারণ SOS app থেকে পার্থক্য?**
এই app-এ: Bangladesh phone format ও নিজের SIM-এ dual-SIM retry; বাংলা BRTA plate OCR দিয়ে Ride Check-in; duress PIN + calculator ছদ্মবেশ; নিজস্ব ESP32 pendant; guardian-এর ফোনে app বন্ধ থাকলেও siren (Android native service); one-way consent-based guardian link; Smart escalation (backup contact)।

**১০০. সরকারি "৯৯৯" বা "Joy" app-এর সাথে তুলনা?**
(ঐসব app-এর code এই repo-তে নেই, তাই তুলনা শুধু এই app-এর দিক থেকে:) এই app পুলিশকে সরাসরি alert পাঠায় না; এটা পরিচিত guardian-কেন্দ্রিক — SMS, live tracking, siren — আর 999-এ call করতে dialer খুলে দেয়।
