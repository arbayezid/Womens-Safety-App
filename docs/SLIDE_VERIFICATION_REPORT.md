# Woman Guard: Final Defence Slides Checked Against the Code

Checked on 21 Nov 2026 against the current working tree (`main` at `bc3851d`, plus the uncommitted "signal lost" changes).

How to read this file:
- **Part A** lists every wrong or out-of-date statement, slide by slide: the slide number, what the slide says, and the correct information.
- **Part B** answers every "Check in code / app" box.
- **Part C** lists the slides that are correct, or that cannot be checked from the code.

The biggest changes came from the last commit (`bc3851d`, "some feature simplify and issues solved"). It removed or changed several things the slides still describe:
1. SOS SMS now goes **only to contacts who accepted the guardian request in the app**. Before, any saved phone number got the SMS.
2. "I'm safe" **no longer sends an SMS**.
3. Escalation **Stage 2 (8 minutes) is removed**. Only the 3-minute stage is left.
4. The 90-second **"EMERGENCY UPDATE" follow-up SMS is removed**.
5. The Messages app **no longer opens by itself** when SMS cannot be sent.
6. The GPS wait is now **about 1.5 s (3 s at most)**, not 10 s.
7. A new **Settings > SMS alerts** switch can turn off every SMS.

---

## Part A: Errors and corrections

### Slide 3: Introduction and Motivation

**Issue 1: The SMS does not go to every saved number**
- **Slide says:** "SMS to Mother and Brother" (and "Her brother has the app", which suggests the mother does not).
- **Correct:** Since `bc3851d`, a contact gets the SOS SMS or the in-app alert only after accepting the guardian request in Woman Guard (`ContactModel.canReceiveAlerts => isSynced`, [contact_model.dart:58](../lib/models/contact_model.dart#L58); [emergency_service.dart:705](../lib/services/emergency_service.dart#L705)). A mother without the app, or one who never accepted, gets nothing. Both the mother and the brother must have accepted the request.
- **Suggested wording:** "SMS to her guardians (Mother and Brother, who accepted her request in the app)". You can also make the example honest by having both use the app: "Her brother's phone also plays a loud siren..."

**Issue 2 (small): The time in the SMS includes the date**
- **Slide says:** "Time: 10:02 PM"
- **Correct:** The real format is "Time: 10:02 PM, 21 Nov 2026" (`formatSmsTime`, [emergency_service.dart:1350](../lib/services/emergency_service.dart#L1350)). If the phone has no precise GPS fix, the text says "Approx. location (within N m): ..." instead of "Live location: ...".

---

### Slide 5: Related Work and Research Gap

**Issue: "This work" row overstates who gets the SMS**
- **Slide says:** "SMS from the phone's own SIM (works offline)"
- **Correct:** Still true for the sender: no internet is needed to send. But the SMS now goes only to guardians who accepted the request in the app, so "works on any phone" is no longer the full picture (see Slide 3). Keep "works offline". Do not claim that any phone number can be alerted.

---

### Slide 6: Objectives and Proposed Solution

**Issue: Fall detection and battery alert are hidden, not removed**
- **Slide says:** (Your check box: "Fall detection fully removed")
- **Correct:** Fall detection and the low-battery alert are **hidden**: they are commented out in Settings, the User Manual and the home-screen start-up. The code is still in the project: `lib/services/motion_detection_service.dart`, `lib/services/battery_alert_service.dart` and `test/fall_detection_test.dart`. The slide does not mention either feature, so the slide text itself is fine. If an examiner asks, say "Fall detection is built but turned off in this version."
- **Shake to SOS:** still present. Settings shows "Shake phone hard 3× to alert (5s to cancel)".

---

### Slide 7: System Architecture

**Issue 1: Number of services**
- **Slide says:** "41 services"
- **Correct:** **45** `.dart` files in `lib/services/`. Fall detection and battery alert were only hidden, so their files are still counted. If you want to count only the services in use, it is 43 (45 minus `motion_detection_service` and `battery_alert_service`).

**Issue 2: SMS does not go to "Any phone"**
- **Slide says:** "User's phone → SMS from own SIM: works without internet → **Any phone**: SMS + map link"
- **Correct:** "→ **Guardian's phone** (any phone, no internet needed): SMS + map link". Only guardians who accepted the request receive it (see Slide 3).

**Issue 3 (small): How often location is saved**
- **Slide says:** "Location saved every 30 s, 25 m or 2 min."
- **Correct:** The location is saved when **at least 30 s have passed AND she moved at least 25 m**, or **every 2 min** as a heartbeat ([live_tracking_service.dart:16-17](../lib/services/live_tracking_service.dart#L16-L17)). Suggested wording: "Location saved at most every 30 s (only after a 25 m move), plus a 2-minute heartbeat."

**Correct on this slide:** 21 screens, 9 data models, 6 MethodChannels. The channels are `sms`, `device`, `deadline`, `guardian`, `pendant` and `fake_call`. Silent Panic phone silencing reuses the `device` channel, so the count is still 6.

---

### Slide 8: Technology Stack

**Issue 1: Kotlin file count**
- **Slide says:** "Kotlin (20 files)"
- **Correct:** **21 files**. `PhoneSilencer.kt` (Silent Panic phone silencing) was added.

**Issue 2: Test file count**
- **Slide says:** "flutter test (42 test files)"
- **Correct:** **45** `*_test.dart` files in `test/`. This includes `fall_detection_test.dart` (still present) and the new `signal_lost_banner_test.dart` (not committed yet). There are also **2 Firestore rules test files** (`test/firestore_rules/*.test.mjs`).

**Issue 3: flutter analyze is not 0 issues**
- **Slide/notes say:** "flutter analyze shows no issues"
- **Correct:** `flutter analyze` currently reports **3 errors**, all in `test/sos_escalation_test.dart` (lines 51, 56, 58). The test still uses `stage2Seconds`, which was removed with escalation Stage 2. **Fix the test before the defence** so the claim "0 issues" is true again.

**Correct on this slide:** Flutter 3.41.9 and Dart 3.11.5 (matches "3.41" and "3.11"), the Firebase services, the maps stack, the OCR stack, the hardware and Poppins.

---

### Slide 10: How One-Tap SOS Works

**Issue 1: GPS wait time**
- **Slide says:** "Get location: GPS tries up to 10 s, then last known place." (Your check box: "high accuracy 5 s → medium 3 s → last known")
- **Correct:** The GPS is kept warm while the app is open (`SosLocationWarmer`), so a fix is usually ready at once. The order is:
  1. A warm GPS fix (≤ 30 m, < 60 s old)
  2. A fresh last-known fix (≤ 30 m, < 30 s old)
  3. Up to **1.5 s** of live GPS
  4. The last real GPS fix from the past 30 min, if it fits the rough fix
  5. The best rough fix, or the last known place

  The whole step is capped at **3 s**, plus a 1 s last-known fallback ([emergency_service.dart:798-830](../lib/services/emergency_service.dart#L798-L830), [1404-1480](../lib/services/emergency_service.dart#L1404-L1480)).
- **Suggested wording:** "Get location: Uses the GPS fix kept ready by the app; waits at most 3 s, then the last known place."

**Issue 2: "I'm safe" no longer sends an SMS**
- **Slide says:** "Hold the green button for 2 s. Everyone gets '… is safe now'."
- **Correct:** The 2-second hold is correct. **No SMS is sent any more.** `markSafe()` says: "No 'I'm safe' SMS: only the alert itself is texted" ([emergency_service.dart:405](../lib/services/emergency_service.dart#L405)). Guardians with the app see the alert change to "Marked safe" and their siren stops.
- **Suggested wording:** "Hold the green button for 2 s. Guardians' apps show 'Marked safe' and the siren stops."
- (Only **Followed Mode** still sends "… is safe now. Followed Mode has ended." by SMS when it ends.)

**Issue 3: No follow-up SMS when GPS comes back**
- **Slide says:** "GPS is off: … Update SMS if GPS comes back within 90 s."
- **Correct:** The "EMERGENCY UPDATE" follow-up SMS was **removed** in `bc3851d`. Now, if there is no fix, the SMS says "Location unavailable". If there is only a rough fix, it says "Approx. location (within N m)". Guardians with the app still get the live location through live tracking.
- **Suggested wording:** "GPS is off: Last known place, or 'Location unavailable'. Guardians still see her live location in the app once GPS returns."

**Issue 4: The Messages app does not open by itself**
- **Slide says:** "No SMS permission: The Messages app opens with the text ready. Just press Send."
- **Correct:** The automatic Messages-app fallback was **removed** in `bc3851d`. Now, if no SMS could be sent, the result bar shows an **"SMS App"** button. Tapping it opens the Messages app for the **first** contact only, pre-filled with the short text "SOS! I need help. My GPS: <link>" ([home_screen.dart:456-466](../lib/screens/home_screen.dart#L456-L466)). The in-app alert still goes to guardians.
- **Suggested wording:** "No SMS permission: The in-app alert still goes. An 'SMS App' button opens Messages with the text ready."

**Issue 5 (small): Contacts step**
- **Slide says:** "Pick contacts: Primary contact first. Backup waits."
- **Correct:** Add "only guardians who accepted". Contacts whose request is pending get nothing. If **no** contact has accepted, the SOS stops with "None of your contacts has accepted your request yet." The new **Settings > SMS alerts** switch (on by default) can also turn off all SMS, leaving only the in-app alert.

**Issue 6: The SMS box**
- **Slide says:** "The SMS (works on any phone)"
- **Correct:** The SMS text format is right. The SMS can be read on any phone without internet, but it is sent only to guardians who accepted the request.

**Correct on this slide:** no countdown on the SOS button, dual-SIM retry (`SmsSender.kt` retries failed numbers on the next SIM), and a second press re-rings guardians and re-sends the SMS without creating a new SOS. The "Re-send" option has a 30 s cooldown.

---

### Slide 11: Guardian Alert and Smart Escalation

**Issue 1: Stage 2 (8 minutes) no longer exists**
- **Slide says:** "8 min · Stage 2: 'URGENT UPDATE' SMS to everyone; reminder to call 999." Speaker notes: "At 8 minutes everyone gets an urgent SMS and she gets a reminder to call 999."
- **Correct:** Escalation now has **only Stage 1 at 3 minutes** ([sos_escalation_service.dart:15-38](../lib/services/sos_escalation_service.dart#L15-L38)). The 8-minute stage was removed in `bc3851d`.
- **What really happens at 3 min:** Backup contacts (who accepted) get "EMERGENCY ESCALATION: … You are alerted as backup. Location: …" by SMS and the in-app alert. The regular contacts get "UPDATE: No one has responded to <name>'s emergency SOS yet. Current location: …" by SMS.
- **Suggested timeline:**
  - 0 min · SOS sent: SMS + app alert to guardians.
  - 3 min · Stage 1: Backup contacts get SMS + app alert; other guardians get an "UPDATE" SMS.
  - Stops when a guardian taps "I'm Responding" or she taps "I'm safe". Runs even when the app is closed.
- 999: guardians can tap "Call 999" in the full-screen alert and in the Incident Room. There is no automatic 999 reminder.

**Issue 2 (small): The guardian must accept before receiving any SMS**
- **Slide says:** "Primary contact gets SMS first; backup is kept for later."
- **Correct:** Add that only accepted guardians get SMS or alerts (see Slide 3).

**Correct on this slide:** The background service listens to Firestore (no push server). The siren uses the ALARM stream (`USAGE_ALARM`), so it rings in silent mode. The full-screen alert has Call, View Map and I'm Responding. The watchdog runs every **10 min** (`INTERVAL_MS = 10 * 60 * 1000`). `GuardianBootReceiver` restarts the service after a reboot. Guardians are added by email, with the phone number optional.

---

### Slide 12: Journey and Ride Safety

**Issue (small): I'm Being Followed is not instant**
- **Slide says:** "One tap → SMS to all guardians + live sharing."
- **Correct:** One tap opens a **5-second countdown that can be cancelled**; then Followed Mode starts and SMS goes to guardians who accepted ([followed_start_dialog.dart](../lib/widgets/followed_start_dialog.dart), `seconds = 5`).

**Correct on this slide:** checks every 30 s; GPS lost 5 min; late at ETA + 5 min; off route 500 m (also "moving away from the destination 4 times in a row"); stopped means under 30 m of movement in 10 min; "Are you OK?" for 60 s; arrival within 100 m; Followed Mode check-in every 5 min with vibration only; ride overdue at ride time + 10 min with a 60 s check; OCR order ML Kit → Gemini (if a key is set) → Tesseract → voting.

---

### Slide 13: Hardware: ESP32 SOS Button

The slide matches the firmware that is on the device (`ESP32 Files/firmware/ESP32_SOS_BLE/ESP32_SOS_BLE.ino`): button GPIO 23, buzzer GPIO 4, battery GPIO 34, OLED SDA 21 / SCL 22, 2000 ms hold, name `ESP32_SOS`, sends "sos" on Nordic UART TX, 4.1 V = 100 % / 3.6 V = 0 %, battery sent every 60 s, 3 short beeps for sent, 1 long beep for failed. On the app side: the first 3 s after connecting are ignored, there is a 30 s cooldown, no siren on a pendant SOS, and the app reads Battery Service 0x180F.

**Warning (not a slide error):** The folder `esp32_firmware/esp32_woman_guard_pendant.ino` in the project root is the **old** firmware: button on GPIO 4, name "ESP32-Safety-Pendant", custom UUIDs. If an examiner opens that file, the pins will not match the slide. Show `ESP32 Files/firmware/ESP32_SOS_BLE/ESP32_SOS_BLE.ino` instead, or replace the old file.

---

### Slide 14: Database and Security

No wrong statements. Two notes:
- **Battery fields:** the `batteryLevel` field in `sos_alerts` is **not** from the removed low-battery alert. It is the sender's phone battery, shown to guardians in the SOS alert and the Incident Room (Slide 15). It should stay.
- **Possible addition to Limitations:** `safety_reports` can be **read by anyone, even without login**, and **any logged-in user can update** a report (`firestore.rules`, lines 369 and 376).
- Extra fact you can mention: every SOS alert now **expires on its own after 2 hours** (`sosAlertLifetime`, and rules allow at most 3 h).

---

### Slide 17: Result: Silent Help Tools

**Issue 1: It must be the Duress PIN**
- **Slide caption/notes say:** "Silent Panic: PIN → …" / "Silent Panic asks for a PIN. When she enters it…"
- **Correct:** She must enter the **Duress PIN**. Entering the real PIN on the Silent Panic screen **does nothing** (by design, so the screen is safe to show anyone).
- **Suggested caption:** "Silent Panic: Duress PIN → phone fully silent + calculator + silent SOS"

**Issue 2: Full silence needs one-time permission**
- **Slide/notes say:** "the phone goes fully silent … the phone makes no sound"
- **Correct:** Full silence needs **Do Not Disturb access**, given once in **Settings > Silence phone on Duress PIN**. With it, the phone uses "Total silence" (`INTERRUPTION_FILTER_NONE`): no sound **and no vibration** for calls, SMS, WhatsApp, Messenger, imo, alarms and every app. **Without that access, the phone only switches to vibrate**, so the attacker may still feel or hear the vibration. The user's own sound settings come back when she leaves the calculator with the real PIN + "=" ([PhoneSilencer.kt](../android/app/src/main/kotlin/com/smartsafety/smart_safety/PhoneSilencer.kt)).
- Suggested addition to the notes: "We give Do Not Disturb access once in Settings; without it the phone only vibrates."

**Issue 3: The Bangla fake-call voices are still placeholders**
- **Slide says:** "Fake Call: Ammu, Abbu, Bhaiya, Police or Office … using her own recorded voice"
- **Correct:** The caller names are right (there is also a "Custom" caller). The 5 built-in Bangla clips (`assets/fake_call/bn/*.mp3`) are still **placeholders** (half a second of silence, about 2 KB each). The app skips them and plays the **English** voice, unless the user records her own clip in Settings > Record my own caller voice. The notes are correct only if you record your own voices before the demo.

**Correct on this slide:** The silent SMS text is exactly "SILENT EMERGENCY: <name> may be under direct threat. Do NOT call her phone! Monitor her live GPS location discreetly." The silent SOS is still sent, with no siren. Camouflage exits with the real PIN + "=".

---

### Slide 18: Testing and Results

**Issue 1: Test file count**
- **Slide says:** "42: Dart test files"
- **Correct:** **45** Dart test files. If you do not want to count the fall-detection test (feature hidden) or the uncommitted signal-lost test, it is 43.

**Issue 2: flutter analyze**
- **Slide says:** "0: issues in flutter analyze"
- **Correct:** **3 errors** right now (`test/sos_escalation_test.dart` still uses the removed `stage2Seconds`). Fix the test, run `flutter analyze` again, then keep "0".

**Issue 3: flutter test**
- `flutter test` right now: **436 tests passed, 1 failed**. The failure is `test/sos_escalation_test.dart`, which does not compile (it uses the removed `stage2Seconds`). Fixing that one test file should make the whole suite pass.

**Issue 4: Feature count**
- **Slide says:** "22 / 29 features fully working (4 partly, 3 not active)". The partly list was escalation 999 tap, ride check-in, fake call and safety map.
- **Correct (recount from the current code):** Two items left the list: the follow-up GPS SMS was removed, and the escalation Stage 2 / 999 reminder was removed. Escalation (3-minute stage) is now fully working.
  - **28 features: 22 fully working, 3 partly, 3 not active**
  - Partly: ride check-in (depends on the Gemini key and Storage), fake call (Bangla clips are placeholders), safety map (shows sample data when Firestore is empty)
  - Not active: phone OTP, Cloud Functions push, and 2 settings switches. "Live location sharing" and "Push notifications" save a value that no service reads.
  - If you count Silent Panic phone silencing as its own feature: **29 features: 23 fully working, 3 partly, 3 not active**.

**Issue 5: "Shake and duress SOS" test row**
- Still correct. If you add a Silent Panic row, test it with **Do Not Disturb access given**. Otherwise the phone only vibrates.

---

### Slide 19: Limitations and Future Work

None of these are fixed. All rows are still true: any logged-in user can read user profiles; the 4-second polling is still in `contact_sync_service.dart:102` **and** `notification_service.dart:873`; the ESP32 cannot store an SOS; 999 is not called automatically; the interface is English only.

**Suggested additions (new limitations from the latest changes):**
- SMS goes only to guardians who accepted the request in the app. A family member with no smartphone cannot be alerted.
- Full silence in Silent Panic needs Do Not Disturb access. Without it the phone only vibrates.
- `safety_reports` are public to read, and any logged-in user can edit them.

---

### Slide 20: Expected Impact and Conclusion

**Issue: "Help reaches family … even without internet"**
- Still true for the sender (SIM SMS). But "family" must be guardians who accepted the request in the app. Suggested wording: "Help reaches her guardians in seconds, even without internet."

---

### Slide 22: Thank You (demo plan)

**Issue: Demo step 7 (Silent Panic)**
- **Notes say:** "Open Silent Panic and enter the PIN: the app turns into a calculator and the phone goes silent"
- **Correct:** Enter the **Duress PIN** (not the real PIN). **Before the defence**, give Do Not Disturb access in Settings > Silence phone on Duress PIN, or the phone will only vibrate during the call test. After the demo, type the **real PIN + "="** in the calculator to get the sound back.

**Other demo notes**
- Step 4: "Hold I'm safe; phone 2 shows Marked safe" is correct. Do **not** say that an "is safe now" SMS arrives, because it no longer does.
- Make sure the phone-2 guardian has **accepted** the request. Otherwise phone 1 shows "None of your contacts has accepted your request yet" and nothing is sent.
- Do not put phone 2 (the guardian) into Silent Panic during the demo. A phone in duress silence does **not** play the guardian siren (`AlertSirenPlayer.kt:54`).

---

## Part B: Answers to every "Check in code / app" box

| Slide | Check | Result |
|---|---|---|
| 1 | Names, IDs, supervisor | Not in the code. Please check yourself. |
| 3 | SMS text format | ✔ `EMERGENCY! <name> needs help. Live location: https://maps.google.com/?q=LAT,LNG  Time: 10:42 PM, 30 Oct 2026`. If there is no precise fix: "Approx. location (within N m)". If there is no fix: "Location unavailable". |
| 3 | Guardian siren when the app is closed | ✔ Native `GuardianAlertService` (foreground service) + `AlertSirenPlayer` on the ALARM stream |
| 3 | Backup alerted after 3 min | ✔ `stage1Seconds = 180`, with a native exact-alarm backstop so it runs even if the app is closed |
| 6 | Fall detection fully removed | ✖ **Hidden only.** Code and test still exist (see Slide 6) |
| 6 | Shake to SOS present | ✔ |
| 7 | 21 screens | ✔ 21 |
| 7 | 41 services | ✖ **45** (43 without the two hidden services) |
| 7 | 9 data models | ✔ 9 |
| 7 | 6 MethodChannels | ✔ 6 (silencing uses the existing `device` channel) |
| 7 | Spark plan | Not visible in the code. Your project memory says Spark, and `functions/` is not deployed. Confirm in the Firebase console. |
| 7 | Location write rule | ✔ 30 s **and** 25 m, or a 2-min heartbeat (see the wording fix) |
| 8 | Flutter / Dart version | ✔ Flutter 3.41.9, Dart 3.11.5 |
| 8 | Kotlin file count 20 | ✖ **21** (+ `PhoneSilencer.kt`) |
| 8 | Test files 42 | ✖ **45** (fall detection test still present) |
| 8 | flutter analyze 0 | ✖ **3 errors** in `test/sos_escalation_test.dart` |
| 8 | Firestore rules tests exist and pass | Exist: `test/firestore_rules/journeys_rules.test.mjs`, `sos_alerts_rules.test.mjs`. **Not run** (they need the Firebase emulator). |
| 9 | Team roles / who built the hardware | Not in the code. Every git commit is by `arbayezid`. Please confirm the hardware builder. |
| 10 | No countdown on SOS tap | ✔ |
| 10 | GPS 5 s → 3 s → last known (10 s) | ✖ Warm fix → fresh last-known → 1.5 s GPS → 3 s cap → last known |
| 10 | Dual-SIM retry | ✔ `SmsSender.kt` `candidateSubscriptions()` |
| 10 | Follow-up "EMERGENCY UPDATE" within 90 s | ✖ **Removed** in `bc3851d` |
| 10 | Messages-app fallback | ⚠ Only a manual "SMS App" button, for the first contact, with short text |
| 10 | "I'm safe" 2 s hold + "is safe now" SMS | ⚠ 2 s hold ✔; **no SMS** ✖ |
| 10 | Press again re-rings, no new SOS, 30 s gap | ✔ `SosGate` + `resendCooldown = 30 s` |
| 11 | Siren on ALARM stream, plays in silent mode | ✔ |
| 11 | Watchdog 10 min, boot restart | ✔ |
| 11 | Escalation 3 min and 8 min | ✖ **Only 3 min** now |
| 11 | Guardian siren when the guardian's own phone is in Silent Panic | ✖ **No siren.** `AlertSirenPlayer` skips the siren while `PhoneSilencer` is active, and DND "Total silence" also blocks the notification sound. |
| 12 | Journey 30 s / 5 min / ETA+5 / 500 m / 10 min / 100 m | ✔ |
| 12 | "Are you OK?" 60 s | ✔ |
| 12 | Followed Mode check-in every 5 min | ✔ (vibration only) |
| 12 | Ride overdue at +10 min | ✔ (+ 60 s check, then automatic SOS) |
| 12 | OCR order | ✔ ML Kit → Gemini (if key) → Tesseract → voting |
| 13 | Firmware pins and hold time | ✔ (in `ESP32 Files/firmware/ESP32_SOS_BLE/`; the old file in `esp32_firmware/` differs) |
| 13 | BLE name / "sos" / Nordic UART TX | ✔ |
| 13 | App: 3 s ignore, no duplicates, 30 s cooldown, no siren | ✔ `connectSettle = 3 s`, `hwCooldown = 30 s`, `playSiren` defaults to false |
| 13 | Battery 0x180F shown in Settings | ✔ "ESP32 Connected • N% Battery" |
| 14 | Collection names match `firestore.rules` | ✔ users, phone_numbers, connection_requests, sos_alerts, journeys, ride_checkins, safety_reports |
| 14 | Rules deployed | Not visible in the code. Check Firebase console → Firestore → Rules. |
| 14 | Battery fields removed | Not needed. `batteryLevel` is the sender's phone battery for guardians, not the removed alert. |
| 17 | Silent Panic still sends a silent SOS | ✔ `triggerDuressPipeline()` → `triggerEmergency(isDuress: true, playSiren: false)` |
| 17 | Silent SMS text | ✔ Exact match |
| 17 | Calls / WhatsApp / Messenger silent (and no vibration?) | ✔ With DND access: no sound **and** no vibration. ⚠ Without DND access: vibrate only. |
| 17 | How it silences and restores | Saves the ringer mode and DND filter, then sets `RINGER_MODE_SILENT` + `INTERRUPTION_FILTER_NONE`. Restored by real PIN + "=", and it survives an app restart (saved on disk). |
| 17 | Exit calculator: real PIN + "=" | ✔ |
| 17 | Bangla fake-call clips | ✖ Still **placeholders**. The English voice plays unless she records her own. |
| 18 | Test file count | **45** |
| 18 | `flutter test` passes | ✖ 436 passed, **1 failed** (`sos_escalation_test.dart` does not compile) |
| 18 | flutter analyze 0 | ✖ 3 errors |
| 18 | Feature count | **28: 22 ✔ / 3 ⚠ / 3 ✖** (see Slide 18) |
| 18 | ESP32 end-to-end on demo phones | Device test, not checkable from code |
| 19 | Any limitation already fixed? | **None fixed.** All still true. |

---

## Part C: Slides with no errors found

- **Slide 1, 2, 4, 9, 21:** Nothing in these can be checked against the code (names, IDs, outline, problem table, dates, team roles, references). Please check them yourself.
- **Slide 13:** Correct (see the firmware folder warning above).
- **Slide 14:** Correct.
- **Slide 15, 16:** The labels in the screenshots still exist in the app ("In-app alert sent", "Marked safe", "ESP32 Connected • N% Battery"). The numbers in the notes (53 seconds, 1.6 km / 22 min, the plate) come from your test run and cannot be checked from the code. "270 SOS alerts recorded" can only be checked in Firebase console → `sos_alerts`.

## Extra: a new feature not on any slide

There are uncommitted changes (`GuardianAlertService.kt`, `GuardianWatchdogReceiver.kt`, `signal_lost_banner.dart`) that add a **"signal lost" alert**. If an active SOS sender's phone sends no location update for **4 minutes**, guardians are told her phone has gone quiet and see a "Call 999" button. If you commit and test it before the defence, it is a good line to add to Slide 11.
