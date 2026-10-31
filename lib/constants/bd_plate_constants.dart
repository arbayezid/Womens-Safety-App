/// Constants for Bangladesh Vehicle Plate Structure, Ride Types, and Numerals
class BdPlateConstants {
  BdPlateConstants._();

  /// Bengali to English digits mapping table
  static const Map<String, String> bengaliToEnglishDigits = {
    '০': '0',
    '১': '1',
    '২': '2',
    '৩': '3',
    '৪': '4',
    '৫': '5',
    '৬': '6',
    '৭': '7',
    '৮': '8',
    '৯': '9',
  };

  /// Normalizes any Bengali digits in the given input string to English digits
  static String normalizeDigits(String input) {
    String result = input;
    bengaliToEnglishDigits.forEach((bn, en) {
      result = result.replaceAll(bn, en);
    });
    return result;
  }

  /// Popular City / Metro areas in Bangladesh for vehicle registrations
  static const List<String> metroCities = [
    'DHAKA METRO',
    'CHATTA METRO',
    'SYLHET METRO',
    'RAJSHAHI METRO',
    'KHULNA METRO',
    'BARISHAL METRO',
    'RANGPUR METRO',
    'MYMENSINGH METRO',
    'GAZIPUR',
    'NARAYANGANJ',
    'CUMILLA',
    'BOGURA',
    'BRAHMANBARIA',
    'FARIDPUR',
    'JESSORE',
    'KUSHTIA',
    'PABNA',
    'TANGHAIL',
    'DINAJPUR',
    'COXS BAZAR',
    'NOAKHALI',
    'FENI',
  ];

  /// Standard series representation with English label, Bengali character, and BRTA vehicle class note
  static const List<BdPlateSeries> seriesList = [
    BdPlateSeries(english: 'THA', bengali: 'থ', description: 'Auto Rickshaw / CNG'),
    BdPlateSeries(english: 'HA', bengali: 'হ', description: 'Motorcycle (>100cc)'),
    BdPlateSeries(english: 'LA', bengali: 'ল', description: 'Motorcycle (<=100cc)'),
    BdPlateSeries(english: 'GA', bengali: 'গ', description: 'Private Car (>1800cc)'),
    BdPlateSeries(english: 'KHA', bengali: 'খ', description: 'Private Car (1301-1800cc)'),
    BdPlateSeries(english: 'KA', bengali: 'ক', description: 'Private Car (<=1300cc)'),
    BdPlateSeries(english: 'GHA', bengali: 'ঘ', description: 'Jeep / SUV'),
    BdPlateSeries(english: 'CHA', bengali: 'চ', description: 'Microbus'),
    BdPlateSeries(english: 'CHHA', bengali: 'ছ', description: 'Human Hauler / Leguna'),
    BdPlateSeries(english: 'JA', bengali: 'জ', description: 'Minibus'),
    BdPlateSeries(english: 'JHA', bengali: 'ঝ', description: 'Large Bus'),
    BdPlateSeries(english: 'BA', bengali: 'ব', description: 'Inter-district Bus'),
    BdPlateSeries(english: 'TA', bengali: 'ট', description: 'Heavy Truck'),
    BdPlateSeries(english: 'DA', bengali: 'ড', description: 'Medium Truck'),
    BdPlateSeries(english: 'NA', bengali: 'ন', description: 'Pick-up Van'),
    BdPlateSeries(english: 'PA', bengali: 'প', description: 'Taxi Cab'),
    BdPlateSeries(english: 'MA', bengali: 'ম', description: 'Delivery Van'),
    BdPlateSeries(english: 'YA', bengali: 'য', description: 'Government / Police'),
    BdPlateSeries(english: 'RA', bengali: 'র', description: 'Ambulance'),
    BdPlateSeries(english: 'BHA', bengali: 'ভ', description: 'Special Purpose'),
  ];

  /// Ride type categories available in Ride Check-in
  static const List<String> rideTypes = [
    'CNG',
    'Bike (Ride-share)',
    'Car (Ride-share)',
    'Bus',
    'Rickshaw / Other',
  ];

  /// Supported ride apps or standalone options
  static const List<String> appOptions = [
    'Uber',
    'Pathao',
    'Obhai',
    'Other App',
    'No App',
  ];
}

/// Represents an individual plate series item
class BdPlateSeries {
  final String english;
  final String bengali;
  final String description;

  const BdPlateSeries({
    required this.english,
    required this.bengali,
    required this.description,
  });

  String get displayName => '$english ($bengali) - $description';
  String get shortName => '$english ($bengali)';
}
