# Fake Call: Bangla caller voices

When a fake call is answered, the app plays one of these clips. Each clip should be a **real person**
reading the script below. Do not use text-to-speech.

| Caller (in app)        | File          |
|------------------------|---------------|
| Ammu (Mom)             | `ammu.mp3`    |
| Abbu (Dad)             | `abbu.mp3`    |
| Bhaiya (Brother)       | `bhaiya.mp3`  |
| Police Station (Thana) | `police.mp3`  |
| Office                 | `office.mp3`  |

A **Custom** caller has no clip of its own. It uses `bhaiya.mp3` unless the user records a voice for it.

## Placeholders

The files in this folder now are **placeholders**: half a second of silence, about 2 KB each.
The app skips any clip of **16 KB or less** and plays the English voice instead, so a missing
recording never gives you a silent call. To add a real recording, replace the file and keep the
same name. Nothing in the code needs to change. Rebuild the app afterwards (`flutter run` or
`flutter build apk`).

Which voice plays when a call is answered:
1. The user's own recording for that caller (Settings › Fake Call › Record My Own Caller Voice)
2. The clip in this folder for that caller (only when Caller Voice Language is **Bangla**, the default)
3. The original English voice

## How to record

- Record in a quiet room, holding the phone the way you normally would on a call (about 15–20 cm
  from your mouth). Do not whisper. Talk normally, as if you were really on the phone.
- At each **"…"**, stay silent for **2–4 seconds**. This gives the user time to "reply".
- Leave about 1 second of silence at the start of the clip and 2 seconds at the end. The app
  repeats the clip after a 4-second pause, so the call never goes quiet.
- Aim for 15–40 seconds in total. Longer is fine.
- Export as **MP3, mono, 44.1 kHz, 48–64 kbps**. A 20-second clip is about 150 KB.
  A free tool such as Audacity (File › Export › MP3) or any phone voice recorder app will do.
- Use only your own voice, or the voice of someone who has agreed to it.

## Scripts

Each "…" marks a pause of 2–4 seconds.

### Ammu (`ammu.mp3`)
> হ্যালো, কোথায় তুমি? অনেকক্ষণ ধরে ফোন দিচ্ছি। … তাড়াতাড়ি বাসায় চলে আসো, আমি অপেক্ষা করছি। … আচ্ছা, লোকেশনটা পাঠাও তো।

### Abbu (`abbu.mp3`)
> হ্যালো মা, কোথায় আছিস? … আমি কাছেই আছি। … তুই ওখানেই দাঁড়া, আমি এখনই আসছি।

### Bhaiya (`bhaiya.mp3`)
> কিরে, কোথায় তুই? … আমি বাইক নিয়ে বের হয়েছি, পাঁচ মিনিটে পৌঁছাচ্ছি। … ফোন রাখিস না।

### Police Station (`police.mp3`)
> হ্যালো, থানা থেকে বলছি। … আপনার লোকেশন আমরা পেয়েছি, আমাদের টিম রওনা দিয়েছে। … দয়া করে লাইনে থাকুন।

### Office (`office.mp3`)
> হ্যালো, অফিস থেকে বলছি। … একটা জরুরি বিষয়, আপনাকে এখনই একটু কল ব্যাক করতে হবে। … আচ্ছা, আমি অপেক্ষা করছি।

## Checking a new clip

1. Settings › Fake Call › Caller Voice Language: **Bangla**.
2. Make sure there is no personal recording for that caller (Record My Own Caller Voice › Delete).
3. Home › Fake Call › choose the caller › **Now** › Accept. Your clip should play.
   In `adb logcat`, look for `WG/FakeCallAudio: Playing conversation clip assets/fake_call/bn/<name>.mp3`.
   If you see `[FakeCallVoice] ... still a placeholder`, the file is still 16 KB or smaller.
