import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/utils/url_launcher_helper.dart';

void main() {
  group('UrlLauncherHelper - Phone Sanitization Tests', () {
    test('Sanitizes standard local phone number with dashes and spaces', () {
      expect(UrlLauncherHelper.sanitizePhoneNumber('01712-345 678'), '01712345678');
    });

    test('Preserves international leading plus sign while removing symbols', () {
      expect(
        UrlLauncherHelper.sanitizePhoneNumber('+880 (171) 234-5678'),
        '+8801712345678',
      );
    });

    test('Handles already clean phone numbers', () {
      expect(UrlLauncherHelper.sanitizePhoneNumber('01812345678'), '01812345678');
      expect(UrlLauncherHelper.sanitizePhoneNumber('+8801812345678'), '+8801812345678');
    });

    test('Returns empty string when input has no numeric characters', () {
      expect(UrlLauncherHelper.sanitizePhoneNumber(''), '');
      expect(UrlLauncherHelper.sanitizePhoneNumber('   '), '');
      expect(UrlLauncherHelper.sanitizePhoneNumber('---()'), '');
    });
  });

  group('UrlLauncherHelper - Map Navigation Tests', () {
    test('Constructs valid Google Maps navigation URL with driving mode', () {
      final url = UrlLauncherHelper.getMapNavigationUrl(23.7925, 90.4078);
      expect(
        url,
        'https://www.google.com/maps/dir/?api=1&destination=23.7925,90.4078&travelmode=driving',
      );
    });
  });
}
