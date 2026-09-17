import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_safety/services/contact_service.dart';
import 'package:smart_safety/services/emergency_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EmergencyService Dynamic Contact Integration Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('EmergencyService retrieves numbers from ContactService when empty in memory', () async {
      final numbers = await ContactService.instance.getEmergencyPhoneNumbers();
      expect(numbers.length, greaterThanOrEqualTo(2));
      expect(numbers, contains('+8801711000001'));
      expect(numbers, contains('+8801933000003'));
    });

    test('Empty contacts list returns failure result with descriptive message', () async {
      // Clear contacts in storage
      await ContactService.instance.clearContacts();
      EmergencyService.instance.updateContacts([]);

      final result = await EmergencyService.instance.triggerEmergency(source: 'Test SOS');
      expect(result.isSuccess, isFalse);
      expect(
        result.message,
        'No emergency contacts configured. Please add emergency contacts first.',
      );
    });

    test('Generates valid Google Maps URL', () {
      final url = EmergencyService.instance.generateGoogleMapsUrl(23.8103, 90.4125);
      expect(url, 'https://www.google.com/maps/search/?api=1&query=23.8103,90.4125');
    });

    test('buildEmergencyMessage generates cost-effective single-segment SMS', () {
      final mapUrl = EmergencyService.instance.generateGoogleMapsUrl(23.7614038, 90.4453419);
      final message = EmergencyService.instance.buildEmergencyMessage(mapUrl);

      // Exact template requested to reduce carrier SMS billing
      expect(
        message,
        'SOS! I need help. My GPS: https://www.google.com/maps/search/?api=1&query=23.7614038,90.4453419',
      );

      // Standard GSM-7 single SMS limit is 160 chars
      expect(message.length, lessThanOrEqualTo(160));
      expect(message.length, equals(95));

      // No emojis or UCS-2 characters that trigger multi-part SMS billing
      expect(message.contains('🚨'), isFalse);
    });

    test('buildEmergencyMessage gracefully handles null or empty mapUrl', () {
      final messageNull = EmergencyService.instance.buildEmergencyMessage(null);
      expect(messageNull, 'SOS! I need help. GPS unavailable.');
      expect(messageNull.length, lessThanOrEqualTo(160));

      final messageEmpty = EmergencyService.instance.buildEmergencyMessage('');
      expect(messageEmpty, 'SOS! I need help. GPS unavailable.');
    });
  });
}
