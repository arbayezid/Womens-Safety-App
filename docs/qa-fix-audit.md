# QA Fix Audit — Woman Guard (smart_safety)

Status: **analysis only, no source files changed.**
Audited revision: `main` @ `f6adf4d` (2026-10-31), identical to `origin/main`.
Audit date: 2026-11-03

---

## 0. Read this first: QA plan vs. code mismatches

Several things QA refers to **do not exist anywhere in this repository**. I checked `lib/`, all four local branches, `origin/main`, and the git history of `lib/`.

| QA wording | What the code actually has |
|---|---|
| "Verified Matchmaking" (Issue 3) | No screen, string, model or collection with this name in any branch or commit. |
| "Star button" to set a Primary contact (Issue 6) | No star icon anywhere. Primary is a switch in the Add Contact dialog, and that switch is ignored (see Issue 6). |
| "Scheduled Fake Call (After 10s)" (protected) | The only scheduled fake call is **"Call in 30s"** in Followed Mode (`followed_mode_screen.dart:150-182`). There is no 10 s option. |
| "Instant Fake Call — Now" (FAIL) | Home → "Fake Call" quick action (`home_screen.dart:376-378`) and Followed Mode → "Fake Call Now" (`followed_mode_screen.dart:801`). Both call the same `FakeCallDialog.show()` that the 30 s path uses. |
| "audio recording start" on SOS (protected) | **No audio is recorded anywhere.** There is no recorder package, no `RECORD_AUDIO` permission, and no `MediaRecorder`. The SOS pipeline never records. |
| "Play Historic Audio" (FAIL) | The Incident Room shows an audio card only if an `sos_alerts` doc has `audioUrl`/`audio_url`/`recordingUrl` (`incident_room_screen.dart:374-376, 507-510`). No code ever writes those fields. |

The release APK in `build/app/outputs/flutter-apk/` was built 2026-10-31 03:28, **before** the two latest commits (09:20 and 09:21). QA may have tested a different or older build, or a test plan written for another app.
**Before Issue 3 is fixed, please confirm the build QA used and send a screenshot of "Verified Matchmaking" and the "Instant Fake Call" failure.**

---

## 1. Architecture summary

| Area | Implementation |
|---|---|
| Framework | Flutter (Dart ≥3.0), Material 3, Poppins via `google_fonts` |
| State management | Hand-written singletons (`XService.instance`) exposing `ValueNotifier`s / broadcast `StreamController`s; widgets use `ValueListenableBuilder` / `StreamBuilder`. There is no Provider, Riverpod or Bloc. |
| Routing | Imperative `Navigator.push(MaterialPageRoute…)`. Global `rootNavigatorKey` (`main.dart:24`) is used for dialogs raised from services. `MaterialApp.builder` swaps the whole UI for `CamouflageCalculatorScreen` when `PinSecurityService.isCamouflageActiveNotifier` is true (`main.dart:155-165`). |
| Startup | `main.dart:40-136`: `AuthService.initialize()` (Firebase init + auth listener), Crashlytics, `PinSecurityService.initialize()`, FCM background handler, `runApp`. After the first frame: ContactSync, permissions, ESP32 BLE, NotificationService, GuardianAlertService (native), BackgroundServiceManager, then auto-resume of live tracking and ride check-in. **Journey and active SOS are restored only in `HomeScreen.initState` (`home_screen.dart:87-89`).** |
| Services (`lib/services`, 31 files) | auth, contact (cache + Firestore), contact_sync (guardian requests), emergency (SOS pipeline), sos_cloud_dispatcher, sos_escalation, journey (Safe Journey + dead-man switch + Followed Mode), ride_checkin, live_tracking, background_service, notification, guardian_alert (bridge to native), motion_detection (fall), siren, fake_call_audio, pin_security, activity (history), battery_alert, safety_report, safe_zone_repository, phone_registry, phone_verification, native_sms, esp32_ble, location, navigation, app_permission, incident, ride_ocr |
| Native Android (Kotlin) | `GuardianAlertService` (foreground service with Firestore listeners that rings guardians while the app is closed), `GuardianBootReceiver`, `AlertSirenPlayer`, `AlertRegistry` (de-dup of rung alerts), `AlertActionReceiver`, `SmsSender` + `SmsResultReceiver` (multi-SIM SMS), `FakeCallAudio` (ringtone + TTS), `NotificationChannels`. Native deps: Firebase BoM 33.16.0 (Firestore, Auth). |
| MethodChannels | `com.smartsafety.smart_safety/device`, `/guardian`, `/sms`, `/fake_call` (all registered only on the **Activity** engine, `MainActivity.kt:67-99`) |
| Background | `flutter_background_service` foreground service (`background_service.dart`). Its isolate entry `onStart` (`:18-54`) **only handles notification text and stop; it runs no safety logic.** Boot autostart is disabled (`:101`). |
| Notification channels | Native: `sos_emergency_channel`, `guardian_protection_channel`, `guardian_emergency_alerts_channel`. Dart (`notification_service.dart:229-254`): SOS v2 channel, `safety_check_channel`, `ride_checkin_channel`. **No scheduled notifications (`zonedSchedule`) exist anywhere.** |
| Android permissions | Location (fine/coarse/background), BT, SEND_SMS, READ_PHONE_STATE, CALL_PHONE, POST_NOTIFICATIONS, USE_FULL_SCREEN_INTENT, WAKE_LOCK, CAMERA, FOREGROUND_SERVICE (+location/connectedDevice/specialUse), REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, RECEIVE_BOOT_COMPLETED. **Missing: `RECORD_AUDIO`, `SCHEDULE_EXACT_ALARM`.** |
| iOS Info.plist | Location when-in-use/always, camera, photo library; `UIBackgroundModes`: location, fetch. No microphone key. |
| Key deps (`pubspec.yaml`) | firebase_core/auth/firestore/messaging/storage/crashlytics, google_sign_in, flutter_local_notifications 17, flutter_background_service 5, telephony, audioplayers, geolocator, sensors_plus, battery_plus, shared_preferences, crypto, ML Kit OCR, tesseract, flutter_map |
| Local storage | **SharedPreferences only.** No Hive, sqflite or secure storage. Firestore offline persistence is on by default. |
| Cloud Functions | `functions/index.js` defines `onConnectionRequestCreated`, `onConnectionRequestUpdated` (mutual contact writes), and `onSosAlertTriggered` (FCM). **Functions cannot be deployed on Spark**, so treat them as dead code. They must not be relied on and must not be "fixed" by deploying them. |
| Firebase Storage | Used only by `ride_checkin_service.dart:34` for plate photos. The bucket is `womens-safety-aa3ef.firebasestorage.app`, a new-style bucket. Firebase announced that Cloud Storage for Firebase requires the Blaze plan for these buckets. **Treat Storage as unavailable on Spark** (verify in the console). This matters for Issue 7 (audio). |

---

## 2. Firestore data model

| Path | Key fields | Written by | Read by | Rules |
|---|---|---|---|---|
| `users/{uid}` | uid, email, email_lowercase, displayName/name, photoUrl, phone/phoneNumber, isPhoneVerified, safetyScore, fcmToken/fcm_token, city, dob, bloodGroup, emergencyNote, lastActiveAt | `AuthService.syncUserToFirestore` (`auth_service.dart:251-283`), `updateProfile` (`:288-336`), `PhoneVerificationService` (`:199-208`) | Profile load; email lookup in `ContactSyncService.searchUserByEmail`; `SosCloudDispatcher` (uid from email) | read: **any signed-in user** (exposes blood group, DOB, emergency note: privacy risk, out of scope); create/update: owner |
| `users/{uid}/contacts/{contactId}` | id, name, email, phone, relationship, isPrimary, isBackup, contactUid, isSyncedAppUser, syncStatus (`synced`/`pending`/`offline_only`), plus snake_case duplicates, syncedAt. IDs: guardian uid, `pending_<email>`, `offline_<ms>` | Owner (add/update/delete); **the other user on accept** (`contact_sync_service.dart:753-772`) | `ContactService.bindUser` stream; SOS routing; escalation; ride check-in; fake call | read: owner; write: owner, or the user whose uid == contactId, or **anyone for `pending_*` IDs** (loose) |
| `phone_numbers/{+E164}` | uid, phoneNumber, createdAt | PhoneRegistryService | same | get only; create-once |
| `connection_requests/{senderUid_receiverUid \| senderUid_emailKey}` | sender_uid/senderId, sender_name, sender_email, receiver_uid/receiverId, receiver_email, relationship, optional_phone, isBackup, status (`pending/accepted/rejected/cancelled`), createdAt, respondedAt (camel + snake dupes) | Sender creates (`contact_sync_service.dart:467-488`); receiver accepts/rejects | Receiver listeners (4 queries), sender listener | sender/receiver read; create as sender with `pending`; receiver → accepted/rejected; sender → cancelled/pending |
| `sos_alerts/{alertId}` | senderId/sender_uid/senderUid, senderName, senderEmail, senderPhone, recipientUids[], recipientEmails[], notifiedUids, source, isDuress, note, status (`active`/`resolved`), lat/lng, location{}, address, batteryLevel, google_maps_url, triggeredAt, timestamp, recentTrail[], liveLocation, escalationLevel, escalationLog[], acknowledgedBy[], dismissedBy[], linkedRideId/linkedRide | `SosCloudDispatcher.triggerCloudSos` (`sos_cloud_dispatcher.dart:213-267`), LiveTracking, Escalation, recipients (ack/dismiss) | SosHistoryScreen, IncidentRoom, NotificationService, native GuardianAlertService | sender or recipient read; field-whitelisted updates; **delete denied** (permanent record) |
| `sos_alerts/{id}/events/{eventId}` | type, title, description, actorName, actorUid, timestamp, metadata | sender/recipients | Incident Room timeline | sender or recipient read/create |
| `journeys/{id}` | ownerId, ownerName, guardianUids[], guardianEmails[], destination*, start*, expectedArrivalAt, status, lastSafetyCheckAt, isFollowedMode, linkedSosAlertId, … | JourneyService | owner, guardians | owner write; guardian read |
| `ride_checkins/{id}` | userId, guardianIds[], guardianEmails[], plate*, rideType, expectedMinutes, status, trail… | RideCheckinService | owner, guardians | as named |
| `safety_reports/{id}` | userId, geohash6, category, verifiedCount, … | SafetyReportService | anyone | public read; any signed-in user may update |

**Indexes** (`firestore.indexes.json`): composite indexes for connection_requests (receiverId/senderId + status + createdAt), sos_alerts (recipientUids/recipientEmails + status/triggeredAt; senderId + triggeredAt), journeys, ride_checkins.

**There is no collection for user activity history.** It exists only on the device (Issue 7).

### Local SharedPreferences keys
`smart_safety_activity_logs` (activity history, **one global key, not per-user**), `contacts_cache_<uid>`, `emergency_contacts_list` (legacy), `smart_safety_is_guest`, `smart_safety_user_profile_*` (legacy), `active_sos_alert_id`, `active_journey_id`, `active_ride_checkin_id`, `sec_real_pin_hash/salt`, `sec_duress_pin_hash/salt`, `sec_pin_protection_enabled`, `sec_pin_require_on_open`, `sec_camouflage_active`, `sec_duress_active`, `pref_*` (settings, escalation delays, fall detection, siren on auto-SOS, battery prompt, etc.). Native prefs: `woman_guard_guardian_service`, `woman_guard_guardian_alerts`.

---

## 3. Auth lifecycle

**Sign-in** (`auth_service.dart:345-394`): Google → Firebase credential → guest flag false → `_loadProfileForUser` (reads `users/{uid}`, or creates it) → `ContactService.bindUser(uid)` (loads `contacts_cache_<uid>`, then Firestore stream) → `ContactSyncService.initialize()` (request listeners + **4 s heartbeat**) → `NotificationService.startSosAlertStreamListener()`. The native `GuardianAlertService` starts via `guardian_alert_service.dart:35-41` on the auth state change.

**Sign-out** (`auth_service.dart:412-456`) clears:
1. FirebaseAuth + GoogleSignIn sessions
2. Flutter image cache
3. `ContactService.purgeOnSignOut()`: memory, `emergency_contacts_list`, all `contacts_cache_*` keys (`contact_service.dart:648-672`)
4. `ContactSyncService.purgeOnSignOut()`: listeners, pending requests in memory
5. **`ActivityService.clearHistory()` → writes `[]` to `smart_safety_activity_logs` (`auth_service.dart:433`, `activity_service.dart:224-232`). This is the Issue 7 data loss.**
6. Profile reset to guest; removes `smart_safety_user_profile_*`; guest flag = true
7. NotificationService and GuardianAlertService listeners stop through their own auth listeners (`notification_service.dart:344-359`, `guardian_alert_service.dart:35-41`)

**Not cleared on sign-out:** PIN hashes and camouflage/duress flags (device-level), `active_sos_alert_id`, `active_journey_id`, `active_ride_checkin_id`, `pref_*` settings, Firestore offline cache, and the native AlertRegistry. Nothing is ever deleted from Firestore on sign-out.

---

## 4. Issues: root cause and proposed fix

### Issue 1: Guardian request is two-way

> **Implemented 2026-11-03, with a lighter design than proposed below.** No `protecting` subcollection.
> "People I Protect" is derived from accepted `connection_requests` addressed to the user
> (`ContactSyncService.protectedPeopleNotifier`), and the migration removes only reverse entries
> proven by request records (`lib/services/guardian_link_logic.dart`,
> `lib/services/guardian_link_migration_service.dart`). Rules tightened in `firestore.rules`.

**What exists**
- `ContactSyncService.sendConnectionRequest` (`contact_sync_service.dart:387-530`): A creates the request and writes B as a pending contact in `users/A/contacts/B`.
- `ContactSyncService.acceptRequest` (`:698-826`), run on B's device:
  - `:753-772` writes B into `users/A/contacts/B` (correct)
  - **`:784-803` writes A into `users/B/contacts/A` with `relationship: 'Safety Ward'`, `isSyncedAppUser: true`**
  - **`:811-823` also adds A to B's local contact cache**
- `functions/index.js:92-190` (`onConnectionRequestUpdated`) does the same mutual write server-side (`:120-160`). It is not deployable on Spark, but if it was ever deployed it produced the same data.
- Delete path `_cleanUpAfterDelete` (`:931-957`) "mutually unlinks" by deleting `users/<partner>/contacts/<me>`.

**Root cause.** Every consumer treats `users/{uid}/contacts` as "my guardians". SOS routing (`emergency_service.dart:269-319`), the cloud fallback (`sos_cloud_dispatcher.dart:92-137`), escalation (`sos_escalation_service.dart:186-188`), journey/ride guardian lists and the fake caller all read it. Because `acceptRequest` puts the requester A into the guardian B's `contacts`, B's SOS now goes to A. The relationship label "Safety Ward" is cosmetic, and no code filters on it.

**Proposed fix (data model change, with migration)**
1. `acceptRequest`: keep step `:753-772` (B into A's list). **Remove `:784-803` and `:811-823`.** Write A instead to a new subcollection **`users/B/protecting/A`** (`{uid, name, email, phone, acceptedAt, requestId}`) so B can still see "People I protect" without A being a guardian.
2. `_cleanUpAfterDelete`: when A deletes guardian B, delete `users/B/protecting/A` instead of `users/B/contacts/A`. Otherwise A deleting B would wrongly delete A from B's own guardian list if B had independently added A.
3. `firestore.rules`: add `match /users/{userId}/protecting/{wardId} { allow read: if isOwner(userId); allow write: if isOwner(userId) || isOwner(wardId); }`. Keep the existing contacts rule, because B still needs to write `users/A/contacts/B`.
4. `functions/index.js:142-160`: remove the reverse write so a future Blaze deploy can't reintroduce the bug.
5. Optional UI: a read-only "People I protect" section in the Contacts screen.

**Migration (client-side, one-time, free).** It runs after sign-in and is guarded by a `users/{uid}.migrations.oneWayGuardians` flag.
- Query `connection_requests where senderId == me and status == 'accepted'` (index exists). This gives the set of guardians **I** requested, by receiver uid and receiver email.
- For each doc in `users/me/contacts` with `isSyncedAppUser == true` and `relationship == 'Safety Ward'` whose uid/email is **not** in that set, it was created by the reverse write. **Copy** it to `users/me/protecting/{id}`, then delete it from `contacts` and from the local cache.
- Contacts I requested myself are untouched. If both people requested each other, both links stay (genuine two-way).
- No data is destroyed: the reverse link moves to `protecting`. Past `sos_alerts` keep their `recipientUids`, so history is unaffected.

**Protected features sharing this code:** Add contact, Delete contact, SOS dispatch / SMS (consumers of `contacts`), Multi-device SOS dialog (B still receives A's SOS because `users/A/contacts/B` is kept), Safe Journey / Ride guardian lists.
**Avoiding breakage:** keep `users/A/contacts/B` exactly as today; don't touch the SOS routing code; the migration only removes docs that A provably never requested. Tests: `test/sos_sms_and_contact_delete_test.dart`, `test/contact_service_test.dart` plus new tests for accept and migration.

**Spark:** fully client-side. Rules deploys are free.

---

### Issue 2: Alerts and timer escalations do not fire in background, locked or closed

**What exists.** All time-based safety logic runs on Dart `Timer`s in the **UI isolate**:
- Safe Journey monitor: `journey_service.dart:623-628` (every 30 s). The 60 s dead-man countdown is at `:735-769`, and auto-SOS at `:824-861`. Time triggers: delay = `expectedArrivalAt + 5 min`; Followed Mode every 10 min since `lastSafetyCheckAt` (`:200-287`).
- SOS escalation stage 1 (3 min) and stage 2 (8 min): `sos_escalation_service.dart:131-139`.
- Ride overdue: `ride_checkin_service.dart:465-470` (30 s periodic), threshold `createdAt + expectedMinutes + 10`.
- Journey restore happens only in `HomeScreen.initState` (`home_screen.dart:87-89`).
- The background service isolate `onStart` (`background_service.dart:18-54`) does **nothing** except update its notification.
- There are no `zonedSchedule`/AlarmManager/WorkManager calls anywhere.
- The SMS and Fake-call MethodChannels are registered only on the Activity engine (`MainActivity.kt:67-99`).

**Root cause.** When the task is swiped away, the process is killed, or the device dozes, the UI isolate and its timers stop. Nothing is armed with the OS. When the user reopens the app, `restoreActiveJourney()` restarts the monitor, sees the overdue state and fires the check. That is exactly QA's observation: "alerts only appear when the app is opened". The guardian side works while closed, because native `GuardianAlertService` listens to Firestore. The gap is on the **user (sender) side**: it never writes the escalation, so guardians are never notified.

**Proposed fix (free, Android-native)**
1. New Kotlin `SafetyDeadlineScheduler` + `SafetyDeadlineReceiver`, with a MethodChannel `…/deadline` exposing `arm(kind, id, fireAtMs, payload)`, `disarm(kind, id)` and `claim(kind, id)`.
   - Kinds: `journey_delay`, `followed_check`, `ride_overdue`, `sos_stage1`, `sos_stage2`.
   - Uses `AlarmManager.setAlarmClock`, which is exact and doze-exempt, when `canScheduleExactAlarms()`; otherwise it falls back to `setExactAndAllowWhileIdle` / `setAndAllowWhileIdle`.
   - The payload (SMS recipients, backup recipients, message, recipient uids/emails, sender name) is persisted in native prefs so the receiver works with no Dart engine.
2. When an alarm fires:
   - **Step A:** post a full-screen, high-priority "Are you safe?" notification with an **I'm safe** action (handled natively; it disarms the alarm and records the time for Dart to sync to Firestore on next launch), and arm a +60 s step B. This mirrors the in-app 60 s countdown.
   - **Step B:** if the alarm is still armed, send the SOS SMS through the existing native `SmsSender`. Create an `sos_alerts` doc through the native Firestore SDK (auth persists natively) with the same fields as `SosCloudDispatcher`. Guardians' `GuardianAlertService` then rings, closed or not. Then show "SOS dispatched".
   - For SOS stages, step A is skipped. Stage 1 sends backup and update SMS and updates `escalationLevel`/`recipientUids`, as the Dart `_executeStage1` does.
3. Dart changes are only arm/disarm calls at existing lifecycle points: journey start/extend/confirmSafe/complete/cancel, Followed Mode start and each check, ride start/end, SOS escalation start/stop (resolved, acknowledged, Mark Safe).
4. **No double SOS.** Both the in-app timer and the native alarm call `claim(kind,id)` (the same pattern as the existing `AlertRegistry.tryClaim`). Only the first one escalates.
5. Re-arm after reboot from `GuardianBootReceiver` (native prefs hold the deadlines).
6. Manifest: add `SCHEDULE_EXACT_ALARM` plus a one-time settings prompt next to the existing battery-optimisation prompt. **Do not** use `USE_EXACT_ALARM` (Play policy restricts it to alarm and calendar apps).
7. Move journey restore from `HomeScreen.initState` to startup (`main.dart` post-frame), so a cold start from a notification also resumes it.

**Limits to state honestly**
- Location-based journey triggers (route deviation, inactivity, GPS lost) need live GPS. They cannot be evaluated by an alarm and stay in-app/foreground-service only. They could move into the background-service isolate later (phase 2).
- A force stop from Settings cancels all alarms (Android design). Some OEMs (MIUI, aggressive Samsung modes) also kill on swipe. The existing reliability prompts mitigate this.
- **iOS:** an app cannot send SMS or run code at an arbitrary time when closed. The best free option is `flutter_local_notifications.zonedSchedule` reminder notifications ("Your journey check-in is overdue — open Woman Guard"). There is no auto-SOS on iOS when the app is killed.

**Protected features sharing this code:** Safe Journey start, periodic check-in, missed check-in auto-SOS and end journey; SOS trigger; Mark Safe with PIN; fall detection (only if the shared notification code is touched; `motion_detection_service.dart` should not be).
**Avoiding breakage:** in-app timers and dialogs stay byte-for-byte the same. Only add arm/disarm/claim calls. The native SOS document must match `SosCloudDispatcher`'s schema and pass the existing `sos_alerts` create rule (sender uid = auth uid).

**Spark:** a server-side scheduler would need Cloud Functions or Cloud Scheduler (Blaze). The device-side AlarmManager is free.

---

### Issue 3: "Verified Matchmaking" is unclear

**What exists:** nothing by that name (see §0). The closest things in the code that "show profiles" or say "verified":
- **Add Contact → email lookup** (`contact_sync_service.dart:307-381`) returns a registered user's name, email, phone, photo and `safetyScore` (hard-coded default 90; 95 after phone verification, `phone_verification_service.dart:206`).
- **Phone verification** (`phone_verification_service.dart`) sets `users/{uid}.isPhoneVerified = true` after a Firebase Phone Auth OTP.
- Community reports show "Verified by N women" (`map_screen.dart:1436`; `verifiedCount` is incremented by any user).
- Safe zones carry `isVerifiedCheckpoint` (static catalogue).

**Root cause:** cannot be determined from this codebase. Either QA tested a different build, or a feature was renamed or removed.

**Proposed next step:** get a screenshot or build ID. If it is the contact lookup, define "Verified" as "phone number confirmed by OTP (`isPhoneVerified == true`)", show that badge with a one-line explanation, and remove the meaningless `safetyScore` number.
**Spark note:** Firebase Phone Auth SMS has a limited free tier on Spark (verify the current limits). If the "no limited-quota services" rule is strict, verification by SMS OTP itself conflicts with it.
**Related privacy risk (not in scope):** `users/{uid}` is readable by any signed-in user, including blood group, DOB and emergency note.

---

### Issue 4: Fake Call shows the user's own name; no caller choice

**What exists:** `fake_call_dialog.dart:50-61`. The caller is the **first `isPrimary` contact, otherwise the first contact, otherwise "Mom"**, and the phone is that contact's phone or `+880 1711-000001`. There is no caller setting or parameter (`FakeCallDialog.show(context)` takes none, `:19`).

**Root cause**
- There is no caller selection at all.
- Every contact is saved with `isPrimary: true` (see Issue 6), so the "primary" is effectively whichever contact comes first.
- A guardian's display name is copied from **their Google profile** on accept (`contact_sync_service.dart:759`, `currentUserName`). If QA used two accounts of the same person (same Google display name), the caller shows the user's own name.
- With the Issue 1 reverse link, a guardian's device also lists the protected person as its own contact.

**"Instant Fake Call — Now" FAIL:** both instant entry points call the same code as the passing 30 s path. The failure cannot be reproduced statically, so we need QA's steps, build and logcat (`[FakeCallAudio]` lines).

**Proposed fix (no Firestore schema change)**
- Add an optional `caller` parameter to `FakeCallDialog.show(context, {FakeCaller? caller})`. When it is omitted, use the saved preference.
- Presets: Mom, Dad, Brother, Sister, Husband, Police Station, Office, Custom (name + optional number), and "My primary contact" (today's behaviour, now opt-in). Default: **Mom**.
- Store the preference per user in `users/{uid}.fakeCall = {preset, name, phone}`. This is a new optional field on an existing owner-writable doc, so no rules change is needed. Cache it locally for offline.
- Add a caller picker plus **Call now / In 10 s / In 30 s** on a small sheet opened from the Home "Fake Call" quick action. Followed Mode's existing "Call in 30s" and "Fake Call Now" keep their exact behaviour and simply use the saved caller.
- The scheduled call uses a `Timer`, which only works while the app is open. That matches today's behaviour.

**Protected features sharing this code:** Scheduled Fake Call; answer slider, timer and audio (all inside `FakeCallDialog`). Only the two `late String` initialisers change source, and the rest of the widget is untouched.

---

### Issue 5: Fake Call voice is English, synthetic TTS

**What exists:** `fake_call_audio_service.dart:15-26` has an English script and an optional `assets/sounds/fake_call_voice.mp3`, which is **not bundled** (`assets/sounds/` holds only `siren.mp3`). Native `FakeCallAudio.kt:108-127` plays the asset if present, otherwise TTS. `selectEnglishVoice` (`:279-287`) forces en-US, en-UK or English. The error snackbar tells users to install an *English* TTS voice (`fake_call_dialog.dart:103-115`).

**Root cause:** there is no recorded voice, and the TTS fallback is hard-coded to English.

**Proposed fix (free)**
1. **Primary: real recorded Bangla voices.** Record 2–3 minute natural conversations (with pauses) by real people, one per persona (Mom, Dad, Police Station, generic). Bundle them as `assets/sounds/fake_call/<preset>_bn.mp3` (mono, 48–64 kbps, about 1 MB each). Pass the per-caller `assetPath` through the existing channel argument; no native API change is needed.
2. In `playVoiceAsset` (`FakeCallAudio.kt:189-224`), set `isLooping = false` for long clips (or loop only after a long silence). A short loop sounds artificial.
3. **Fallback:** a Bangla script and a `bn-BD` → `bn-IN` → English locale order in `selectEnglishVoice` (Google TTS ships free offline Bengali voices). Update the snackbar text.
4. Custom callers use the generic Bangla clip.

**Protected features sharing this code:** Fake Call answer audio and ringtone. `startRinging` and `stopAll` are untouched; only the asset and locale selection change.
**Spark / free:** Google Cloud TTS and other neural TTS APIs need billing or have quotas, so they are excluded. **I need from you (or the team):** the recorded clips, because no truly realistic free voice can be generated.

---

### Issue 6: No Star / Primary control

> **Implemented 2026-11-04, differently from the proposal below.** The single primary is stored
> under a new key `isPrimaryContact`, because the legacy `isPrimary` is `true` on every existing
> contact and is still written as `true` by guardians on older builds. Existing contacts are not
> primary. SOS routing **does** now change order, but not membership: the primary is first in the
> SMS and in-app recipient lists (`ContactService.primaryFirst`). Ride check-in still preselects
> all regular contacts. Tests: `test/primary_contact_test.dart`.

**What exists**
- Add Contact dialog switch "Mark as Primary Emergency Contact" (`add_contact_dialog.dart:32, 483-501`). **`_isPrimary` is never passed on**: the calls at `:86-93`, `:119-126` and `:165-171` don't include it.
- `sendConnectionRequest` and `saveOfflineContact` hard-code `isPrimary: true` (`contact_sync_service.dart:508, 557`). `acceptRequest` forces `isPrimary: true` (`:766`).
- Contacts screen groups by `isPrimary` (`contacts_screen.dart:131-133`) and shows a red dot or "SOS" chip (`:867-880, :900-915`). The card actions (`:1080-1128`) have sync, call, SMS, edit-phone and delete, but **no star or primary toggle**.
- `ContactService.updateContact` (`contact_service.dart:532-578`) already supports the change.

**Root cause:** the UI control doesn't exist, the dialog switch is dead, and the service forces every contact to primary.

**Proposed fix**
- Add a star `_ActionIconBtn` on `_ContactCard` (filled when primary). It calls `ContactService.updateContact(c.copyWith(isPrimary: !c.isPrimary))`. On the guardian side the write goes to the owner's own `users/me/contacts/X`, which the owner may write.
- Pass `isPrimary` through `sendConnectionRequest`/`saveOfflineContact` as a new optional param, default `true` to keep current callers unchanged. Store it on the `connection_requests` doc (new optional field, default `true` when absent). In `acceptRequest` (`:766`) write the request's value instead of a literal `true`.
- **Semantics (honest):** today `isPrimary` does **not** change SOS routing. All non-backup contacts get the SOS (`emergency_service.dart:269-292`). Primary only affects list order, the fake caller and ride check-in preselection. Keep routing unchanged (protected), and change the dialog subtitle from "Receives highest priority in the SOS broadcast list" to "Shown first; all non-backup contacts still receive SOS".
- **Migration:** none. Existing docs keep `isPrimary: true`, so they appear exactly as now.

**Protected features sharing this code:** Add contact, Delete contact (same card widget), SOS routing (reads `isPrimary` only for `getEmergencyPhoneNumbers(primaryOnly:)`, which **nothing calls**).

---

### Issue 7: Alert history lost after logout/login; View SOS History / Play Historic Audio FAIL

**What exists**
- "Safety & Alert History" (Settings `settings_screen.dart:134-144, 956-992`) and Profile "Recent Activity" with the alert count (`profile_screen.dart:334-341, 717-799`) both read `ActivityService`. That service stores up to 50 items **only** in SharedPreferences under one global key `smart_safety_activity_logs` (`activity_service.dart:13, 49-104`).
- `AuthService.signOut()` calls `ActivityService.clearHistory()` (`auth_service.dart:433`), which writes `[]`. A reinstall also wipes SharedPreferences.
- First launch seeds **fake sample items** ("Configured 3 trusted guardian contacts", etc.; `activity_service.dart:20-45`).
- "SOS Alert History" (`sos_history_screen.dart`) reads the durable `sos_alerts` collection (3 queries merged, `:79-115`).
  - Bug: `mergeAndDeduplicateStreams` forwards **any one query's error** with `controller.addError` (`:48-50`). Flutter's `StreamBuilder` then replaces the snapshot with an error snapshot, so `snapshot.data` becomes null and the list renders **empty** (`:226-231`, only a debugPrint).
  - Likely trigger: the `recipientEmails` query fails rules when the auth token's email differs in case, or the network fails.
- Audio: see §0. It was never recorded or uploaded.

**Root cause**
1. History is device-local and is deliberately wiped on sign-out.
2. The SOS History screen hides all results when any one of its 3 listeners errors.
3. Audio recording and playback are not implemented.

**Proposed fix**
1. **Persist activity per user in Firestore:** `users/{uid}/activity_logs/{id}` (same fields as `ActivityItem`). Add a rule `allow read, create, delete: if isOwner(userId); allow update: if false;`.
   - `ActivityService` keeps its public API (`logActivity`, `logSOS`, …) unchanged. It writes local first (instant, offline), then fire-and-forget to Firestore, so it never blocks or throws into the SOS path.
   - On sign-in, load the last 50 from Firestore and merge by id.
   - The local cache key becomes per-user (`smart_safety_activity_logs_<uid>`).
   - On sign-out, clear only the in-memory list and local cache, never Firestore. The user-initiated "Clear" button keeps deleting.
2. **Migration:** on the first sign-in after the update, if the legacy global key has items, upload them to the **current** user (excluding the seeded `init_*` items), then delete the legacy key. Stop seeding fake defaults for new installs.
3. **Alert count** on Profile/Settings: derive it from `sos_alerts where senderId == uid` (durable), with the local count as the offline fallback.
4. **SOS History:** treat each query's error independently (keep the last good data per stream, log the error), and show a small "some alerts couldn't load" banner instead of an empty list. This is read-only; no data model change.
5. **Audio evidence (new feature, needs your decision).** Not implemented today. Free options:
   - (a) Record locally with the `record` package (+`RECORD_AUDIO`, iOS mic key) into app documents, keyed by alertId, and play it from history. Survives logout (we no longer wipe it) but **not a reinstall**.
   - (b) Additionally upload low-bitrate Opus (16 kbps, about 120 KB/min) as chunked documents in `sos_alerts/{id}/audio_chunks` (each <1 MiB). This survives reinstall and stays within Spark Firestore limits for short clips (cap at 2–3 min per alert).
   - Firebase Storage is **not** an option on Spark (see §1).

**Protected features sharing this code:** One-tap SOS (calls `ActivityService.logSOS`, `emergency_service.dart:541`), Mark Safe (`:162-171`), Siren, Fake Call, contact add/delete, journey confirm/extend (all log activity). Google Sign-In and sign-out.
**Avoiding breakage:** no `ActivityService` method signature changes. The Firestore write is `unawaited` with try/catch. Sign-out keeps purging everything else exactly as now.

---

## 5. Shared-code risk list

| File | Issues | Protected features that use the same code | Guard |
|---|---|---|---|
| `lib/services/contact_sync_service.dart` | 1, 6 | Add contact, Delete contact, Multi-device SOS (guardian links) | Keep sender-side writes identical; new params default to current values; tests for accept, delete and migration |
| `lib/services/contact_service.dart` | 1 (migration cache), 6 | Add/Delete contact, SOS routing, Mark Safe SMS | No change to `getContacts`/routing; only `updateContact` reused |
| `lib/models/contact_model.dart` | (none required) | everything contact-based | Prefer no change |
| `lib/screens/contacts_screen.dart` | 1 (optional "People I protect"), 6 | Add/Delete contact | Add one button; don't reorder existing actions |
| `lib/widgets/add_contact_dialog.dart` | 6 | Add contact | Pass one more argument |
| `firestore.rules` | 1, 7 | All Firestore features | Only **add** `protecting` and `activity_logs` matches; no edits to existing blocks; test with the emulator before deploying |
| `functions/index.js` | 1 | none (not deployed) | Remove the reverse write only |
| `lib/services/journey_service.dart` | 2 | Safe Journey start, check-in, auto-SOS, end | Only arm/disarm/claim calls at existing lifecycle points |
| `lib/services/sos_escalation_service.dart` | 2 | SOS trigger, Mark Safe | arm/disarm at start/stop; claim before `_executeStage1/2` |
| `lib/services/ride_checkin_service.dart` | 2 | (ride check-in, not in protected list) | arm/disarm only |
| `lib/services/emergency_service.dart` | 2 (disarm in `markSafe`) | One-tap SOS, SMS dispatch, Mark Safe | One disarm call in `markSafe`; **no changes to `triggerEmergency`** |
| `lib/screens/home_screen.dart` | 2 (restore moved), 4 (quick-action sheet) | SOS button, Mark Safe, Siren, Fake Call | Move one call; replace one `FakeCallDialog.show` call with a sheet |
| `lib/main.dart` | 2 | App startup | Add `restoreActiveJourney()` in the post-frame block |
| `android/.../MainActivity.kt` | 2 | SMS, Fake Call, Guardian channels | Register one new channel only |
| new `SafetyDeadline*.kt`, `GuardianBootReceiver.kt`, `AndroidManifest.xml` | 2 | Guardian alerts (boot receiver) | Additive; keep the existing guardian restart logic first |
| `android/.../SmsSender.kt` | 2 (reused, not modified) | Emergency SMS | Call the existing `sendAsync` only |
| `lib/services/notification_service.dart` | 2 (iOS zonedSchedule) | Multi-device SOS dialog, safety-check notification | Additive methods only |
| `lib/widgets/fake_call_dialog.dart` | 4, 5 | Scheduled fake call, answer slider, timer, audio | Change only the caller source and asset path |
| `lib/services/fake_call_audio_service.dart`, `FakeCallAudio.kt` | 5 | Fake Call audio | Locale order + per-caller asset; ringing untouched |
| `lib/screens/followed_mode_screen.dart` | 4 | (Followed Mode "Call in 30s") | No change needed; it inherits the saved caller |
| `lib/services/activity_service.dart` | 7 | Called by SOS, Mark Safe, Siren, Fake Call, contacts, journey | API frozen; cloud write non-blocking |
| `lib/services/auth_service.dart` | 7 | Google Sign-In, Guest Mode, sign-out | Replace one line (`clearHistory` → memory-only purge) |
| `lib/screens/sos_history_screen.dart` | 7 | (View SOS History) | Per-stream error isolation only |
| `lib/screens/profile_screen.dart`, `settings_screen.dart` | 7 | none protected | Read-only changes |
| `test/*` | all | — | Update `activity_service_test`, `contact_service_test`, `sos_sms_and_contact_delete_test`, `sos_hardening_test`; add new tests |

---

## 6. Recommended implementation order

1. **Issue 7a/b: history persistence + SOS History error isolation.** Low risk, highest user value, and it unblocks QA's history checks. Includes the `activity_logs` rule and the legacy upload migration.
2. **Issue 6: Primary star.** Small, isolated UI change plus one passthrough param.
3. **Issue 4: Fake Call caller selection** (plus Call now / 10 s / 30 s). Get QA's repro of "Instant — Now" first.
4. **Issue 1: one-way guardians.** Data model change: `protecting` subcollection, rules, guarded client migration, delete-path update. Run it on a test project with copied data first.
5. **Issue 5: Bangla voice.** Needs recorded clips from you; the code side is small.
6. **Issue 2: background deadlines.** Largest change (native Kotlin, exact-alarm permission). Do it after 1, so alarm payloads use the corrected one-way guardian list.
7. **Issue 3: blocked** until the build and screenshot are confirmed. **Audio evidence (7c)** is a new feature that needs your choice between options (a) and (b).

## 7. Open questions for you

1. Which build or APK did QA test? (See §0 for the mismatches.)
2. A screenshot of "Verified Matchmaking"?
3. Audio evidence: local-only (a), or local plus Firestore chunks (b)? And what maximum length?
4. Can you provide recorded Bangla voice clips (which personas)?
5. Is a one-time "Allow exact alarms" settings prompt acceptable (Android 14+ requires the user to grant it)?
