import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';

/// Data model representing a user's safety profile and account details.
///
/// Contains personal information, contact numbers, blood group, emergency notes,
/// and profile photo metadata with serialization for permanent storage.
class UserProfile {
  final String uid;
  final String name;
  final String email;
  final String phone;
  final String city;
  final String dob;
  final String bloodGroup;
  final String emergencyNote;
  final String? photoUrl;

  const UserProfile({
    required this.uid,
    required this.name,
    this.email = '',
    this.phone = '',
    this.city = 'Dhaka, Bangladesh',
    this.dob = 'Jan 1, 1998',
    this.bloodGroup = 'B+',
    this.emergencyNote = '',
    this.photoUrl,
  });

  /// Factory constructor for default guest profile state.
  factory UserProfile.guest() {
    return const UserProfile(
      uid: 'guest',
      name: 'Guest',
      email: '',
      phone: '',
      city: 'Dhaka, Bangladesh',
      dob: 'Jan 1, 1998',
      bloodGroup: 'B+',
      emergencyNote: '',
      photoUrl: null,
    );
  }

  /// Creates a default [UserProfile] initialized from an authenticated [User].
  factory UserProfile.fromFirebaseUser(User user) {
    String name = user.displayName?.trim() ?? '';
    if (name.isEmpty && user.email != null && user.email!.contains('@')) {
      name = user.email!.split('@').first;
    }
    if (name.isEmpty) name = 'User';

    return UserProfile(
      uid: user.uid,
      name: name,
      email: user.email ?? '',
      phone: user.phoneNumber ?? '',
      city: 'Dhaka, Bangladesh',
      dob: 'Jan 1, 1998',
      bloodGroup: 'B+',
      emergencyNote: '',
      photoUrl: user.photoURL,
    );
  }

  /// Converts this [UserProfile] into a key-value [Map].
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'uid': uid,
      'name': name,
      'email': email,
      'phone': phone,
      'city': city,
      'dob': dob,
      'bloodGroup': bloodGroup,
      'emergencyNote': emergencyNote,
      'photoUrl': photoUrl,
    };
  }

  /// Creates a [UserProfile] from a key-value [Map].
  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      uid: map['uid']?.toString() ?? 'guest',
      name: map['name']?.toString() ?? 'Guest',
      email: map['email']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      city: map['city']?.toString() ?? 'Dhaka, Bangladesh',
      dob: map['dob']?.toString() ?? 'Jan 1, 1998',
      bloodGroup: map['bloodGroup']?.toString() ?? 'B+',
      emergencyNote: map['emergencyNote']?.toString() ?? '',
      photoUrl: map['photoUrl']?.toString(),
    );
  }

  /// Serializes this [UserProfile] into a JSON String.
  String toJson() => json.encode(toMap());

  /// Deserializes a [UserProfile] from a JSON String.
  factory UserProfile.fromJson(String source) =>
      UserProfile.fromMap(json.decode(source) as Map<String, dynamic>);

  /// Creates a copy of this [UserProfile] with optionally updated fields.
  UserProfile copyWith({
    String? uid,
    String? name,
    String? email,
    String? phone,
    String? city,
    String? dob,
    String? bloodGroup,
    String? emergencyNote,
    String? photoUrl,
    bool clearPhoto = false,
  }) {
    return UserProfile(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      city: city ?? this.city,
      dob: dob ?? this.dob,
      bloodGroup: bloodGroup ?? this.bloodGroup,
      emergencyNote: emergencyNote ?? this.emergencyNote,
      photoUrl: clearPhoto ? null : (photoUrl ?? this.photoUrl),
    );
  }

  /// Uppercase initial of the user's name for avatar fallback (e.g. 'R' or 'G').
  String get initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'G';
    return trimmed[0].toUpperCase();
  }

  /// First name / greeting name representation.
  String get greetingName {
    final full = name.trim();
    if (full.isEmpty || full == 'Guest' || full == 'User') return 'Guest';
    final parts = full.split(' ');
    return parts.isNotEmpty ? parts.first : full;
  }

  /// Whether this profile represents an unauthenticated guest.
  bool get isGuest => uid == 'guest';

  @override
  String toString() {
    return 'UserProfile(uid: $uid, name: $name, email: $email, phone: $phone, city: $city, bloodGroup: $bloodGroup)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserProfile &&
        other.uid == uid &&
        other.name == name &&
        other.email == email &&
        other.phone == phone &&
        other.city == city &&
        other.dob == dob &&
        other.bloodGroup == bloodGroup &&
        other.emergencyNote == emergencyNote &&
        other.photoUrl == photoUrl;
  }

  @override
  int get hashCode {
    return uid.hashCode ^
        name.hashCode ^
        email.hashCode ^
        phone.hashCode ^
        city.hashCode ^
        dob.hashCode ^
        bloodGroup.hashCode ^
        emergencyNote.hashCode ^
        photoUrl.hashCode;
  }
}
