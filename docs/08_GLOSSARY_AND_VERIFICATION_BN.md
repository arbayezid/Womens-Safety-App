# ১২. Glossary (শব্দকোষ) ও ১৩. যাচাই রিপোর্ট (Verification Report)

---

## ১২. Glossary

| শব্দ | সহজ বাংলা ব্যাখ্যা |
|---|---|
| Flutter | Google-এর UI framework — একই Dart code থেকে Android/iOS app |
| Dart | Flutter-এর programming language |
| Widget | Flutter-এ screen-এর প্রতিটি অংশ (বোতাম, লেখা, পুরো পাতা) |
| StatelessWidget | যে widget-এর নিজের পরিবর্তনশীল অবস্থা নেই |
| StatefulWidget | যে widget-এর `State` আছে, `setState()` দিলে আবার আঁকা হয় |
| `setState` | State বদলেছে জানিয়ে UI আবার আঁকার নির্দেশ |
| Future | ভবিষ্যতে একবার আসবে এমন ফল (যেমন GPS position) |
| Stream | ডেটার একটানা প্রবাহ, নতুন ডেটা এলেই UI আপডেট হয় (যেমন Firestore snapshots) |
| async / await | অপেক্ষা করতে হয় এমন কাজ UI না আটকে চালানো |
| `unawaited` | ইচ্ছাকৃতভাবে ফলের অপেক্ষা না করে কাজ চালু রাখা |
| Singleton | পুরো app-এ একটাই instance (যেমন `EmergencyService.instance`) |
| ValueNotifier | একটা মান রাখে; বদলালে listener-দের জানায় |
| ValueListenableBuilder | ValueNotifier বদলালে নিজে rebuild হওয়া widget |
| ChangeNotifier | listener-দের `notifyListeners()` দিয়ে জানানো class |
| IndexedStack | একসাথে অনেক child রাখে, শুধু একটা দেখায় — state হারায় না |
| Navigator / Route | screen-এর stack; push = নতুন screen, pop = ফিরে যাওয়া |
| MethodChannel | Dart ও native (Kotlin/Swift) code-এর মধ্যে বার্তা আদান-প্রদানের পথ |
| Native code | Platform-এর নিজস্ব ভাষায় লেখা code (এখানে Kotlin) |
| Headless engine | UI ছাড়া background-এ Dart চালানোর Flutter engine |
| `@pragma('vm:entry-point')` | release build-এ function মুছে না ফেলার নির্দেশ (native নাম ধরে ডাকে) |
| Isolate | Dart-এর আলাদা thread-এর মতো, নিজস্ব memory |
| Package | pub.dev থেকে আনা তৈরি লাইব্রেরি |
| pubspec.yaml / pubspec.lock | dependency তালিকা / বাস্তবে install হওয়া version-এর তালিকা |
| Firebase | Google-এর Backend-as-a-Service |
| Firebase Authentication | login ও user পরিচয় (uid) |
| uid | প্রতিটি user-এর অনন্য id |
| Cloud Firestore | NoSQL document database — collection → document → field |
| Collection / Document / Subcollection | ফোল্ডার / ফাইল / ফাইলের ভিতরের ফোল্ডার — এই ধরনের গঠন |
| Snapshot listener | Firestore data বদলালেই সাথে সাথে খবর পাওয়া |
| `arrayContains` query | array field-এ নির্দিষ্ট মান আছে এমন document খোঁজা |
| Composite index | একাধিক field মিলিয়ে query দ্রুত করার index |
| `FieldValue.serverTimestamp()` | client নয়, server-এর সময় বসানো |
| `FieldValue.arrayUnion` / `increment` | array-তে যোগ / সংখ্যা বাড়ানো (atomic) |
| Batch write | একাধিক write একসাথে — হয় সব, নয় কিছুই না |
| Offline persistence | internet না থাকলে local cache-এ রাখা, পরে sync |
| Security Rules | server-side নিয়ম — কে কোন data পড়তে/লিখতে পারবে |
| `request.auth` / `request.resource` / `resource` | rules-এ: কে চাইছে / নতুন data / বর্তমান data |
| Spark plan / Blaze plan | Firebase-এর free plan / pay-as-you-go plan |
| Cloud Functions | server-এ চলা code (Blaze plan লাগে) |
| FCM (Firebase Cloud Messaging) | push notification সেবা |
| FCM token | একটা device-কে push পাঠানোর ঠিকানা |
| Firebase Storage | ছবি/ফাইল রাখার cloud storage |
| Crashlytics | app crash-এর রিপোর্ট সংগ্রহ |
| SOS | জরুরি সাহায্যের সংকেত |
| Guardian | যিনি accept করে কারো SOS পান |
| Protected user | যিনি SOS পাঠান (request পাঠিয়েছেন) |
| Primary contact | SOS-এ সবার আগে SMS পান এমন একজন |
| Backup contact | ৩ মিনিটে কেউ সাড়া না দিলে যাকে জানানো হয় |
| Escalation | সাড়া না পেলে ধাপে ধাপে বাড়তি পদক্ষেপ |
| Ring key (`alertId#ringSeq`) | একটি alert-এর একটি "বাজনা"-র পরিচয় — একবারই বাজে |
| Re-ring | sender ইচ্ছা করে আবার চাপলে `ringSeq` +১, guardian আবার শোনেন |
| Duress PIN | চাপে পড়ে দেওয়ার গোপন PIN — চুপচাপ SOS পাঠায় |
| Camouflage | app-কে calculator হিসেবে লুকানো |
| Salt / SHA-256 / Hash | PIN-এর সাথে random অংশ মিশিয়ে একমুখী এনক্রিপশন |
| Geolocator | GPS location নেওয়ার package |
| Reverse geocoding | coordinate থেকে ঠিকানা |
| Haversine | পৃথিবীর বক্রতা ধরে দুই বিন্দুর দূরত্ব হিসাবের সূত্র |
| Cross-track distance | একটি পথ-রেখা থেকে লম্ব দূরত্ব |
| Geohash | lat/lng-কে ছোট string-এ রূপান্তর; কাছাকাছি স্থানের prefix একই |
| E.164 | আন্তর্জাতিক phone format (`+8801XXXXXXXXX`) |
| SmsManager | Android-এর SMS পাঠানোর system API |
| Multipart SMS | লম্বা বার্তা কয়েক অংশে ভাগ করে পাঠানো |
| Dual-SIM / Subscription id | দুই SIM-এর ফোনে কোন SIM দিয়ে পাঠানো হবে তার id |
| PendingIntent | পরে অন্য কাউকে (system) দিয়ে চালানো হবে এমন intent |
| Intent | Android-এ কাজ/screen চালুর বার্তা |
| Foreground service | notification দেখিয়ে background-এ চলা Android service — সহজে kill হয় না |
| Foreground service type (`location`, `connectedDevice`, `specialUse`) | Android 14+-এ service কী কাজে চলছে তা ঘোষণা |
| BroadcastReceiver | system event (boot, alarm) গ্রহণকারী |
| AlarmManager / exact alarm | নির্দিষ্ট সময়ে app জাগানো (Doze-এও) |
| Doze | Android-এর battery-সাশ্রয়ী ঘুম অবস্থা |
| Wake lock | CPU-কে কিছুক্ষণ জাগিয়ে রাখা |
| Full-screen intent | lock screen-এর উপর পুরো screen notification |
| Notification channel | Android-এ notification-এর ধরন (শব্দ, গুরুত্ব) |
| Alarm stream (`USAGE_ALARM`) | alarm-এর audio channel — silent mode-এও বাজে |
| Text-to-Speech (TTS) | লেখা থেকে কণ্ঠস্বর |
| BLE (Bluetooth Low Energy) | কম শক্তির Bluetooth |
| GATT / Service / Characteristic / UUID | BLE device-এর data কাঠামো ও অনন্য id |
| Notify (BLE) | device নিজে থেকে phone-কে data পাঠানো |
| ESP32 | Wi-Fi/Bluetooth-যুক্ত ছোট microcontroller board |
| Debounce / Cooldown | দ্রুত বারবার signal উপেক্ষা করা / নির্দিষ্ট সময় বিরতি |
| Accelerometer | গতি/ত্বরণ মাপার sensor |
| OCR | ছবি থেকে লেখা পড়া |
| ML Kit | Google-এর on-device machine learning (এখানে Latin OCR) |
| Tesseract | open-source OCR engine (এখানে বাংলা `ben`) |
| Gemini API | Google-এর AI model (এখানে plate পড়তে, ঐচ্ছিক) |
| `--dart-define` | build-এর সময় constant মান দেওয়া |
| OpenStreetMap (OSM) / tile | মুক্ত মানচিত্র / map-এর ছোট ছবির টুকরো |
| OSRM | OSM-ভিত্তিক route হিসাব সার্ভিস |
| Photon | OSM-ভিত্তিক place search |
| Dead code | আছে কিন্তু কোথাও ডাকা হয় না এমন code |
| Throttle | নির্দিষ্ট হারের বেশি কাজ না করা |
| Heartbeat | নির্দিষ্ট সময় পরপর নিয়মিত কাজ |
| Tombstone | মোছা item মনে রাখা, যাতে পুরনো data দিয়ে ফিরে না আসে |
| Mermaid | text দিয়ে diagram আঁকার ভাষা |

---

## ১৩. যাচাই রিপোর্ট (Verification Report)

### ১৩.১ পদ্ধতি
1. সব config (pubspec.yaml/lock, AndroidManifest, gradle, Info.plist, AppDelegate, firebase.json, firestore.rules, firestore.indexes.json, functions/, secrets.example.json, .gitignore) সম্পূর্ণ পড়া হয়েছে।
2. মূল service ফাইল সম্পূর্ণ পড়া: `main.dart`, `auth_service`, `emergency_service`, `sos_cloud_dispatcher`, `native_sms_service`, `sos_escalation_service`, `contact_service`, `contact_model`, `contact_sync_service`, `guardian_alert_service`, `live_tracking_service`, `background_service`, `welcome_screen`; Kotlin: `GuardianAlertService`, `MainActivity`, `SmsSender`, `AppChannels`, `NotificationChannels`। বাকি ফাইল (journey, ride, OCR, ESP32, PIN, shake, fall, battery, reports, safe zones, inbox, activity, screens) অংশবিশেষ পড়া + grep দিয়ে নির্দিষ্ট function/constant যাচাই।
3. প্রতিটি feature-এর জন্য UI entry point থেকে caller grep করে trace করা (যেমন `triggerEmergency(`-এর ১২টি call site)।
4. Dead code খোঁজা: প্রতিটি `lib/` ফাইল অন্য কোথাও import হয় কিনা (script), এবং সন্দেহজনক function-এর call গণনা।
5. Read-only command: `flutter --version`, `flutter analyze` (No issues found), Python দিয়ে Info.plist XML parse ও safe_zones.json গণনা, google-services.json-এর key-কাঠামো (মান প্রকাশ না করে)।
6. দ্বিতীয় pass: উদ্ধৃত line নম্বর, সংখ্যা ও মান আবার grep করে মেলানো।

### ১৩.২ সংখ্যা
- ডকুমেন্টে `[source: ...]` সহ স্পষ্ট উদ্ধৃত দাবি: **প্রায় ২৪৩টি** (01: ৫৫, 02: ৪, 03: ১৪২, 04: ২৫, 05: ১৫, 06: ২ + ভেতরের line-reference; Q&A-তে ফাইল/function নাম দিয়ে উল্লেখ)।
- দ্বিতীয় pass-এ নির্দিষ্টভাবে আবার যাচাই করা মান/line নম্বর/গণনা: **প্রায় ৯৫টি** (manifest, gradle, emergency_service, journey_service, pin_security, Info.plist, ফাইল গণনা, package গণনা, settings toggle, upload error handling, report sheet ইত্যাদি)। বাকি উদ্ধৃতি প্রথম pass-এ সরাসরি ফাইল পড়ে লেখা।

### ১৩.৩ যাচাইয়ের সময় সংশোধন করা ভুল
| # | আগে লেখা | সংশোধিত (code অনুযায়ী) |
|---|---|---|
| 1 | AndroidManifest `android:label` line ~48 | line ~49 |
| 2 | `triggerDuressPipeline()` line ~262 (২ জায়গায়) | line ~269 |
| 3 | `lib/services/` ফাইল ৪৩টি | ৪১টি |
| 4 | `lib/widgets/` ১৫ + ৫ | ১৪ + ৫ |
| 5 | Kotlin ফাইল ১৮টি | ২০টি |
| 6 | Dart test ফাইল ৪১টি (৪ জায়গায়); `test/` মোট ৪৩ | ৪২টি; মোট ৪৪ (২টি `.mjs` সহ) |
| 7 | `latlong2` ১২টি ফাইলে | ১১টি (`lib/` মাত্র) |
| 8 | gradle: desugaring line ~16, multiDex ~35, Java ~17-24, dependencies ~50-58 | ~18, ~36, ~19-24, ~48-56 |
| 9 | `SafetyDeadlineService.arm()` line ~140-176 | `arm()` ~193, `resyncFromCloud()` ~266 |
| 10 | `claim()` ~219-229, late alarm ~369-397 | ~221, ~370-410 |
| 11 | Q&A: সব testable logic-এ `@visibleForTesting` | "কয়েকটিতে" — সব class-এ annotation নেই |
| 12 | Q&A: feature phone-এর মা-বাবা link খুলতে পারেন (অনুমান) | code comment উদ্ধৃত করে নিরপেক্ষ বাক্য |
| 13 | Fake call: "ইংরেজি voice" | Android TextToSpeech দিয়ে ইংরেজি (`FakeCallAudio.kt`) |
| 14 | Ride ছবি upload ব্যর্থ হলে "ধরে নেওয়া যায়" | নিশ্চিত: `uploadRideImage()` catch করে `null` ফেরায় |

### ১৩.৪ "⚠️ নিশ্চিত করা যায়নি" তালিকা — আপনাকে নিজে যাচাই করতে হবে

| # | বিষয় | কেন code থেকে বলা যায় না | কীভাবে যাচাই করবেন |
|---|---|---|---|
| U1 | Firebase project সত্যিই Spark plan-এ কিনা | billing console-এর বিষয় | Firebase console → Usage and billing |
| U2 | `firestore.rules` ও indexes console-এ deploy করা আছে কিনা | deploy state repo-তে থাকে না | console → Firestore → Rules / Indexes; অথবা `firebase deploy --only firestore` |
| U3 | Cloud Functions deploy আছে কিনা (FCM push আসে কিনা) | repo-তে code আছে, deploy state নেই | console → Functions (Spark-এ খালি থাকার কথা) |
| U4 | Firebase Storage চালু ও তার rules | `storage.rules` repo-তে নেই | console → Storage → Rules; একটি ride-এ ছবি দিয়ে test |
| U5 | Google Sign-In-এর SHA-1 fingerprint যোগ করা আছে কিনা | console setting | console → Project settings → Android app → SHA certificate; real device-এ login |
| U6 | iOS build সফল হয় কিনা | Info.plist XML ত্রুটি, GoogleService-Info.plist/Podfile নেই; Mac লাগবে | Mac-এ `flutter build ios` |
| U7 | iOS-এ background location / BLE / notification আচরণ | device-নির্ভর | iPhone-এ test |
| U8 | Real SIM-এ SMS পৌঁছায় কিনা (dual-SIM, balance, carrier) | runtime/network-নির্ভর | দুই SIM-এর Android ফোনে SOS test |
| U9 | App বন্ধ/lock অবস্থায় guardian siren ও full-screen alert (Samsung/Xiaomi-তে) | OEM battery policy-নির্ভর | দুই ফোনে test: guardian app swipe করে বন্ধ, screen lock, তারপর SOS |
| U10 | Exact alarm (Android 14+) permission দেওয়া অবস্থায় safety deadline সময়মতো বাজে কিনা | runtime | Safe Journey ছোট ETA দিয়ে শুরু করে app kill করুন |
| U11 | ESP32 pendant app বন্ধ থাকলে SOS পাঠায় কিনা | hardware/BLE runtime | pendant জোড়া লাগিয়ে app swipe করে বোতাম চাপুন |
| U12 | Fall/shake detection-এর বাস্তব নির্ভুলতা (false positive) | heuristic threshold | বিভিন্ন ভাবে test |
| U13 | Gemini model নামগুলো (`gemini-3.5-flash` ইত্যাদি) আপনার key-তে কাজ করে কিনা | external API state | `secrets.json` দিয়ে run করে plate OCR test |
| U14 | Firestore read/write খরচ Spark সীমার মধ্যে থাকে কিনা (বিশেষ করে ৪ সেকেন্ডের heartbeat) | usage runtime-নির্ভর | console → Firestore → Usage |
| U15 | সব test pass করে কিনা | `flutter test` চালানো হয়নি (read-only বিশ্লেষণ) | `flutter test` |
| U16 | minSdk 24 / targetSdk 36 | project-এ hard-coded নয়; Flutter SDK version থেকে আসে | `flutter --version` (এখানে 3.41.9) ও build output |
| U17 | Team-এর দ্বিতীয় সদস্যের ভূমিকা | git log-এ সব ৫০টি commit একই author-এর | নিজে প্রস্তুত রাখুন |
