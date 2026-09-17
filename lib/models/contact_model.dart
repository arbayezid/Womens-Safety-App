import 'dart:convert';

/// Data model representing an emergency contact.
///
/// Contains contact details, relationship tag, and emergency priority flag.
class ContactModel {
  final String id;
  final String name;
  final String phone;
  final String relationship;
  final bool isPrimary;

  const ContactModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.relationship,
    this.isPrimary = false,
  });

  /// Converts this [ContactModel] to a key-value [Map].
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'phone': phone,
      'relationship': relationship,
      'isPrimary': isPrimary,
    };
  }

  /// Creates a [ContactModel] from a key-value [Map].
  factory ContactModel.fromMap(Map<String, dynamic> map) {
    return ContactModel(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      relationship: map['relationship']?.toString() ?? 'Other',
      isPrimary: map['isPrimary'] == true,
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
    String? phone,
    String? relationship,
    bool? isPrimary,
  }) {
    return ContactModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      relationship: relationship ?? this.relationship,
      isPrimary: isPrimary ?? this.isPrimary,
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
    return 'ContactModel(id: $id, name: $name, phone: $phone, relationship: $relationship, isPrimary: $isPrimary)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ContactModel &&
        other.id == id &&
        other.name == name &&
        other.phone == phone &&
        other.relationship == relationship &&
        other.isPrimary == isPrimary;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        name.hashCode ^
        phone.hashCode ^
        relationship.hashCode ^
        isPrimary.hashCode;
  }
}
