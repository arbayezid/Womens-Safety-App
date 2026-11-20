# ৩. Package তালিকা (বিস্তারিত)

> **Version (pubspec.lock)** = বাস্তবে install হওয়া (resolved) version, `pubspec.lock` থেকে হুবহু। **Constraint (pubspec.yaml)** = developer যে সীমা লিখেছেন। "কোথায়" কলামের ফাইল তালিকা `grep "package:<name>/" lib` চালিয়ে পাওয়া (read-only)।
>
> Package বলতে: অন্যের লেখা তৈরি code-এর লাইব্রেরি, যা pub.dev থেকে নামানো হয় (package = তৈরি করা টুলবক্স)।

## ৩.১ dependencies

| Package | Version (lock) | Constraint (yaml) | কী কাজ করে | এই app-এ কোথায় / কেন | বিকল্প |
|---|---|---|---|---|---|
| `flutter` (sdk) | SDK | `sdk: flutter` | Flutter framework | সব UI | — |
| `google_fonts` | 6.3.3 | `^6.2.1` | Google Fonts runtime-এ load করে | Poppins font — `lib/core/app_text.dart`, `app_theme.dart` সহ ৪১টি ফাইলে | font ফাইল `assets/`-এ bundle করা |
| `cupertino_icons` | 1.0.9 | `^1.0.6` | iOS-ধাঁচের icon font | **unused** — `lib/`-এ কোথাও `package:cupertino_icons` import বা `CupertinoIcons` ব্যবহার নেই (grep: 0) | বাদ দেওয়া যায় |
| `geolocator` | 13.0.4 | `^13.0.2` | GPS location, permission, distance | `emergency_service.dart` (`getCurrentPosition`, `getLastKnownPosition`), `live_tracking_service.dart` (`getPositionStream`), `journey_service.dart`, `location_service.dart`, `ride_checkin_service.dart`, `battery_alert_service.dart` সহ ১৩টি ফাইল | `location` package |
| `geocoding` | 2.2.2 | `^2.1.1` | coordinate → ঠিকানা (reverse geocoding) | `sos_cloud_dispatcher.dart` (`placemarkFromCoordinates`), `live_tracking_service.dart`, `location_service.dart` | Nominatim API |
| `telephony` | 0.2.0 | `^0.2.0` | Android-এ SMS পাঠানো | `emergency_service.dart` (fallback + "I'm safe" SMS), `sos_escalation_service.dart` (stage SMS), `journey_service.dart`, `ride_checkin_service.dart`, `battery_alert_service.dart` | নিজস্ব native `SmsSender.kt` (primary SOS-এ এটাই ব্যবহৃত) |
| `audioplayers` | 6.7.1 | `^6.1.0` | audio বাজানো | `siren_service.dart` (siren loop, alarm stream), `fake_call_voice_screen.dart` (recording preview) | `just_audio` |
| `permission_handler` | 11.4.0 | `^11.3.1` | runtime permission চাওয়া/দেখা | `app_permission_service.dart`, `emergency_service.dart` (`Permission.sms`), `background_service.dart` (`ignoreBatteryOptimizations`), `notification_service.dart`, `home_screen.dart`, `safety_deadline_service.dart`, `background_reliability_screen.dart`, `fake_call_voice_screen.dart` | প্রতিটি plugin-এর নিজস্ব permission API |
| `shared_preferences` | 2.5.5 | `^2.2.2` | ছোট key-value local storage | ২১টি ফাইলে: active SOS id, contact cache, PIN hash, toggle settings ইত্যাদি | `hive`, `flutter_secure_storage` |
| `url_launcher` | 6.3.2 | `^6.2.5` | `tel:`, `sms:`, `https:`, `geo:` URL খোলা | `navigation_service.dart`, `emergency_service.dart` (`launchNativeSmsApp`), `notification_service.dart` (Call action), `intrusive_sos_dialog.dart`, `incident_room_screen.dart` সহ ১০টি | `android_intent_plus` |
| `flutter_map` | 6.2.1 | `^6.1.0` | OpenStreetMap-ভিত্তিক map widget | `map_screen.dart`, `incident_room_screen.dart`, `journey_tracking_screen.dart`, `followed_mode_screen.dart`, `active_ride_screen.dart`, `ride_details_screen.dart`, `start_journey_sheet.dart` | `google_maps_flutter` (API key + billing লাগে) |
| `latlong2` | 0.9.1 | `^0.9.0` | `LatLng` টাইপ ও দূরত্ব | flutter_map-এর সঙ্গে ১১টি ফাইলে | — |
| `firebase_core` | 3.15.2 | `^3.0.0` | Firebase initialize | `auth_service.dart` (`Firebase.initializeApp`), `main.dart` সহ ১৭টি | — |
| `firebase_auth` | 5.7.0 | `^5.0.0` | Authentication | `auth_service.dart`, এবং uid দরকার এমন ২২টি ফাইল | Supabase Auth |
| `google_sign_in` | 6.3.0 | `^6.2.1` | Google account picker | শুধু `auth_service.dart` (`GoogleSignIn(scopes: ['email','profile'], serverClientId: ...)`) | email/password auth |
| `cloud_firestore` | 5.6.12 | `^5.0.0` | NoSQL real-time database | মূল data store; ৩৪টি ফাইল | Realtime Database, Supabase |
| `firebase_messaging` | 15.2.10 | `^15.0.0` | FCM push token ও message | `main.dart` (`onBackgroundMessage`), `notification_service.dart` (`getToken`, `onMessage`), `phone_verification_service.dart` (dead file) | OneSignal |
| `flutter_local_notifications` | 17.2.4 | `^17.1.2` | device-এ local notification | শুধু `notification_service.dart` (SOS banner, safety check, status, ride) | `awesome_notifications` |
| `firebase_storage` | 12.4.10 | `^12.0.0` | ফাইল (ছবি) cloud-এ রাখা | শুধু `ride_checkin_service.dart` (`uploadRideImage`) | Cloudinary free tier |
| `firebase_crashlytics` | 4.3.10 | `^4.3.10` | crash report | শুধু `main.dart` | Sentry |
| `path_provider` | 2.1.5 | `^2.1.2` | temp/doc folder path | `fake_call_settings_service.dart` (recording folder), `ride_checkin_service.dart`, `ride_ocr_service.dart` (temp OCR ছবি) | — |
| `flutter_background_service` | 5.1.0 | `^5.0.11` | Android foreground service চালানো | শুধু `background_service.dart` (`BackgroundServiceManager`) | `flutter_foreground_task` |
| `battery_plus` | 6.2.3 | `^6.2.1` | battery % ও charging state | `battery_alert_service.dart`, `live_tracking_service.dart`, `sos_cloud_dispatcher.dart` | — |
| `crypto` | 3.0.7 | `^3.0.6` | SHA-256 hash | শুধু `pin_security_service.dart` (`sha256.convert`) | `pointycastle` (PBKDF2/bcrypt) |
| `sensors_plus` | 5.0.1 | `^5.0.0` | accelerometer | `shake_sos_service.dart`, `motion_detection_service.dart` (`accelerometerEventStream`) | — |
| `image_picker` | 1.2.4 | `^1.1.2` | camera / gallery থেকে ছবি | শুধু `ride_checkin_screen.dart` | `camera` package |
| `google_mlkit_text_recognition` | 0.13.1 | `^0.13.0` | on-device Latin OCR | শুধু `ride_ocr_service.dart` (`TextRecognizer(script: TextRecognitionScript.latin)`) | Cloud Vision (paid) |
| `flutter_image_compress` | 2.5.1 | `^2.3.0` | ছবি compress | শুধু `ride_checkin_service.dart` (`quality: 75`, `minWidth: 1280`) | `image` package |
| `flutter_tesseract_ocr` | 0.4.31 | `^0.4.31` | Tesseract OCR (বাংলা) | শুধু `ride_ocr_service.dart` (`language: 'ben'`) | — |
| `image` | 4.12.0 | `^4.12.0` | pure-Dart image processing (grayscale, crop, binarize) | শুধু `plate_image_processor.dart` | `opencv` binding |
| `record` | 6.0.0 | `6.0.0` (exact) | microphone থেকে audio record | শুধু `fake_call_voice_screen.dart` | `flutter_sound` |
| `flutter_blue_plus` | 1.34.5 | `1.34.5` (exact) | Bluetooth Low Energy scan/connect | `esp32_ble_service.dart`, `esp32_scan_sheet.dart` | `flutter_reactive_ble` |

## ৩.২ dev_dependencies

| Package | Version (lock) | Constraint | কাজ | কোথায় |
|---|---|---|---|---|
| `flutter_test` (sdk) | SDK | `sdk: flutter` | unit/widget test | `test/*.dart` (৪২টি ফাইল) |
| `flutter_lints` | 3.0.2 | `^3.0.0` | lint rule set | `analysis_options.yaml` → `include: package:flutter_lints/flutter.yaml` |
| `flutter_launcher_icons` | 0.14.4 | `^0.14.4` | app icon generate | `pubspec.yaml`-এর `flutter_launcher_icons:` block (`image_path: "assets/logo.png"`) |

## ৩.৩ Android native (Gradle) dependency — pubspec-এর বাইরে

`[source: android/app/build.gradle.kts, dependencies, line ~48-56]`
- `com.android.tools:desugar_jdk_libs:2.1.4`
- `com.google.firebase:firebase-bom:33.16.0` → `firebase-firestore`, `firebase-auth` (Kotlin `GuardianAlertService`-এর জন্য)
- `androidx.core:core:1.13.1`

Gradle plugins `[source: android/settings.gradle.kts]`: AGP `com.android.application` **8.11.1**, `com.google.gms.google-services` **4.4.4**, `com.google.firebase.crashlytics` **3.0.2**, Kotlin `org.jetbrains.kotlin.android` **2.2.20**; Gradle wrapper **8.14** `[source: android/gradle/wrapper/gradle-wrapper.properties]`।

## ৩.৪ Cloud Functions dependency

`[source: functions/package.json]` — `firebase-admin ^12.0.0`, `firebase-functions ^5.0.0`, Node engine `"18"`। (Spark plan-এ deploy করা যায় না — বিস্তারিত `06_ISSUES_BN.md`।)

## ৩.৫ সারসংক্ষেপ: unused package

| Package | অবস্থা |
|---|---|
| `cupertino_icons` | pubspec-এ আছে, code-এ ব্যবহার নেই (Flutter template-এর default) |

বাকি সব package অন্তত একটি `lib/` ফাইলে import হয়। লক্ষ্য করুন: `firebase_messaging` একটি dead ফাইলেও (`phone_verification_service.dart`) import হয়, কিন্তু `main.dart` ও `notification_service.dart`-এ সত্যিই ব্যবহার হয়।
