import 'dart:math' as math;

import '../constants/bd_plate_constants.dart';

/// One reading of a plate (or part of it) produced by a single OCR pass.
///
/// [number] holds the 6 ASCII digits of the plate: 2-digit class followed by 4-digit serial.
class PlateReading {
  final String? city;
  final String? series;
  final String? number;
  final double weight;
  final String source;

  const PlateReading({
    this.city,
    this.series,
    this.number,
    this.weight = 1.0,
    this.source = '',
  });

  bool get isEmpty => city == null && series == null && number == null;

  @override
  String toString() => 'PlateReading($source w=$weight: $city / $series / $number)';
}

/// The agreed plate after voting over several [PlateReading]s, with a confidence per field.
class PlateConsensus {
  final String? city;
  final String? series;
  final String? classNumber;
  final String? serialNumber;
  final double cityConfidence;
  final double seriesConfidence;
  final double numberConfidence;

  /// Digit positions (0-5 over class + serial) the passes disagreed on
  final List<int> uncertainDigits;

  const PlateConsensus({
    this.city,
    this.series,
    this.classNumber,
    this.serialNumber,
    this.cityConfidence = 0,
    this.seriesConfidence = 0,
    this.numberConfidence = 0,
    this.uncertainDigits = const [],
  });

  bool get isComplete =>
      city != null && series != null && classNumber != null && serialNumber != null;

  /// Every field present and backed by agreeing readings
  bool get isConfident =>
      isComplete &&
      cityConfidence >= PlateVoting.confidentThreshold &&
      seriesConfidence >= PlateVoting.confidentThreshold &&
      numberConfidence >= PlateVoting.confidentThreshold;
}

/// Weighted majority voting over independent OCR readings.
///
/// A single reading can never be "confident" by itself (unless it carries a high weight, like a
/// high-confidence cloud read): confidence is the winning weight divided by at least
/// [minEvidence], so two agreeing device passes are needed to reach 1.0.
class PlateVoting {
  PlateVoting._();

  static const double confidentThreshold = 0.75;
  static const double minEvidence = 2.0;

  /// [PlateReading.source] of cloud-model readings
  static const String cloudSource = 'gemini';

  /// Series whose Bangla letters are easily confused with another series' letter:
  /// থ/খ, ব/র, ঘ/ম, চ/ছ, জ/ঝ
  static const Set<String> lookAlikeSeries = {
    'THA', 'KHA', 'BA', 'RA', 'GHA', 'MA', 'CHA', 'CHHA', 'JA', 'JHA',
  };

  static final Set<String> _knownSeries =
      BdPlateConstants.seriesList.map((s) => s.english).toSet();
  static final Set<String> _knownCities = BdPlateConstants.metroCities.toSet();

  /// BRTA class numbers are 11-99 and serials 0001-9999
  static bool isPlausibleNumber(String digits) {
    if (!RegExp(r'^\d{6}$').hasMatch(digits)) return false;
    if (digits[0] == '0') return false;
    if (digits.substring(2) == '0000') return false;
    return true;
  }

  static PlateConsensus decide(List<PlateReading> readings) {
    final city = _voteField(
      readings.where((r) => r.city != null && _knownCities.contains(r.city)),
      (r) => r.city!,
    );
    final series = _voteField(
      readings.where((r) => r.series != null && _knownSeries.contains(r.series)),
      (r) => r.series!,
    );
    final number = _voteNumber(
      readings.where((r) => r.number != null && isPlausibleNumber(r.number!)).toList(),
    );

    // A look-alike series letter read only by the cloud model is not trusted: in testing
    // Gemini read থ (THA) as খ (KHA) while reporting "high" confidence.
    var seriesConfidence = series?.confidence ?? 0;
    if (series != null &&
        lookAlikeSeries.contains(series.value) &&
        !readings.any((r) => r.series == series.value && r.source != cloudSource)) {
      seriesConfidence = math.min(seriesConfidence, 0.6);
    }

    return PlateConsensus(
      city: city?.value,
      series: series?.value,
      classNumber: number?.digits.substring(0, 2),
      serialNumber: number?.digits.substring(2),
      cityConfidence: city?.confidence ?? 0,
      seriesConfidence: seriesConfidence,
      numberConfidence: number?.confidence ?? 0,
      uncertainDigits: number?.uncertain ?? const [],
    );
  }

  static ({String value, double confidence})? _voteField(
    Iterable<PlateReading> readings,
    String Function(PlateReading) key,
  ) {
    final weights = <String, double>{};
    var total = 0.0;
    for (final r in readings) {
      weights.update(key(r), (w) => w + r.weight, ifAbsent: () => r.weight);
      total += r.weight;
    }
    if (weights.isEmpty) return null;

    final ranked = weights.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    return (value: best.key, confidence: best.value / math.max(total, minEvidence));
  }

  /// Votes each of the 6 digit positions separately, so passes that each misread a different
  /// digit still combine into the right number. Ties fall back to the most supported full number.
  static ({String digits, double confidence, List<int> uncertain})? _voteNumber(
    List<PlateReading> readings,
  ) {
    if (readings.isEmpty) return null;

    final wholeWeights = <String, double>{};
    for (final r in readings) {
      wholeWeights.update(r.number!, (w) => w + r.weight, ifAbsent: () => r.weight);
    }
    final bestWhole =
        (wholeWeights.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

    final buffer = StringBuffer();
    final uncertain = <int>[];
    var minConfidence = 1.0;
    for (var i = 0; i < 6; i++) {
      final weights = <String, double>{};
      var total = 0.0;
      for (final r in readings) {
        weights.update(r.number![i], (w) => w + r.weight, ifAbsent: () => r.weight);
        total += r.weight;
      }
      var bestDigit = bestWhole[i];
      for (final e in weights.entries) {
        if (e.value > weights[bestDigit]!) bestDigit = e.key;
      }
      final confidence = weights[bestDigit]! / math.max(total, minEvidence);
      if (confidence < confidentThreshold) uncertain.add(i);
      minConfidence = math.min(minConfidence, confidence);
      buffer.write(bestDigit);
    }

    final digits = buffer.toString();
    if (!isPlausibleNumber(digits)) {
      // The per-digit mix produced something impossible: trust the best full reading instead
      return (
        digits: bestWhole,
        confidence: wholeWeights[bestWhole]! /
            math.max(readings.fold<double>(0, (s, r) => s + r.weight), minEvidence),
        uncertain: const [0, 1, 2, 3, 4, 5],
      );
    }
    return (digits: digits, confidence: minConfidence, uncertain: uncertain);
  }

  /// Converts letters OCR commonly confuses with digits, for text known to be in a digit position
  /// (e.g. `DHAKA METRO-GA I1-22O3` -> class `11`, serial `2203`).
  static String latinToDigits(String text) {
    const map = {
      'O': '0', 'Q': '0', 'D': '0', 'U': '0',
      'I': '1', 'L': '1', '|': '1', '!': '1', 'J': '1',
      'Z': '2',
      'S': '5',
      'G': '6',
      'T': '7',
      'B': '8',
    };
    final out = StringBuffer();
    for (final ch in text.toUpperCase().split('')) {
      out.write(map[ch] ?? ch);
    }
    return out.toString();
  }

  /// Levenshtein edit distance, used for fuzzy city-name matching on OCR text
  static int editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = math.min(math.min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
  }
}
