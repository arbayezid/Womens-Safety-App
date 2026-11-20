# ১০. সমস্যা, দুর্বলতা ও ভবিষ্যৎ উন্নয়ন

> Board এগুলো জিজ্ঞেস করতে পারে — লুকানো হয়নি। প্রতিটির সাথে প্রমাণ ও "সৎ কিন্তু শক্ত" উত্তরের ইঙ্গিত দেওয়া আছে। তীব্রতা: 🔴 গুরুতর, 🟠 মাঝারি, 🟡 ছোট।

## ১০.১ Bug ও ভুল আচরণ

| # | সমস্যা | প্রমাণ | তীব্রতা |
|---|---|---|---|
| B1 | **`ios/Runner/Info.plist` valid XML নয়** — `UISupportedInterfaceOrientations~ipad`-এর `<array>` বন্ধ না করেই `<key>LSApplicationQueriesSchemes</key>` শুরু। Python parser: `mismatched tag: line 92, column 2`। iOS build/plist processing ব্যর্থ হওয়ার কথা। | `ios/Runner/Info.plist`, line ~77-92 | 🔴 (iOS) |
| B2 | **Cloud Function `onSosAlertTriggered`-এ undefined variable `contactUids`** — `notifiedUids: contactUids` ReferenceError ছুঁড়বে (catch-এ log হবে); push পাঠানোর পরের ধাপ। | `functions/index.js`, line ~340-343 | 🟡 (Functions deploy হয় না বলে বাস্তব প্রভাব নেই) |
| B3 | **Battery alert SOS doc-এ `batteryStatus` লেখে**, যা rules-এর sender allow-list-এ নেই → পুরো update reject (চুপচাপ catch)। Ride session-এ `activeType == 'ride'` হলে `journeys` collection-এ লেখে (ভুল collection)। | `lib/services/battery_alert_service.dart`, line ~173-181; `firestore.rules`, line ~206-235 | 🟠 |
| B4 | **Stage-2 escalation notification "Tap here to call 999"** — tap করলে 999 dial হয় না (payload নেই, handler নেই)। | `sos_escalation_service.dart`, line ~384-388; `notification_service.dart`, `showStatusNotification()` line ~1372-1391 | 🟠 |
| B5 | **Settings-এর "Live location sharing" ও "Push notifications" toggle কিছুই করে না** — pref save হয়, কেউ পড়ে না। | `lib/screens/settings_screen.dart`, line ~226-231, ~455-460 | 🟠 (ব্যবহারকারীকে বিভ্রান্ত করে) |
| B6 | **Safety map-এ Firestore খালি/error হলে hard-coded "Dhaka seed reports"** দেখায় — আসল data মনে হতে পারে। | `lib/services/safety_report_service.dart`, line ~70-75, ~86-90, ~300+ | 🟠 (demo-তে স্বচ্ছ থাকুন) |
| B7 | **Fake call-এর bundled বাংলা clip placeholder** (আধা সেকেন্ড নীরবতা) — app ইংরেজি TTS-এ ফিরে যায়। | `assets/fake_call/bn/README.md` | 🟡 |
| B8 | **ESP32 firmware battery `95` hard-coded**, আসল ADC পড়া হয় না। | `esp32_firmware/esp32_woman_guard_pendant.ino`, `batteryLevel = 95` | 🟡 |
| B9 | Stage-delay pref (`pref_escalation_stage1/2_minutes`) পড়া হয় কিন্তু কোথাও লেখা হয় না। | `sos_escalation_service.dart`, line ~62-63, ~121-127 | 🟡 |
| B10 | Ride overdue SMS যায় **সব** emergency contact-এ (`getEmergencyPhoneNumbers()`), শুধু ride-এর জন্য বাছাই করা guardian-এ নয়। | `ride_checkin_service.dart`, line ~541 | 🟡 |
| B11 | Journey/ride `guardianIds`-এ offline contact-এর `offline_<ms>` id ঢুকতে পারে (কারণ `ContactService` contactUid না থাকলে doc.id বসায়); SOS-এর `recipientUids`-এ `pending_<key>` ঢুকতে পারে (`offline_` ছাড়া অন্য prefix filter হয় না)। ক্ষতিকর নয়, অকেজো entry। | `contact_service.dart`, line ~319-323; `emergency_service.dart`, line ~737-742; `ride_checkin_screen.dart`, line ~507-509 | 🟡 |

## ১০.২ Security risk

| # | ঝুঁকি | প্রমাণ | কী বলবেন / সমাধান |
|---|---|---|---|
| S1 | `users` collection সব login user পড়তে পারে → phone, email, blood group, emergency note, FCM token প্রকাশ। | `firestore.rules`, line ~44 | email দিয়ে guardian খোঁজার জন্য রাখা; সমাধান: public `user_directory` আলাদা collection (শুধু uid+email hash), বাকি private। |
| S2 | `safety_reports` update যেকোনো login user যেকোনো field-এ পারে। | line ~376 | `affectedKeys().hasOnly(['verifiedCount'])` ও `+1` শর্ত। |
| S3 | `ride_checkins` guardian `status` সহ প্রায় সব field বদলাতে পারে। | line ~357-360 | guardian-এর জন্য allow-list। |
| S4 | **SOS consent gap:** pending (accept না করা) contact-এর email `recipientEmails`-এ যায়; rules তাকে read করতে দেয়; foreground app-এ তার Dart listener alert দেখাবে। | `emergency_service.dart`, line ~730-735; `firestore.rules`, line ~170-177 | design সিদ্ধান্ত হিসেবে বলা যায় "জরুরি অবস্থায় বেশি মানুষ জানুক", তবে সমাধান: শুধু `syncStatus == 'synced'` contact-কে cloud recipient করা। |
| S5 | Report-এর দৈনিক ৩টি সীমা শুধু client-side (SharedPreferences)। | `safety_report_service.dart`, line ~212-224 | rules-এ server-side rate limit কঠিন; Cloud Function/App Check লাগবে। |
| S6 | Gemini API key APK-তে embed (`String.fromEnvironment`)। | `gemini_plate_reader.dart`, line ~37 | free-tier key, quota-সীমিত; production-এ proxy server। |
| S7 | Release build debug key দিয়ে sign। | `android/app/build.gradle.kts`, line ~38-44 | Play Store-এর আগে নিজস্ব keystore। |
| S8 | ৪-অঙ্কের PIN-এর hash local SharedPreferences-এ — rooted device-এ ১০,০০০ সম্ভাবনা brute-force করা সহজ। | `pin_security_service.dart`, line ~28-35, ~61-64 | `flutter_secure_storage` + PBKDF2/Argon2 + লম্বা PIN। |
| S9 | Firebase App Check নেই — চুরি করা client key দিয়ে কেউ API ডাকতে পারে (তবুও rules প্রযোজ্য)। | pubspec-এ `firebase_app_check` নেই | App Check (Play Integrity)। |
| S10 | `storage.rules` repo-তে নেই — Storage-এর access ⚠️ কোড থেকে নিশ্চিত করা যায়নি। | repo | console-এ rules যাচাই। |

## ১০.৩ Dead code / অসংযুক্ত অংশ
- `lib/widgets/phone_verification_modal.dart` (কোথাও import নেই) ও `lib/services/phone_verification_service.dart` (শুধু ওই modal-এ import) — Phone OTP feature UI-তে নেই।
- `EmergencyService.updateContacts()` / `_emergencyContacts` (call নেই), `triggerEmergencySOS()`, `sendEmergencySMS()`।
- `ContactService.resetToDefaults()`, `clearContacts()`, `_defaultContacts` (Mom/Dad/Riya sample — শুধু Firebase না থাকলে test-এ)। `[contact_service.dart, line ~34-62, ~460-466]`
- `home_screen.dart`-এ `'Safe Route'` quick-action branch (tile নেই)।
- `functions/index.js` (Spark-এ চলে না)।
- Unused package: `cupertino_icons`।
- Manifest-এ declare কিন্তু runtime-এ চাওয়া হয় না: `ACCESS_BACKGROUND_LOCATION`, `READ_PHONE_STATE`, `CALL_PHONE` (call `tel:` dialer দিয়ে হয়, এই permission লাগে না)।
- iOS: `UIBackgroundModes` `fetch` আছে, কিন্তু কোনো background fetch logic নেই (`onIosBackground` শুধু `true`)।

## ১০.৪ Scalability / খরচ সীমা (Spark plan)

> নিচের হিসাবগুলো code-এর timer থেকে করা অনুমান; আসল খরচ Firebase console-এর Usage tab-এ দেখতে হবে (⚠️)।

1. **৪ সেকেন্ডের heartbeat:** `ContactSyncService` প্রতি ৪ সেকেন্ডে ৪টি `connection_requests` query + `getContacts(forceRefresh: true)` চালায় (`Source.serverAndCache`)। app খোলা থাকলে ঘণ্টায় ~৯০০ বার। Firestore প্রতিটি query-তে কমপক্ষে ১টি read গোনে → একজন user-ই ঘণ্টায় কয়েক হাজার read করতে পারে; Spark-এর দৈনিক read সীমা দ্রুত শেষ হতে পারে। `[source: contact_sync_service.dart, line ~99-109, ~650-725]`
2. `NotificationService`-এর ৪ সেকেন্ডের heartbeat শুধু listener জীবিত কিনা দেখে ও local re-process করে (নতুন query নয়, যদি listener না মরে)। `[notification_service.dart, line ~871-881]`
3. `recentTrail` `arrayUnion`-এ অসীমভাবে বাড়ে — দীর্ঘ SOS-এ document ১ MB সীমায় পৌঁছাতে পারে। `[live_tracking_service.dart, line ~233-239]`
4. `sos_alerts` কখনো মোছা যায় না (rules) — শুধু admin script `scripts/cleanup_sos.js`।
5. Email-ভিত্তিক `in` query সর্বোচ্চ ৩০টি (Functions-এ `slice(0, 30)`)।
6. Safety report: সর্বোচ্চ ১০০টি fetch — শহর জুড়ে বেশি report হলে অসম্পূর্ণ heatmap। `[safety_report_service.dart, line ~60-64]`
7. Public OSM tile server ভারী ব্যবহারের জন্য নয় (OSM tile usage policy)।

## ১০.৫ Platform সীমাবদ্ধতা
- iOS-এ automatic SMS, guardian background listener, exact-alarm deadline নেই; Info.plist ত্রুটি; Bluetooth usage description নেই; Google Sign-In URL scheme নেই → **iOS সমর্থন বাস্তবে অসম্পূর্ণ।**
- Android OEM (Xiaomi, Oppo, Vivo, Samsung) background kill — app auto-start settings ও Samsung guide দেখায়, কিন্তু নিশ্চয়তা দিতে পারে না। `[source: AppChannels.kt, openAutoStartSettings(), line ~106-130]`

## ১০.৬ বাস্তবসম্মত ভবিষ্যৎ উন্নয়ন
1. Blaze plan + Cloud Function দিয়ে FCM high-priority push (iOS guardian-দের জন্য অপরিহার্য), এবং `functions/index.js`-এর `contactUids` bug ঠিক করা।
2. Security rules কড়া করা (S1–S3), App Check, `flutter_secure_storage`।
3. SOS-এ শুধু accepted guardian-কে cloud recipient (S4)।
4. ৪ সেকেন্ড polling বাদ দিয়ে শুধু snapshot listener।
5. `recentTrail` সীমিত রাখা (শেষ N বিন্দু) বা subcollection-এ।
6. iOS: Info.plist ঠিক করা, BLE/Location-always usage description, `GoogleService-Info.plist`, critical alert entitlement।
7. Volume-button / power-button SOS (এখন নেই)।
8. বাংলা UI localization (এখন UI text ইংরেজি)।
9. নিকটবর্তী police-এর সাথে সরাসরি সংযোগ / 999 auto-call (এখন শুধু dialer খোলে)।
10. Audio/video evidence recording SOS-এর সময় (এখন নেই)।
11. Dead code (phone OTP) চালু বা মুছে ফেলা; UI-only toggle কার্যকর করা।
12. Seed data-কে "Demo" label দেওয়া।
