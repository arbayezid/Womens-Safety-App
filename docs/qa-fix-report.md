# QA Fix Verification Report — Woman Guard (smart_safety)

Date: 2026-11-05
Code verified: `main` @ `f6adf4d` (the audited revision) **plus all uncommitted changes in the working tree**.
All fixes for Issues 1, 2, 4, 5, 6 and 7 are uncommitted; nothing was committed or pushed during verification.
Audit this report checks: [`docs/qa-fix-audit.md`](qa-fix-audit.md).

## How to read the Result column

No physical phone or emulator was used in this verification. **Pass** means all of the following checks passed:

- `flutter analyze`: no issues.
- `flutter test`: **255 / 255 passed**, 27 test files.
- Release APK built (`flutter build apk --release`).
- Every changed line since `f6adf4d` was reviewed against the issue's acceptance tests and the protected-feature list.

Anything that only a real phone can prove (two devices, app killed, screen locked, real SMS) is marked
"device test pending" in Notes. Section 4 gives the manual steps. **Fail** means the requirement is not met in the current code.

## 1. Build and static checks

| Check | Result | Notes |
|---|---|---|
| `flutter analyze` | Pass | No issues found. |
| `flutter test` (full suite) | Pass | 255 tests passed, 0 failed. Includes 20 new Fake Call tests, 17 guardian-link tests, 10 safety-deadline tests, 9 primary-contact tests, 8 SOS history and evidence tests, and 15 activity-history tests. |
| Release APK | Pass | `build/app/outputs/flutter-apk/app-release.apk`. The headless Dart entry point `safetyDeadlineBackgroundMain` has `@pragma('vm:entry-point')`, so release tree-shaking keeps it. |
| `firestore.indexes.json` deployable | Pass (after fix) | **Fixed during verification:** removed a single-field "composite" index on `users.phoneNumber`. The Firestore API rejects this kind of index with `400 this index is not necessary`, which fails the whole index deploy. No query uses it, and single-field indexes are automatic anyway. The other 16 indexes are unchanged. None of the new queries (`activity_logs`, `safety_deadlines`, `sos_evidence`, guardian-link migration) needs a composite index: each is either a single-field filter/sort or a pair of equality filters. |
| `firestore.rules` deployable | Pass (code review) | Uses only functions supported by the rules language (`string.lower()`, `string.replace(re, sub)`, `map.get()`, `exists()`, `get()`). At most 2 distinct document reads per rule evaluation, below the limit of 10. **Not compiled with the Firebase CLI**, because the CLI on this machine crashes on start (`node:fs` error). Run the dry run in §5 before deploying. |

## 2. The 7 QA issues

| ID | Scenario | Result | Notes |
|---|---|---|---|
| I1-a | A sends a guardian request to B, and B accepts: B is added to A's guardian list | Pass | `acceptRequest` writes `users/A/contacts/B` after updating the request (`contact_sync_service.dart` ~L781-800). The rules allow this only to the user who accepted an accepted request (`acceptedGuardianOf`). Unit tests: `guardian_link_logic_test.dart`. Device test pending (§4-T1). |
| I1-b | One-way: A is **not** added to B's guardian list, and B's SOS does not go to A | Pass | The reverse write was removed from both the app and `functions/index.js`. A appears for B only under "People I Protect", which is built from accepted requests (`derivePeopleIProtect`, tested). |
| I1-c | Existing two-way data is cleaned up | Pass | `guardian_link_migration_service.dart` removes a reverse entry only when the server shows no request from that partner (`planOneWayGuardianMigration`, tested). Unresolved cases are left in place, never deleted blindly. |
| I1-d | Removing a guardian ends only that direction | Pass | `deleteSyncedContact` removes the guardian from your own list first, then cleans up in the background. The partner's list is touched only for a provable legacy reverse entry. Tests: `sos_sms_and_contact_delete_test.dart`. |
| I2-a | Guardian receives an SOS siren and notification while the app is closed or the phone is locked | Pass | Native `GuardianAlertService` (foreground service with Firestore listeners) still rings via `AlertSirenPlayer` and a full-screen notification. New behaviour: the service runs only while the user protects at least one person, and an alert's notification is removed when it ends. Device test pending (§4-T2). |
| I2-b | Safe Journey / Followed Mode check-in escalates when the app is killed | Pass | Exact alarm (`SafetyDeadlines.kt`) leads to `SafetyDeadlineService` (foreground) and then the headless Dart `JourneyService.escalateFromDeadline`. A "claim" step ensures only one of the in-app timer and the native alarm sends the SOS. Device test pending (§4-T3). |
| I2-c | Ride check-in overdue escalates when the app is killed | Pass | Same mechanism (`SafetyDeadlineKind.ride`). Device test pending. |
| I2-d | SOS escalation Stage 1 (backups at 3 min) and Stage 2 (999 prompt at 8 min) run when the app is closed | Pass | Native backstops are armed per alert. `runStageFromDeadline` re-reads the alert from the server and sends nothing if it is resolved or acknowledged. Mark Safe clears both stages. The in-app stage still runs when no native deadline exists (native `claim` returns `true` for unknown IDs). Device test pending (§4-T4). |
| I2-e | Alarms survive a reboot or app update | Pass | `GuardianBootReceiver` calls `SafetyDeadlines.rescheduleAll` on BOOT_COMPLETED, MY_PACKAGE_REPLACED and the exact-alarm permission change. Deadlines are mirrored to `users/{uid}/safety_deadlines` and re-armed after a reinstall (`resyncFromCloud`). |
| I3 | "Verified Matchmaking": purpose, Verified definition, info icon, intro sheet, checklist, rename, privacy | **Fail (not implemented, blocked)** | No "Verified Matchmaking" screen, label, route or listing of other users exists in any branch, commit or file. Only `docs/qa-fix-audit.md` mentions it. The purpose cannot be determined from the code, so no change was made. **Needed from the product owner:** the build QA used, or a screenshot, or a decision between: (a) QA meant the Add Contact email lookup, so rename it and define Verified from free signals; (b) build a new opt-in "Trusted Walking Companions" feature; (c) QA meant "Verified by N women" on community reports. Related privacy findings that remain open: the email lookup sends the found user's **email and phone number** back to the searcher's phone, plus a meaningless `safetyScore` (90/95) (`contact_sync_service.dart` ~L403-410); and `users/{uid}` is readable by any signed-in user (blood group, date of birth, emergency note). |
| I4-a | Fake Call "Now" shows the chosen caller immediately, never the user's own name | Pass | The caller comes from presets or a custom name, and contacts and the profile are no longer read. A custom name equal to the user's own profile name is rejected (picker) and replaced with "Ammu" (call screen). Double-tap or overlapping calls are blocked by a single-instance guard. Widget test: `fake_call_caller_voice_test.dart`. |
| I4-b | "After 10s" rings after exactly 10 s with the chosen caller | Pass | One-shot `Timer(Duration(seconds: 10))` in `FakeCallScheduler`, which keeps running when the sheet closes or the user switches tabs. Can be cancelled. App must stay open (as before). |
| I4-c | Custom name and number shown; choice remembered after a restart | Pass | Stored in SharedPreferences (`fake_call_caller_preset`, `_custom_name`, `_custom_phone`). Unit test simulates a restart. |
| I4-d | "I'm Being Followed" Fake Call uses the same caller | Pass | Followed Mode shows "Caller: X · Change". "Fake Call Now" and "Call in 30s" load the saved caller. |
| I5-a | Voice language setting: Bangla (default) / English | Pass | Settings › Fake Call › Caller Voice Language. The English path sends exactly the original arguments (unit test). |
| I5-b | Answering plays the Bangla clip for that caller | **Pass, but real clips still needed** | The code path is verified. `assets/fake_call/bn/{ammu,abbu,bhaiya,police,office}.mp3` are **placeholders** (half a second of silence, 2 KB). Clips of 16 KB or less are skipped and the English voice plays, so a call is never silent. The acceptance test can only pass on a phone after real recordings are added. Scripts: `assets/fake_call/bn/README.md`. |
| I5-c | The user's own recording overrides the bundled clip | Pass | Settings › Fake Call › Record My Own Caller Voice: record, preview, re-record and delete per caller, with microphone permission handling (including "Open Settings"). Saved in app storage only. Priority: user recording, then bundled Bangla clip, then English (unit tested). |
| I5-d | Earpiece/Speaker toggle | Pass | Native `setSpeaker`: speaker (default, unchanged) or earpiece (`MODE_IN_COMMUNICATION` + built-in receiver). A clip resumes at the same position. Needs `MODIFY_AUDIO_SETTINGS`, a normal permission with no prompt. Device test pending (§4-T6). |
| I6-a | Star / Primary control in Add Contact and the contact list | Pass | A star toggle in Add Contact (default **off**; it used to be on for every contact) plus a primary control in the contact list. `setPrimaryContact` keeps exactly one primary and rolls back if the write is rejected. Tests: `primary_contact_test.dart`. |
| I6-b | Primary is alerted first; everyone else still alerted | Pass | `ContactService.primaryFirst` only reorders, so the same recipients are alerted (tested: "Primary contact is alerted first"). Old records, where every contact was primary, are read as "no primary" because the flag is now stored as `isPrimaryContact`. |
| I7-a | Alert history survives logout, login, reinstall and a new phone | Pass | `users/{uid}/activity_logs` (owner-only rules), merged with the per-account local cache. Logout clears only this device's copy. Tests: "Per-account history, migration and logout". |
| I7-b | Old (pre-update) history is migrated, and fake seed items are no longer created | Pass | Legacy global key uploaded to the signed-in account without the seeded `init_*` items. Tested. |
| I7-c | View SOS History: one failing query never blanks the list | Pass | Each query fails on its own. Tests: `sos_history_and_evidence_test.dart`. |
| I7-d | Play historic SOS audio | Pass | SOS audio is now recorded on the phone that raised the SOS (Settings › Record Audio During SOS, default on once the microphone is allowed). Metadata goes to `users/{uid}/sos_evidence` and the audio can be played or exported from history. The audio itself is **not uploaded**, by design (free tier), so other phones see "recorded on another device". |

## 3. Protected features

Method: every diff since `f6adf4d` was reviewed. These files are **unchanged**: `siren_service.dart`, `pin_security_service.dart`, `camouflage_calculator_screen.dart`, `motion_detection_service.dart`, `pin_input_dialog.dart`, `intrusive_sos_dialog.dart`, `incident_room_screen.dart`, `sos_cloud_dispatcher.dart`, `native_sms_service.dart`, `login_required_bottom_sheet.dart`, `journey_tracking_screen.dart`, `start_journey_sheet.dart`, `live_tracking_service.dart`, `SmsSender.kt`, `AlertSirenPlayer.kt`. No guest-guard, sign-in, 999, siren, PIN or camouflage call site was removed.

| ID | Scenario | Result | Notes |
|---|---|---|---|
| P1 | Google Sign-In | Pass | `signInWithGoogle` unchanged. Sign-in now also binds the per-account history (`ActivityService.bindUser`, not awaited, so sign-in is never blocked). Firestore offline persistence is set explicitly in a try/catch. |
| P2 | Guest restriction | Pass | `AuthGuard` / `LoginRequiredBottomSheet` unchanged, and no guard call removed. Tests: "AuthGuard Tests". |
| P3 | SOS trigger | Pass | Pipeline unchanged apart from the primary-first order (same recipients, tested) and `_postDispatchWork`, which only stores the existing follow-up future. Tests: `emergency_service_test.dart`, `sos_hardening_test.dart`. |
| P4 | Multi-device alert (guardian phones ring) | Pass | Firestore alert listeners and siren unchanged. The native service now stops for users who protect nobody, which is required by Issue 1. Accepting a request always writes `receiverId`, which is what the service listens on. Device test pending (§4-T2). |
| P5 | SMS dispatch | Pass | `NativeSmsService` / `SmsSender.kt` unchanged. Tests: "SOS SMS message format". The headless deadline run reuses the same SMS channel handler (`AppChannels.registerShared`). |
| P6 | Mark Safe | Pass | `resolveAlert` unchanged, plus a non-blocking `clearSosStages` that stops pending escalation alarms. |
| P7 | Call 999 / call the victim | Pass | Stage 2 999 prompt and incident-room call buttons unchanged. Only the backup-SMS wording changed ("Primary contacts" became "Emergency contacts"). |
| P8 | Loud Siren | Pass | `siren_service.dart` unchanged, and the Home and Followed Mode toggles are unchanged. |
| P9 | Scheduled fake call | Pass | Followed Mode "Call in 30s" timer code unchanged. Home adds "After 10s". The single-instance guard stops a second call screen opening on top of the first. |
| P10 | Fake call answer (Accept, timer, audio) | Pass | Accept button and call timer unchanged (widget test: 00:00, then 00:02 after 2 s). Ringtone and vibration (`startRinging`) unchanged. Audio now picks a voice per caller. The original English audio is still the fallback, with byte-identical arguments (unit test). **Note:** there is no answer *slider* in this app; answering is an Accept button. |
| P11 | Safe Journey: start journey | Pass | `startJourney` unchanged, plus arming a native backstop (not awaited). |
| P12 | Safe Journey: delay check-in prompt | Pass | `_triggerSafetyCheck` unchanged, plus a 60 s native prompt backstop. |
| P13 | Safe Journey: "I'm safe" / extend | Pass | Unchanged, plus re-arming the next deadline. A ride-overdue check that shares the dialog is cleared too. |
| P14 | Safe Journey: no response, automatic SOS (dead-man switch) | Pass | Same `_escalateJourney` (code moved, behaviour the same). `claim` stops a double SOS when the native backstop already fired. Tests: "JourneyService Math & Trigger Tests". |
| P15 | Fall detection: impact and stillness trigger the check | Pass | `motion_detection_service.dart` unchanged. Tests: `fall_detection_test.dart`. |
| P16 | Fall detection: "I'm OK" cancels | Pass | Dialog cancel path unchanged. |
| P17 | Fall detection: no response or "Send SOS now" sends SOS | Pass | "Send SOS now" first runs `claimRunningChecks()`, which only makes local platform-channel calls, catches every error and never touches the network, then calls the same `triggerEmergency`. |
| P18 | PIN setup / Real PIN | Pass | `pin_security_service.dart` and `pin_input_dialog.dart` unchanged. Tests: "PinSecurityService Pure Crypto & Logic Tests". |
| P19 | Camouflage: open the calculator disguise | Pass | `camouflage_calculator_screen.dart` and the Home entry unchanged. |
| P20 | Camouflage: exit with Real PIN (duress PIN sends a silent SOS) | Pass | Unchanged. |
| P21 | Add contact | Pass | Same three paths (registered user request, invite, offline). The Primary switch now defaults to **off**, as Issue 6 required. |
| P22 | Delete contact | Pass | Removes from your own list first and stays deleted (tests: "Contact deletion stays deleted"). Cleanup is now one-way, as Issue 1 required. |

QA's own wording for the 4 Safe Journey, 3 Fall detection and 2 Camouflage test cases is not in the repository. Rows P11-P20 follow those features' flows.

## 4. Remaining limitations

1. **OEM battery killers** (Xiaomi/MIUI, Oppo/ColorOS, Vivo, Realme, Huawei, some Samsung modes) can still stop the guardian foreground service or delay exact alarms. Settings › Background Alerts Setup walks users through auto-start, battery "No restrictions" and exact alarms, but the app cannot force these settings.
2. **Force stop** (Settings › Apps › Force stop) cancels all alarms and services until the app is opened again. This is an Android rule and no app can work around it.
3. **Exact alarms on Android 14+** need the user to grant "Alarms & reminders". Without it, alarms are inexact and may fire minutes late.
4. **Headless escalation needs network** for Firestore (journey and alert re-checks, cloud alert). SMS still goes out when the app has `SEND_SMS` permission and the alert data was cached.
5. **Fake Call:** the scheduled call ("After 10s", "Call in 30s") only fires while the app is open, as before. Bangla clips are placeholders until real recordings are added (I5-b). A custom caller uses the Bhaiya clip unless the user records one. The caller preference is per phone, not synced.
6. **SOS audio evidence** stays on the recording phone (by design, no paid Storage). Uninstalling the app deletes it unless it was exported.
7. **Issue 3 is blocked**, along with its privacy findings (I3 row).
8. **Billing (Spark plan):** the core safety path needs **no billing**: Firestore, Google Sign-In, FCM, Crashlytics, on-device SMS and exact alarms. Three pre-existing, non-core items do:
   - **Cloud Functions** (`functions/index.js`) need Blaze. The app already does every write itself, so **do not deploy functions** (use `--only firestore`).
   - **Ride check-in plate photo upload** uses Firebase Storage (`*.firebasestorage.app` bucket). Firebase now requires Blaze for Cloud Storage buckets; check the console. On failure the upload returns null and the ride check-in continues without a photo.
   - **Phone number verification** uses Firebase Phone Auth SMS, which has a limited free quota. The audit flagged this before. It was not changed.

## 5. Deploy steps (no billing)

```
firebase deploy --only firestore:rules,firestore:indexes --project womens-safety-aa3ef --dry-run
firebase deploy --only firestore:rules,firestore:indexes --project womens-safety-aa3ef
```
Run the dry run first: it compiles the rules, which could not be done in this environment. Do **not** run a plain `firebase deploy`, because it would try to deploy Functions and fail on Spark.

## 6. Manual 2-device test steps

Setup: Phone **A** (protected person) and phone **B** (guardian), each with the release APK and a different Google account. On both: allow notifications, location, SMS and microphone; Settings › Background Alerts Setup all green (battery unrestricted, exact alarms allowed).

**T1. One-way guardian (I1)**
1. On A: Contacts › Add › B's email › Send request. On B: accept it.
2. A's contact list shows B. B's contact list does **not** show A; B sees A under "People I Protect".
3. On B: trigger SOS. A must **not** ring (unless A separately added B as a guardian and B accepted).
4. On A: delete B. A's list no longer shows B, and B's "People I Protect" no longer shows A after a refresh.

**T2. Closed or locked guardian alert (I2-a, P4)**
1. Set up as in T1 (B guards A). Remove B's app from Recents and lock B's screen.
2. On A: press SOS. Within about 10 s, B rings (siren plus full-screen alert) on the lock screen.
3. On A: Mark Safe. B's siren stops and its notification disappears.
4. Reboot B without opening the app, then repeat step 2. B should still ring.

**T3. Safe Journey with the app killed (I2-b, P11-P14)**
1. On A: start a Safe Journey with an arrival time 2 minutes from now, then remove A from Recents.
2. At the arrival time, A shows the "are you OK?" notification. Ignore it for 60 s.
3. The SOS goes out: B rings, SMS goes to A's contacts, and A's history shows the SOS.
4. Repeat, tapping "I'm safe" on the notification: no SOS is sent and the next check-in is scheduled.

**T4. SOS escalation with the app closed (I2-d)**
1. On A: have one regular contact (B) and one **backup** contact with a phone number. Press SOS, then remove A from Recents. Do **not** acknowledge on B.
2. At about 3 min the backup gets the escalation SMS. At about 8 min A shows the notification "8 minutes have passed without a response. Tap here to call 999".
3. Repeat, but acknowledge on B within 3 min: nothing escalates.

**T5. Fake Call (I4, P9, P10)**
1. Home › Fake Call › Ammu › **Now**: rings at once showing "Ammu / Mobile". Accept: the timer runs from 00:00.
2. Fake Call › Custom "Rina Apu", "+880 1711-223344" › **After 10s**: rings at 10 s with that name and number. Force-stop, reopen: the picker still has Rina Apu.
3. Followed Mode: the card shows "Caller: Rina Apu". "Fake Call Now" and "Call in 30s" use it.
4. Typing your own profile name as a custom caller is rejected.

**T6. Fake Call voice (I5)**
1. Settings › Fake Call › Caller Voice Language = Bangla. With placeholder clips, Accept plays the English voice. After real clips are added (over 16 KB) and the app is rebuilt, the caller's Bangla clip plays, then pauses about 4 s and repeats.
2. Record My Own Caller Voice › Ammu › Record (15 s) › Stop & Save › Preview. A call from Ammu now plays your recording, even with English selected.
3. During a call, tap Speaker: the voice moves to the earpiece and the label shows "Earpiece". Tap again to go back to the loudspeaker.

**T7. History persistence (I7)**
1. On A: trigger and resolve an SOS, run a fake call, then log out and log in. The history is still there.
2. Uninstall and reinstall A, then sign in: the SOS and the routine history return. SOS audio shows "recorded on another device / not on this phone" unless it was exported.
3. Sign in on a second phone with A's account: the same history appears.

**T8. Primary contact (I6)**
1. On A: star contact C. Only C shows the star, and starring D moves it.
2. Trigger SOS: every non-backup contact gets the SMS. C's SMS is sent first (check the SMS app timestamps).
