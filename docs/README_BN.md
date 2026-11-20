# Woman Guard (smart_safety) — সম্পূর্ণ Documentation (বাংলা)

University final defence-এর জন্য তৈরি। সব তথ্য বর্তমান workspace-এর code থেকে নেওয়া; প্রতিটি দাবির পাশে `[source: file, Class.method(), line ~X]`। line নম্বর আনুমানিক (`~`)।

চিহ্ন: ✅ সম্পূর্ণ কাজ করে (code trace করা) · ⚠️ আংশিক / gap / device-এ যাচাই দরকার · ❌ শুধু উল্লেখ বা dead code।

## ফাইলসমূহ

| # | ফাইল | বিষয় |
|---|---|---|
| ১–২ | [01_PROJECT_AND_TECH_STACK_BN.md](01_PROJECT_AND_TECH_STACK_BN.md) | প্রজেক্ট পরিচিতি, feature তালিকা (status সহ), Flutter/Dart version, Firebase services, Spark plan সিদ্ধান্ত, state management, architecture ও folder structure, MethodChannel তালিকা |
| ৩ | [02_PACKAGES_BN.md](02_PACKAGES_BN.md) | প্রতিটি package — lock version, constraint, কাজ, কোথায়, বিকল্প; unused package |
| ৪ | [03_FEATURES_BN.md](03_FEATURES_BN.md) | ২৪টি feature section — workflow, code flow, Firestore data, permission, edge case, limitation, status, Mermaid diagram (SOS end-to-end সহ) |
| ৫–৬ | [04_SECURITY_AND_DATABASE_BN.md](04_SECURITY_AND_DATABASE_BN.md) | Auth flow, guest mode, Firestore rules লাইন ধরে, দুর্বলতা; পূর্ণ Firestore schema, ER diagram, কোন screen কোন collection |
| ৭–৯ | [05_NAVIGATION_BACKGROUND_SETUP_BN.md](05_NAVIGATION_BACKGROUND_SETUP_BN.md) | Screen তালিকা ও flow diagram; background service, notification channel, FCM, SMS, sensor; Android বনাম iOS; build/setup, SDK version, key |
| ১০ | [06_ISSUES_AND_FUTURE_BN.md](06_ISSUES_AND_FUTURE_BN.md) | Bug, security risk, dead code, scalability, ভবিষ্যৎ উন্নয়ন |
| ১১ | [07_VIVA_QA_BN.md](07_VIVA_QA_BN.md) | **১০০টি viva প্রশ্ন ও উত্তর** (সাধারণ, Flutter, Firebase, code-specific, tricky, তুলনামূলক) |
| ১২–১৩ | [08_GLOSSARY_AND_VERIFICATION_BN.md](08_GLOSSARY_AND_VERIFICATION_BN.md) | শব্দকোষ; যাচাই রিপোর্ট — সংশোধনের তালিকা ও "নিশ্চিত করা যায়নি" তালিকা |

## এক নজরে ৫টি সবচেয়ে গুরুত্বপূর্ণ তথ্য
1. SOS = **একবার tap** → নিজের SIM থেকে SMS (Android native `SmsSender.kt`) + Firestore `sos_alerts` + live tracking + escalation। কেন্দ্র: `lib/services/emergency_service.dart → EmergencyService.triggerEmergency()`।
2. Guardian alert **FCM দিয়ে নয়** — Spark plan-এ server নেই, তাই guardian-এর ফোনে native foreground service (`GuardianAlertService.kt`) Firestore listener চালায়।
3. App কার্যত **Android-only** (iOS-এ SMS auto-send, background listener, exact alarm নেই; Info.plist-এ XML ত্রুটি)।
4. Security rules SOS অংশে কড়া (server timestamp, delete নিষিদ্ধ, field allow-list), কিন্তু `users` সবার জন্য readable ও `safety_reports` update খোলা।
5. `flutter analyze` → No issues found।

> পুরনো `qa-fix-audit.md` ও `qa-fix-report.md` এই documentation-এর অংশ নয় (আগে থেকেই ছিল)।
