# Picked up automatically by the Flutter Gradle plugin for release builds.

# google_mlkit_text_recognition references the optional Chinese / Devanagari / Japanese / Korean
# recognizers. Only the Latin model is bundled (Ride Safety Check-in plate OCR), so R8 must not
# fail on the absent classes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Tesseract4Android (Bangla plate OCR) is driven through JNI: the native library looks up these
# classes, fields and callbacks by name, so R8 must not rename or strip them.
-keep class com.googlecode.tesseract.android.** { *; }
-keep class com.googlecode.leptonica.android.** { *; }
