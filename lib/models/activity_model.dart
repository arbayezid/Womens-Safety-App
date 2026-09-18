import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/app_colors.dart';

/// Categories of tracked safety and app activities.
enum ActivityType {
  sos,
  siren,
  contact,
  profile,
  location,
  fakeCall,
  audio,
}

/// Data model representing a logged user action or emergency safety event.
class ActivityItem {
  final String id;
  final ActivityType type;
  final String title;
  final String subtitle;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;

  const ActivityItem({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    this.metadata = const {},
  });

  /// Relative human-friendly timestamp (e.g. "Just now", "5m ago", "2h ago", "Yesterday").
  String get timeAgo {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inSeconds < 45) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      final mins = difference.inMinutes;
      return '${mins}m ago';
    } else if (difference.inHours < 24) {
      final hrs = difference.inHours;
      return '${hrs}h ago';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[timestamp.month - 1]} ${timestamp.day}';
    }
  }

  /// Primary icon corresponding to the activity type.
  IconData get icon {
    switch (type) {
      case ActivityType.sos:
        return Icons.notifications_active_rounded;
      case ActivityType.siren:
        return Icons.campaign_rounded;
      case ActivityType.contact:
        return Icons.group_rounded;
      case ActivityType.profile:
        return Icons.manage_accounts_rounded;
      case ActivityType.location:
        return Icons.location_on_rounded;
      case ActivityType.fakeCall:
        return Icons.phone_in_talk_rounded;
      case ActivityType.audio:
        return Icons.mic_rounded;
    }
  }

  /// Semantic foreground color.
  Color get iconColor {
    switch (type) {
      case ActivityType.sos:
        return AppColors.sosRed;
      case ActivityType.siren:
        return AppColors.actionOrange;
      case ActivityType.contact:
        return AppColors.actionBlue;
      case ActivityType.profile:
        return AppColors.actionPurple;
      case ActivityType.location:
        return AppColors.actionGreen;
      case ActivityType.fakeCall:
        return AppColors.actionPurple;
      case ActivityType.audio:
        return AppColors.actionOrange;
    }
  }

  /// Light tint background container color.
  Color get bgColor {
    switch (type) {
      case ActivityType.sos:
        return const Color(0xFFFFE5E5);
      case ActivityType.siren:
        return const Color(0xFFFEEDD8);
      case ActivityType.contact:
        return const Color(0xFFDDEEFD);
      case ActivityType.profile:
        return const Color(0xFFF0E6F9);
      case ActivityType.location:
        return const Color(0xFFDFF5E3);
      case ActivityType.fakeCall:
        return const Color(0xFFF0E6F9);
      case ActivityType.audio:
        return const Color(0xFFFEEDD8);
    }
  }

  /// Converts this [ActivityItem] to a key-value [Map].
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'type': type.name,
      'title': title,
      'subtitle': subtitle,
      'timestamp': timestamp.toIso8601String(),
      'metadata': metadata,
    };
  }

  /// Constructs an [ActivityItem] from a serialized [Map].
  factory ActivityItem.fromMap(Map<String, dynamic> map) {
    ActivityType type;
    try {
      type = ActivityType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => ActivityType.sos,
      );
    } catch (_) {
      type = ActivityType.sos;
    }

    DateTime timestamp;
    try {
      timestamp = DateTime.parse(map['timestamp']?.toString() ?? '');
    } catch (_) {
      timestamp = DateTime.now();
    }

    return ActivityItem(
      id: map['id']?.toString() ?? '',
      type: type,
      title: map['title']?.toString() ?? '',
      subtitle: map['subtitle']?.toString() ?? '',
      timestamp: timestamp,
      metadata: Map<String, dynamic>.from(map['metadata'] ?? {}),
    );
  }

  /// Serializes into JSON string.
  String toJson() => json.encode(toMap());

  /// Deserializes from JSON string.
  factory ActivityItem.fromJson(String source) =>
      ActivityItem.fromMap(json.decode(source) as Map<String, dynamic>);
}
