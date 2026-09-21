import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/models/user_profile_model.dart';
import 'package:smart_safety/services/contact_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ContactSyncService Phone Normalization Tests', () {
    test('Normalizes local 017 format to +88017', () {
      final normalized = ContactSyncService.instance.normalizePhone('01712345678');
      expect(normalized, '+8801712345678');
    });

    test('Preserves existing +880 format', () {
      final normalized = ContactSyncService.instance.normalizePhone('+8801812345678');
      expect(normalized, '+8801812345678');
    });

    test('Strips dashes and whitespace', () {
      final normalized = ContactSyncService.instance.normalizePhone('019-12 34 56 78');
      expect(normalized, '+8801912345678');
    });

    test('Handles 00880 international prefix', () {
      final normalized = ContactSyncService.instance.normalizePhone('008801612345678');
      expect(normalized, '+8801612345678');
    });
  });

  group('UserProfile isPhoneVerified and fcmToken Tests', () {
    test('Serializes and deserializes phone verification status and fcmToken correctly', () {
      const profile = UserProfile(
        uid: 'user_123',
        name: 'Fatima Rahman',
        email: 'fatima@safety.org',
        phone: '+8801712345678',
        isPhoneVerified: true,
        fcmToken: 'mock_fcm_token_xyz',
      );

      final map = profile.toMap();
      expect(map['isPhoneVerified'], true);
      expect(map['fcmToken'], 'mock_fcm_token_xyz');
      expect(map['phone'], '+8801712345678');

      final fromMap = UserProfile.fromMap(map);
      expect(fromMap.isPhoneVerified, true);
      expect(fromMap.fcmToken, 'mock_fcm_token_xyz');
      expect(fromMap.phone, '+8801712345678');

      final jsonStr = profile.toJson();
      final fromJson = UserProfile.fromJson(jsonStr);
      expect(fromJson.isPhoneVerified, true);
      expect(fromJson.fcmToken, 'mock_fcm_token_xyz');
    });

    test('Defaults isPhoneVerified to false when not provided in map', () {
      final map = {
        'uid': 'user_abc',
        'name': 'Ayesha',
        'email': 'ayesha@example.com',
        'phone': '+8801800000000',
      };

      final profile = UserProfile.fromMap(map);
      expect(profile.isPhoneVerified, false);
      expect(profile.fcmToken, isNull);
    });

    test('copyWith updates isPhoneVerified and fcmToken', () {
      const profile = UserProfile(
        uid: 'u1',
        name: 'User One',
        isPhoneVerified: false,
      );

      final updated = profile.copyWith(
        isPhoneVerified: true,
        fcmToken: 'new_token_123',
        phone: '+8801700000001',
      );

      expect(updated.isPhoneVerified, true);
      expect(updated.fcmToken, 'new_token_123');
      expect(updated.phone, '+8801700000001');
    });
  });
}
