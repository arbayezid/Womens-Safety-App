import 'package:flutter/widgets.dart' show StringCharacters;

/// Who "calls" the user in a Fake Call. The user's own profile name is never a caller:
/// the caller always comes from one of these presets or from a custom name the user typed.
enum FakeCallerPreset { ammu, abbu, bhaiya, police, office, custom }

extension FakeCallerPresetInfo on FakeCallerPreset {
  /// Name shown on the incoming and in-call screens.
  String get displayName {
    switch (this) {
      case FakeCallerPreset.ammu:
        return 'Ammu';
      case FakeCallerPreset.abbu:
        return 'Abbu';
      case FakeCallerPreset.bhaiya:
        return 'Bhaiya';
      case FakeCallerPreset.police:
        return 'Police Station';
      case FakeCallerPreset.office:
        return 'Office';
      case FakeCallerPreset.custom:
        return 'Custom';
    }
  }

  /// Label in the caller picker and in Settings.
  String get pickerLabel {
    switch (this) {
      case FakeCallerPreset.ammu:
        return 'Ammu (Mom)';
      case FakeCallerPreset.abbu:
        return 'Abbu (Dad)';
      case FakeCallerPreset.bhaiya:
        return 'Bhaiya (Brother)';
      case FakeCallerPreset.police:
        return 'Police Station (Thana)';
      case FakeCallerPreset.office:
        return 'Office';
      case FakeCallerPreset.custom:
        return 'Custom name';
    }
  }

  /// Line under the caller name when no number is shown, like a saved contact on a real phone.
  String get numberLabel {
    switch (this) {
      case FakeCallerPreset.ammu:
      case FakeCallerPreset.abbu:
      case FakeCallerPreset.bhaiya:
        return 'Mobile';
      case FakeCallerPreset.police:
      case FakeCallerPreset.office:
      case FakeCallerPreset.custom:
        return 'Phone';
    }
  }

  /// File name (without extension) of the bundled Bangla clip under `assets/fake_call/bn/`.
  /// A custom caller has no clip of its own and uses the generic "Bhaiya" clip
  /// ("where are you, I'm coming"), unless the user records their own voice for it.
  String get bundledClipKey {
    switch (this) {
      case FakeCallerPreset.ammu:
        return 'ammu';
      case FakeCallerPreset.abbu:
        return 'abbu';
      case FakeCallerPreset.bhaiya:
      case FakeCallerPreset.custom:
        return 'bhaiya';
      case FakeCallerPreset.police:
        return 'police';
      case FakeCallerPreset.office:
        return 'office';
    }
  }

  /// The Bangla script the caller reads (shown on the recording screen). Null for custom.
  String? get banglaScript {
    switch (this) {
      case FakeCallerPreset.ammu:
        return 'হ্যালো, কোথায় তুমি? অনেকক্ষণ ধরে ফোন দিচ্ছি। … তাড়াতাড়ি বাসায় চলে আসো, '
            'আমি অপেক্ষা করছি। … আচ্ছা, লোকেশনটা পাঠাও তো।';
      case FakeCallerPreset.abbu:
        return 'হ্যালো মা, কোথায় আছিস? … আমি কাছেই আছি। … তুই ওখানেই দাঁড়া, আমি এখনই আসছি।';
      case FakeCallerPreset.bhaiya:
        return 'কিরে, কোথায় তুই? … আমি বাইক নিয়ে বের হয়েছি, পাঁচ মিনিটে পৌঁছাচ্ছি। … ফোন রাখিস না।';
      case FakeCallerPreset.police:
        return 'হ্যালো, থানা থেকে বলছি। … আপনার লোকেশন আমরা পেয়েছি, আমাদের টিম রওনা দিয়েছে। '
            '… দয়া করে লাইনে থাকুন।';
      case FakeCallerPreset.office:
        return 'হ্যালো, অফিস থেকে বলছি। … একটা জরুরি বিষয়, আপনাকে এখনই একটু কল ব্যাক করতে হবে। '
            '… আচ্ছা, আমি অপেক্ষা করছি।';
      case FakeCallerPreset.custom:
        return null;
    }
  }

  static FakeCallerPreset? fromId(String? id) {
    for (final p in FakeCallerPreset.values) {
      if (p.name == id) return p;
    }
    return null;
  }
}

/// Language of the bundled caller voice. A recording the user made always wins over both.
enum FakeCallVoiceLanguage { bangla, english }

extension FakeCallVoiceLanguageInfo on FakeCallVoiceLanguage {
  String get label => this == FakeCallVoiceLanguage.bangla ? 'Bangla' : 'English';

  static FakeCallVoiceLanguage fromId(String? id) =>
      id == FakeCallVoiceLanguage.english.name ? FakeCallVoiceLanguage.english : FakeCallVoiceLanguage.bangla;
}

class FakeCaller {
  final FakeCallerPreset preset;

  /// Only used when [preset] is [FakeCallerPreset.custom].
  final String customName;
  final String customPhone;

  const FakeCaller(this.preset, {this.customName = '', this.customPhone = ''});

  static const FakeCaller defaultCaller = FakeCaller(FakeCallerPreset.ammu);

  String get name => preset == FakeCallerPreset.custom ? customName.trim() : preset.displayName;

  /// Number shown under the name; empty when none was given.
  String get phone => preset == FakeCallerPreset.custom ? customPhone.trim() : '';

  /// Second line on the call screens: the number if one was given, otherwise "Mobile"/"Phone".
  String get subtitle => phone.isNotEmpty ? phone : preset.numberLabel;

  /// Letter avatar (first character, which may be a Bangla letter for a custom name).
  String get avatarLetter {
    final n = name;
    if (n.isEmpty) return '?';
    return n.characters.first.toUpperCase();
  }

  /// A custom caller needs a name; presets are always valid.
  bool get isValid => preset != FakeCallerPreset.custom || customName.trim().isNotEmpty;

  /// True if this caller would show [ownName] (the signed-in user's own profile name).
  bool usesOwnName(String? ownName) {
    final own = (ownName ?? '').trim().toLowerCase();
    if (own.isEmpty || own == 'guest' || own == 'user') return false;
    return name.toLowerCase() == own;
  }

  @override
  bool operator ==(Object other) =>
      other is FakeCaller &&
      other.preset == preset &&
      other.customName == customName &&
      other.customPhone == customPhone;

  @override
  int get hashCode => Object.hash(preset, customName, customPhone);

  @override
  String toString() => 'FakeCaller(${preset.name}, $name, $phone)';
}
