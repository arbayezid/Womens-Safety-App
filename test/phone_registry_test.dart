import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/phone_registry_service.dart';

void main() {
  group('PhoneRegistryService.normalize (one number = one account key)', () {
    test('all spellings of the same Bangladesh number map to one key', () {
      const key = '+8801711000001';
      expect(PhoneRegistryService.normalize('01711000001'), key);
      expect(PhoneRegistryService.normalize('8801711000001'), key);
      expect(PhoneRegistryService.normalize('+8801711000001'), key);
      expect(PhoneRegistryService.normalize('+880 1711-000001'), key);
      expect(PhoneRegistryService.normalize('008801711000001'), key);
      expect(PhoneRegistryService.normalize('1711000001'), key);
      expect(PhoneRegistryService.normalize(' (017) 1100-0001 '), key);
    });

    test('international numbers with a country code are kept', () {
      expect(PhoneRegistryService.normalize('+44 7700 900123'), '+447700900123');
      expect(PhoneRegistryService.normalize('0044 7700 900123'), '+447700900123');
    });

    test('rejects input that cannot identify a single number', () {
      expect(PhoneRegistryService.normalize(''), isNull);
      expect(PhoneRegistryService.normalize('abc'), isNull);
      expect(PhoneRegistryService.normalize('12345'), isNull);
      expect(PhoneRegistryService.normalize('7700900123'), isNull); // no country code, not BD
      expect(PhoneRegistryService.normalize('+0123456789'), isNull);
      expect(PhoneRegistryService.normalize('+1234567890123456'), isNull); // > 15 digits
    });
  });

  test('claim result messages explain the rule', () {
    expect(
      const PhoneClaimResult(PhoneClaimStatus.takenByAnotherAccount).message,
      contains('already registered to another account'),
    );
    expect(const PhoneClaimResult(PhoneClaimStatus.claimed, '+8801711000001').isClaimed, isTrue);
  });
}
