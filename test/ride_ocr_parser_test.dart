import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/ride_ocr_service.dart';

void main() {
  group('RideOcrService Bangladesh Plate Parser Tests', () {
    test('1. Standard English BD plate with hyphen and spaces', () {
      const input = 'DHAKA METRO-GA 11-2233';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'DHAKA METRO');
      expect(result.series, 'GA');
      expect(result.classNumber, '11');
      expect(result.serialNumber, '2233');
      expect(result.formattedPlate, 'DHAKA METRO-GA 11-2233');
    });

    test('2. Plate with missing hyphens', () {
      const input = 'DHAKA METRO GA 112233';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'DHAKA METRO');
      expect(result.series, 'GA');
      expect(result.classNumber, '11');
      expect(result.serialNumber, '2233');
      expect(result.formattedPlate, 'DHAKA METRO-GA 11-2233');
    });

    test('3. Bengali numerals converted to English', () {
      const input = 'DHAKA METRO-THA ১১-২২৩৩';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'DHAKA METRO');
      expect(result.series, 'THA');
      expect(result.classNumber, '11');
      expect(result.serialNumber, '2233');
      expect(result.formattedPlate, 'DHAKA METRO-THA 11-2233');
    });

    test('4. Chattogram/Chatta Metro alias normalization', () {
      const input = 'CHATTA METRO-HA 12 3456';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'CHATTA METRO');
      expect(result.series, 'HA');
      expect(result.classNumber, '12');
      expect(result.serialNumber, '3456');
      expect(result.formattedPlate, 'CHATTA METRO-HA 12-3456');
    });

    test('5. Non-metro district plate (Gazipur)', () {
      const input = 'Vehicle: GAZIPUR-HA 15-7890 active';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'GAZIPUR');
      expect(result.series, 'HA');
      expect(result.classNumber, '15');
      expect(result.serialNumber, '7890');
      expect(result.formattedPlate, 'GAZIPUR-HA 15-7890');
    });

    test('6. Plate surrounded by extra whitespace and noise', () {
      const input = '  TRIP DETAILS \n DHAKA   METRO - LA   13 - 9988 \n THANKS  ';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'DHAKA METRO');
      expect(result.series, 'LA');
      expect(result.classNumber, '13');
      expect(result.serialNumber, '9988');
      expect(result.formattedPlate, 'DHAKA METRO-LA 13-9988');
    });

    test('7. Multiple candidates extracted with candidates list populated', () {
      const input = 'Car 1: DHAKA METRO-GA 11-2233 and Car 2: SYLHET METRO-KHA 22-4455';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.candidatePlates.length, 2);
      expect(result.candidatePlates[0], 'DHAKA METRO-GA 11-2233');
      expect(result.candidatePlates[1], 'SYLHET METRO-KHA 22-4455');
    });

    test('8. Driver name and phone extraction from screenshot text', () {
      const input = '''
        Uber Trip
        Captain Name: Mohammad Karim
        Phone: 01712345678
        Vehicle: DHAKA METRO-CHA 11-5566
      ''';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.formattedPlate, 'DHAKA METRO-CHA 11-5566');
      expect(result.driverName, 'Mohammad Karim');
      expect(result.driverPhone, '+8801712345678');
    });

    test('9. Random noise / garbage text produces no plate and confidence 0', () {
      const input = 'Hello World! Just testing some random text with 1234 numbers.';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isFalse);
      expect(result.formattedPlate, isNull);
      expect(result.isConfident, isFalse);
      expect(result.confidence, 0.0);
    });
  });

  group('RideOcrService Bangla plate parser (Tesseract output)', () {
    test('10. Two-line Bangla plate as printed on the vehicle', () {
      const input = 'ঢাকা মেট্রো-গ\n৩১-৯৯৫৭';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isTrue);
      expect(result.city, 'DHAKA METRO');
      expect(result.series, 'GA');
      expect(result.classNumber, '31');
      expect(result.serialNumber, '9957');
      expect(result.formattedPlate, 'DHAKA METRO-GA 31-9957');
    });

    test('11. CNG plate (থ series) with stray noise and spacing', () {
      const input = 'ব্রেক\n ঢাকা  মেট্রো - থ \n ১১ - ২২৩৩ \n';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.formattedPlate, 'DHAKA METRO-THA 11-2233');
    });

    test('12. Series letter glued to মেট্রো and missing number separator', () {
      const input = 'চট্ট মেট্রোহ ১২৩৪৫৬';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.formattedPlate, 'CHATTA METRO-HA 12-3456');
    });

    test('13. Misread vowel signs still resolve the city by consonant skeleton', () {
      // ঢাকা read as ঢকা, মেট্রো read as মেট্রা
      const input = 'ঢকা মেট্রা-ল ১৩-৯৯৮৮';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.formattedPlate, 'DHAKA METRO-LA 13-9988');
    });

    test('14. Non-metro district with decomposed nukta (য + ়)', () {
      const input = 'নারায়ণগঞ্জ-ক ১৫-৭৮৯০';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.formattedPlate, 'NARAYANGANJ-KA 15-7890');
    });

    test('15. Only the number line readable -> partial result pre-fills digits', () {
      const input = 'িি ৩১-৯৯৫৭';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isFalse);
      expect(result.hasNumber, isTrue);
      expect(result.classNumber, '31');
      expect(result.serialNumber, '9957');
    });

    test('16. Bare numbers in English text are not mistaken for a plate number', () {
      const input = 'Trip fare 12 3456 paid';
      final result = RideOcrService.parsePlateFromText(input);

      expect(result.hasPlate, isFalse);
      expect(result.hasNumber, isFalse);
    });
  });
}
