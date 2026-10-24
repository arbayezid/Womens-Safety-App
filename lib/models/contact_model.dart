import 'dart:convert';

/// Data model representing an emergency contact.
///
/// Supports email-based mutual consent sync for high-priority cloud push alerts,
/// and an optional phone number for offline direct background SMS fallback.
class ContactModel {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String relationship;
  final bool isPrimary;
  final String? contactUid;
  final bool isSyncedAppUser;
  final String syncStatus; // 'synced' | 'pending' | 'offline_only'

  const ContactModel({
    required this.id,
    required this.name,
    this.email = '',
    this.phone = '',
    required this.relationship,
    this.isPrimary = false,
    this.contactUid,
    this.isSyncedAppUser = false,
    this.syncStatus = 'offline_only',
  });

  /// True if an optional mobile phone number is available for SMS fallback.
  bool get hasPhone => phone.trim().isNotEmpty;

  /// True if this contact is officially linked through in-app email consent.
  bool get isSynced => isSyncedAppUser && syncStatus == 'synced';

  /// True if waiting for the recipient to accept the connection request.
  bool get isPending => syncStatus == 'pending';

  /// Active emergency alert channels available for this contact:
  /// - 'SMS' if the contact has a valid phone number
  /// - 'App' if the contact is a synced app user
  /// - 'No alert channel' if the contact has no phone and is not a synced app user
  List<String> get alertChannels {
    final channels = <String>[];
    if (hasPhone) {
      channels.add('SMS');
    }
    if (isSynced) {
      channels.add('App');
    }
    if (channels.isEmpty) {
      channels.add('No alert channel');
    }
    return channels;
  }

  /// Converts this [ContactModel] to a key-value [Map] for local or remote storage.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'email': email.toLowerCase().trim(),
      'phone': phone.trim(),
      'relationship': relationship,
      'isPrimary': isPrimary,
      'contactUid': contactUid,
      'isSyncedAppUser': isSyncedAppUser,
      'syncStatus': syncStatus,
      // Firestore compatibility fields
      'contact_name': name,
      'contact_email': email.toLowerCase().trim(),
      'contact_optional_phone': phone.trim(),
      'contact_uid': contactUid,
      'is_synced_app_user': isSyncedAppUser,
      'sync_status': syncStatus,
    };
  }

  /// Creates a [ContactModel] from a key-value [Map].
  factory ContactModel.fromMap(Map<String, dynamic> map) {
    final String resolvedEmail =
        map['email']?.toString() ?? map['contact_email']?.toString() ?? '';
    final String resolvedPhone =
        map['phone']?.toString() ?? map['contact_optional_phone']?.toString() ?? '';
    final String? resolvedUid =
        map['contactUid']?.toString() ?? map['contact_uid']?.toString();
    final bool resolvedSynced =
        map['isSyncedAppUser'] == true || map['is_synced_app_user'] == true;
    final String resolvedStatus = map['syncStatus']?.toString() ??
        map['sync_status']?.toString() ??
        (resolvedSynced ? 'synced' : 'offline_only');

    return ContactModel(
      id: map['id']?.toString() ?? resolvedUid ?? '',
      name: map['name']?.toString() ?? map['contact_name']?.toString() ?? '',
      email: resolvedEmail,
      phone: resolvedPhone,
      relationship: map['relationship']?.toString() ?? 'Other',
      isPrimary: map['isPrimary'] == true,
      contactUid: resolvedUid,
      isSyncedAppUser: resolvedSynced,
      syncStatus: resolvedStatus,
    );
  }

  /// Serializes this [ContactModel] into a JSON String.
  String toJson() => json.encode(toMap());

  /// Deserializes a [ContactModel] from a JSON String.
  factory ContactModel.fromJson(String source) =>
      ContactModel.fromMap(json.decode(source) as Map<String, dynamic>);

  /// Creates a copy of this [ContactModel] with optionally updated fields.
  ContactModel copyWith({
    String? id,
    String? name,
    String? email,
    String? phone,
    String? relationship,
    bool? isPrimary,
    String? contactUid,
    bool? isSyncedAppUser,
    String? syncStatus,
  }) {
    return ContactModel(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      relationship: relationship ?? this.relationship,
      isPrimary: isPrimary ?? this.isPrimary,
      contactUid: contactUid ?? this.contactUid,
      isSyncedAppUser: isSyncedAppUser ?? this.isSyncedAppUser,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }

  /// Returns first letter of the name (uppercase) for avatar display.
  String get initial {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed[0].toUpperCase();
  }

  @override
  String toString() {
    return 'ContactModel(id: $id, name: $name, email: $email, phone: $phone, relationship: $relationship, isPrimary: $isPrimary, isSynced: $isSyncedAppUser, status: $syncStatus)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ContactModel &&
        other.id == id &&
        other.name == name &&
        other.email == email &&
        other.phone == phone &&
        other.relationship == relationship &&
        other.isPrimary == isPrimary &&
        other.contactUid == contactUid &&
        other.isSyncedAppUser == isSyncedAppUser &&
        other.syncStatus == syncStatus;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        name.hashCode ^
        email.hashCode ^
        phone.hashCode ^
        relationship.hashCode ^
        isPrimary.hashCode ^
        contactUid.hashCode ^
        isSyncedAppUser.hashCode ^
        syncStatus.hashCode;
  }
}

