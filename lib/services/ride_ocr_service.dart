import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../constants/bd_plate_constants.dart';
import 'gemini_plate_reader.dart';
import 'plate_consensus.dart';
import 'plate_image_processor.dart';

/// Result envelope of the OCR extraction process
class RideOcrResult {
  final String? rawText;
  final String? formattedPlate;
  final String? city;
  final String? series;
  final String? classNumber;
  final String? serialNumber;
  final String? driverName;
  final String? driverPhone;
  final double confidence; // 0.0 to 1.0
  final bool isConfident;
  final List<String> candidatePlates;

  /// Per-field agreement between OCR passes (0-1); below 0.75 the UI asks the user to check
  final double cityConfidence;
  final double seriesConfidence;
  final double numberConfidence;

  /// Digit positions (0-5 across class + serial) the OCR passes disagreed on
  final List<int> uncertainDigits;

  /// 'cloud' when the Gemini reader contributed, 'device' for on-device OCR only
  final String source;

  const RideOcrResult({
    this.rawText,
    this.formattedPlate,
    this.city,
    this.series,
    this.classNumber,
    this.serialNumber,
    this.driverName,
    this.driverPhone,
    this.confidence = 0.0,
    this.isConfident = false,
    this.candidatePlates = const [],
    this.cityConfidence = 0.0,
    this.seriesConfidence = 0.0,
    this.numberConfidence = 0.0,
    this.uncertainDigits = const [],
    this.source = 'device',
  });

  bool get hasPlate => formattedPlate != null && formattedPlate!.isNotEmpty;

  /// True when at least the class + serial digits were read, even if city/series were not
  bool get hasNumber => classNumber != null && serialNumber != null;

  /// Fills any field this result is missing from [other]; a full plate always wins.
  RideOcrResult mergeWith(RideOcrResult other) {
    if (hasPlate) return this;
    if (other.hasPlate) {
      return RideOcrResult(
        rawText: other.rawText,
        formattedPlate: other.formattedPlate,
        city: other.city,
        series: other.series,
        classNumber: other.classNumber,
        serialNumber: other.serialNumber,
        driverName: other.driverName ?? driverName,
        driverPhone: other.driverPhone ?? driverPhone,
        confidence: other.confidence,
        isConfident: other.isConfident,
        candidatePlates: other.candidatePlates,
      );
    }
    final useOtherNumber = !hasNumber && other.hasNumber;
    return RideOcrResult(
      rawText: [rawText, other.rawText].whereType<String>().where((t) => t.isNotEmpty).join('\n'),
      city: city ?? other.city,
      series: series ?? other.series,
      classNumber: useOtherNumber ? other.classNumber : classNumber,
      serialNumber: useOtherNumber ? other.serialNumber : serialNumber,
      driverName: driverName ?? other.driverName,
      driverPhone: driverPhone ?? other.driverPhone,
      candidatePlates: [...candidatePlates, ...other.candidatePlates],
    );
  }
}

/// Service managing image OCR and tolerant Bangladesh vehicle plate recognition
class RideOcrService {
  RideOcrService._internal();
  static final RideOcrService instance = RideOcrService._internal();

  /// Known city variations mapped to standardized dropdown values
  static const Map<String, String> cityAliases = {
    'DHAKA METRO': 'DHAKA METRO',
    'DHAKA': 'DHAKA METRO',
    'CHATTA METRO': 'CHATTA METRO',
    'CHATTOGRAM METRO': 'CHATTA METRO',
    'CHITTAGONG METRO': 'CHATTA METRO',
    'CHATTA': 'CHATTA METRO',
    'CHATTOGRAM': 'CHATTA METRO',
    'CHITTAGONG': 'CHATTA METRO',
    'SYLHET METRO': 'SYLHET METRO',
    'SYLHET': 'SYLHET METRO',
    'RAJSHAHI METRO': 'RAJSHAHI METRO',
    'RAJSHAHI': 'RAJSHAHI METRO',
    'KHULNA METRO': 'KHULNA METRO',
    'KHULNA': 'KHULNA METRO',
    'BARISHAL METRO': 'BARISHAL METRO',
    'BARISHAL': 'BARISHAL METRO',
    'BARISAL': 'BARISHAL METRO',
    'RANGPUR METRO': 'RANGPUR METRO',
    'RANGPUR': 'RANGPUR METRO',
    'MYMENSINGH METRO': 'MYMENSINGH METRO',
    'MYMENSINGH': 'MYMENSINGH METRO',
    'GAZIPUR': 'GAZIPUR',
    'NARAYANGANJ': 'NARAYANGANJ',
    'CUMILLA': 'CUMILLA',
    'COMILLA': 'CUMILLA',
    'BOGURA': 'BOGURA',
    'BOGRA': 'BOGURA',
    'BRAHMANBARIA': 'BRAHMANBARIA',
    'FARIDPUR': 'FARIDPUR',
    'JESSORE': 'JESSORE',
    'KUSHTIA': 'KUSHTIA',
    'PABNA': 'PABNA',
    'TANGHAIL': 'TANGHAIL',
    'DINAJPUR': 'DINAJPUR',
    'COXS BAZAR': 'COXS BAZAR',
    'NOAKHALI': 'NOAKHALI',
    'FENI': 'FENI',
  };

  /// Bangla city names as printed on BRTA plates, mapped to the standardized dropdown values
  static const Map<String, String> banglaCityAliases = {
    'ঢাকা': 'DHAKA METRO',
    'চট্টগ্রাম': 'CHATTA METRO',
    'চট্ট': 'CHATTA METRO',
    'সিলেট': 'SYLHET METRO',
    'রাজশাহী': 'RAJSHAHI METRO',
    'খুলনা': 'KHULNA METRO',
    'বরিশাল': 'BARISHAL METRO',
    'রংপুর': 'RANGPUR METRO',
    'ময়মনসিংহ': 'MYMENSINGH METRO',
    'গাজীপুর': 'GAZIPUR',
    'নারায়ণগঞ্জ': 'NARAYANGANJ',
    'কুমিল্লা': 'CUMILLA',
    'বগুড়া': 'BOGURA',
    'ব্রাহ্মণবাড়িয়া': 'BRAHMANBARIA',
    'ফরিদপুর': 'FARIDPUR',
    'যশোর': 'JESSORE',
    'কুষ্টিয়া': 'KUSHTIA',
    'পাবনা': 'PABNA',
    'টাঙ্গাইল': 'TANGHAIL',
    'দিনাজপুর': 'DINAJPUR',
    'কক্সবাজার': 'COXS BAZAR',
    'নোয়াখালী': 'NOAKHALI',
    'ফেনী': 'FENI',
  };

  static final RegExp _banglaScript = RegExp('[ঀ-৿]');

  /// Vowel signs, hasanta, nukta, chandrabindu/anusvara/visarga and the au length mark: the parts
  /// of a Bangla word OCR most often gets wrong. Dropping them leaves the consonant "skeleton".
  static final RegExp _banglaMarks = RegExp('[ঁ-ঃ়া-্ৗ]');

  /// Canonicalizes Bangla OCR output: composes nukta letters, drops zero-width joiners,
  /// converts Bangla digits and unifies dashes.
  static String normalizeBanglaText(String text) {
    var t = BdPlateConstants.normalizeDigits(text)
        .replaceAll('য়', 'য়') // য + ় -> য়
        .replaceAll('ড়', 'ড়') // ড + ় -> ড়
        .replaceAll('ঢ়', 'ঢ়') // ঢ + ় -> ঢ়
        .replaceAll(RegExp('[​-‍﻿]'), '')
        .replaceAll(RegExp(r'[—–―_~]'), '-')
        .toUpperCase();
    t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
    return t.trim();
  }

  static String banglaSkeleton(String text) => text.replaceAll(_banglaMarks, '');

  /// Parses a plate printed in Bangla, e.g. `ঢাকা মেট্রো-গ ৩১-৯৯৫৭`.
  /// Returns a full plate when city, series and number are all read, otherwise whatever was found
  /// (typically the class + serial digits) so the form can be pre-filled.
  static RideOcrResult parseBanglaPlate(String rawInput) {
    final text = normalizeBanglaText(rawInput);
    if (text.isEmpty || (!_banglaScript.hasMatch(text) && !RegExp(r'\d').hasMatch(text))) {
      return const RideOcrResult();
    }

    // Class (2 digits) + serial (4 digits); the separator is often lost or misread by OCR
    final numberMatch =
        RegExp(r'(?<!\d)(\d{2})\s*[-.:=,]?\s*(\d{4})(?!\d)').firstMatch(text);
    final beforeNumber = numberMatch != null ? text.substring(0, numberMatch.start) : text;

    final cityHit = _findBanglaCity(beforeNumber);
    final series = _findBanglaSeries(
      cityHit != null ? beforeNumber.substring(cityHit.end) : beforeNumber,
    );

    final city = cityHit?.city;
    final classNumber = numberMatch?.group(1);
    final serialNumber = numberMatch?.group(2);

    // A bare 2+4 digit run is only trusted as a plate number when the text is actually Bangla
    // (or a city/series was found), so random numbers in English screenshots are ignored.
    final trustNumber = numberMatch != null &&
        (_banglaScript.hasMatch(text) || city != null || series != null);

    if (city != null && series != null && trustNumber) {
      final formatted = '$city-$series $classNumber-$serialNumber';
      return RideOcrResult(
        rawText: rawInput,
        formattedPlate: formatted,
        city: city,
        series: series,
        classNumber: classNumber,
        serialNumber: serialNumber,
        confidence: 0.8,
        isConfident: true,
        candidatePlates: [formatted],
      );
    }

    return RideOcrResult(
      rawText: rawInput,
      city: city,
      series: series,
      classNumber: trustNumber ? classNumber : null,
      serialNumber: trustNumber ? serialNumber : null,
    );
  }

  /// Finds the last city name in [text], first by exact spelling, then by consonant skeleton
  /// (tolerates misread vowel signs such as ঢাকা read as ঢকা).
  static ({String city, int end})? _findBanglaCity(String text) {
    // Normalize the names the same way as the OCR text (e.g. য + ় vs precomposed য়)
    final aliases = {
      for (final e in banglaCityAliases.entries) normalizeBanglaText(e.key): e.value,
    };
    final names = aliases.keys.toList()..sort((a, b) => b.length.compareTo(a.length));

    ({String city, int end})? best;
    for (final name in names) {
      final idx = text.lastIndexOf(name);
      if (idx >= 0 && (best == null || idx + name.length > best.end)) {
        best = (city: aliases[name]!, end: idx + name.length);
      }
    }
    if (best != null) return best;

    // Skeleton match, mapping skeleton positions back to positions in the original text
    final skeleton = StringBuffer();
    final endInOriginal = <int>[];
    for (var i = 0; i < text.length; i++) {
      if (_banglaMarks.hasMatch(text[i])) continue;
      skeleton.write(text[i]);
      endInOriginal.add(i + 1);
    }
    final skel = skeleton.toString();

    for (final name in names) {
      final nameSkel = banglaSkeleton(name);
      if (nameSkel.length < 2) continue;
      final idx = skel.lastIndexOf(nameSkel);
      if (idx < 0) continue;
      var end = endInOriginal[idx + nameSkel.length - 1];
      // Swallow trailing vowel signs of the matched word
      while (end < text.length && _banglaMarks.hasMatch(text[end])) {
        end++;
      }
      if (best == null || end > best.end) {
        best = (city: aliases[name]!, end: end);
      }
    }
    if (best != null) return best;

    // Fuzzy: one wrong/missing consonant in a longer name (e.g. চট্টগ্রাম read as চট্টগাম).
    // Short names are excluded: one edit would turn them into other words too easily.
    for (final token in RegExp('[ঀ-৿]+').allMatches(text)) {
      final tokenSkel = banglaSkeleton(token.group(0)!);
      if (tokenSkel.length < 3) continue;
      for (final name in names) {
        final nameSkel = banglaSkeleton(name);
        if (nameSkel.length < 4) continue;
        if (PlateVoting.editDistance(tokenSkel, nameSkel) <= 1 &&
            (best == null || token.end > best.end)) {
          best = (city: aliases[name]!, end: token.end);
        }
      }
    }
    return best;
  }

  /// Finds the series letter (e.g. গ -> GA): the single-consonant word closest to the number,
  /// skipping the "মেট্রো" word. Also handles OCR gluing it on, as in "মেট্রোগ".
  static String? _findBanglaSeries(String text) {
    final banglaToSeries = {
      for (final s in BdPlateConstants.seriesList) s.bengali: s.english,
    };

    final tokens = text
        .split(RegExp('[^ঀ-৿]+'))
        .where((t) => t.isNotEmpty)
        .toList()
        .reversed;

    for (final token in tokens) {
      var skel = banglaSkeleton(token);
      if (skel.startsWith('মট')) {
        // "মেট্রো" itself, possibly with the series letter glued on
        skel = skel.startsWith('মটর') ? skel.substring(3) : skel.substring(2);
        if (skel.isEmpty) continue;
      }
      if (skel.length == 1 && banglaToSeries.containsKey(skel)) {
        return banglaToSeries[skel];
      }
    }
    return null;
  }

  /// Normalizes and cleans raw OCR text
  static String normalizeOcrText(String text) {
    if (text.isEmpty) return '';
    String normalized = BdPlateConstants.normalizeDigits(text);
    normalized = normalized.toUpperCase();
    // Replace unusual hyphens/dashes with standard hyphen
    normalized = normalized.replaceAll(RegExp(r'[—–―_]'), '-');
    // Collapse multiple whitespaces
    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized;
  }

  /// Replaces OCR-garbled English city names with the closest known name, e.g. `DHAKA MFTRO`
  /// or `DHAKA METR0` -> `DHAKA METRO`. Only windows with the same word count are compared,
  /// and only small edit distances are accepted.
  static String fixLatinCityNames(String text) {
    final words = text.split(' ');
    if (words.isEmpty) return text;
    final names = cityAliases.keys.toList()..sort((a, b) => b.length.compareTo(a.length));

    final out = <String>[];
    var i = 0;
    outer:
    while (i < words.length) {
      for (final name in names) {
        final nameWords = name.split(' ');
        if (i + nameWords.length > words.length) continue;
        // Compare letters only, so a glued-on "-GA" suffix doesn't count against the match
        final window = words.sublist(i, i + nameWords.length);
        final lastWord = window.last;
        final lastLetters = RegExp(r'^[A-Z0-9|]+').stringMatch(lastWord) ?? '';
        if (lastLetters.isEmpty) continue;
        final candidate = [...window.sublist(0, window.length - 1), lastLetters]
            .join(' ')
            .replaceAll('0', 'O')
            .replaceAll('1', 'I')
            .replaceAll('|', 'I');
        final exact = candidate == name;
        if (!exact) {
          if (name.length < 5) continue;
          final maxDistance = name.length >= 10 ? 2 : 1;
          if (PlateVoting.editDistance(candidate, name) > maxDistance) continue;
        }
        out.add(name + lastWord.substring(lastLetters.length));
        i += nameWords.length;
        continue outer;
      }
      out.add(words[i]);
      i++;
    }
    return out.join(' ');
  }

  /// Parses a plate from text using a tolerant regex for Bangladesh plates.
  /// Handles formats like:
  /// - `DHAKA METRO-GA 11-2233`
  /// - `DHAKA METRO GA 112233`
  /// - `CHATTA METRO-HA 12 3456`
  /// - `DHAKA-THA 11-2233`
  /// - `GAZIPUR-HA 11-2233`
  /// - OCR confusions in the digits: `DHAKA METRO-GA I1-22O3` -> `11-2203`
  static RideOcrResult parsePlateFromText(String rawInput) {
    final clean = fixLatinCityNames(normalizeOcrText(rawInput));
    if (clean.isEmpty) {
      return const RideOcrResult();
    }

    // Build city pattern from known city keys
    final sortedCities = cityAliases.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final cityPattern = sortedCities.map(RegExp.escape).join('|');

    // Digit positions also accept letters OCR mistakes for digits (O->0, I->1, S->5, B->8 ...);
    // they are converted after matching. Anchored on a known city, so words aren't mistaken.
    const d = r'[0-9OQDUIL|!JZSGTB]';
    // Group 1: City, 2: Series (1 to 4 letters, e.g. CHHA), 3: Class (2), 4: Serial (4)
    final plateRegex = RegExp(
      '\\b($cityPattern)\\s*[-]?\\s*([A-Z]{1,4})\\s*[-.]?\\s*($d{2})\\s*[-.]?\\s*($d{4})(?![0-9A-Z])',
      caseSensitive: false,
    );

    final candidates = <String>[];
    String? bestFormatted;
    String? bestCity;
    String? bestSeries;
    String? bestClass;
    String? bestSerial;
    String? partialCity;
    String? partialClass;
    String? partialSerial;

    for (final match in plateRegex.allMatches(clean)) {
      final matchedCityRaw = match.group(1)?.trim().toUpperCase() ?? '';
      final matchedSeries = match.group(2)?.trim().toUpperCase() ?? '';
      final matchedClass = PlateVoting.latinToDigits(match.group(3)?.trim() ?? '');
      final matchedSerial = PlateVoting.latinToDigits(match.group(4)?.trim() ?? '');
      if (!RegExp(r'^\d{2}$').hasMatch(matchedClass) || !RegExp(r'^\d{4}$').hasMatch(matchedSerial)) {
        continue;
      }

      final stdCity = cityAliases[matchedCityRaw] ?? matchedCityRaw;
      if (!_isKnownSeries(matchedSeries)) {
        // City and number are still useful; the series is left for the user to pick
        partialCity ??= stdCity;
        partialClass ??= matchedClass;
        partialSerial ??= matchedSerial;
        continue;
      }

      final formatted = '$stdCity-$matchedSeries $matchedClass-$matchedSerial';
      candidates.add(formatted);

      if (bestFormatted == null) {
        bestFormatted = formatted;
        bestCity = stdCity;
        bestSeries = matchedSeries;
        bestClass = matchedClass;
        bestSerial = matchedSerial;
      }
    }

    // Attempt loose fallback if standard city regex didn't match:
    // Any word followed by 1-4 letters and 2 digits and 4 digits
    if (bestFormatted == null) {
      final looseRegex = RegExp(
        r'\b([A-Z\s]{3,20}?)\s*[-]?\s*([A-Z]{1,4})\s*[-]?\s*(\d{2})\s*[-]?\s*(\d{4})\b',
      );
      final looseMatch = looseRegex.firstMatch(clean);
      if (looseMatch != null) {
        final rawCity = looseMatch.group(1)?.trim().toUpperCase() ?? '';
        final rawSeries = looseMatch.group(2)?.trim().toUpperCase() ?? '';
        final rawClass = looseMatch.group(3)?.trim() ?? '';
        final rawSerial = looseMatch.group(4)?.trim() ?? '';

        // Only accept if rawCity looks somewhat like a city (at least 3 alpha chars) and the series
        // is a real BRTA series, so text like "TRIP FARE 12 3456" is not taken for a plate
        if (RegExp(r'^[A-Z\s]+$').hasMatch(rawCity) && rawCity.length >= 3 && _isKnownSeries(rawSeries)) {
          final stdCity = cityAliases[rawCity] ?? rawCity;
          bestFormatted = '$stdCity-$rawSeries $rawClass-$rawSerial';
          bestCity = stdCity;
          bestSeries = rawSeries;
          bestClass = rawClass;
          bestSerial = rawSerial;
          candidates.add(bestFormatted);
        }
      }
    }

    // Driver name & phone extraction from clearly labeled text
    final driverName = extractDriverName(rawInput);
    final driverPhone = extractDriverPhone(rawInput);

    if (bestFormatted == null) {
      // Plates are printed in Bangla on the vehicle itself: fall back to the Bangla parser
      final bangla = parseBanglaPlate(rawInput);
      if (bangla.hasPlate || bangla.hasNumber || bangla.city != null || bangla.series != null) {
        return RideOcrResult(driverName: driverName, driverPhone: driverPhone).mergeWith(bangla);
      }
      if (partialCity != null) {
        return RideOcrResult(
          rawText: rawInput,
          city: partialCity,
          classNumber: partialClass,
          serialNumber: partialSerial,
          driverName: driverName,
          driverPhone: driverPhone,
        );
      }
    }

    final bool isConfident = bestFormatted != null;
    final double confidence = isConfident ? 0.85 : 0.0;

    return RideOcrResult(
      rawText: rawInput,
      formattedPlate: bestFormatted,
      city: bestCity,
      series: bestSeries,
      classNumber: bestClass,
      serialNumber: bestSerial,
      driverName: driverName,
      driverPhone: driverPhone,
      confidence: confidence,
      isConfident: isConfident,
      candidatePlates: candidates,
    );
  }

  static bool _isKnownSeries(String series) =>
      BdPlateConstants.seriesList.any((s) => s.english == series);

  /// Extracts driver name only if clearly labeled (never guess)
  static String? extractDriverName(String text) {
    final lines = text.split(RegExp(r'[\r\n]+'));
    final labelRegex = RegExp(
      r'(?:driver|captain|rider|pilot)\s*(?:name)?\s*[:\-\—]\s*([A-Za-z\s\.]{3,30})',
      caseSensitive: false,
    );

    for (final line in lines) {
      final match = labelRegex.firstMatch(line);
      if (match != null) {
        final name = match.group(1)?.trim();
        if (name != null && name.length >= 3) {
          return name;
        }
      }
    }
    return null;
  }

  /// Extracts driver phone number if clearly formatted as BD mobile number
  static String? extractDriverPhone(String text) {
    // Look for lines with phone labels or standalone mobile pattern
    final phoneRegex = RegExp(r'(?:\+?88)?01[3-9]\d{8}');
    final match = phoneRegex.firstMatch(text);
    if (match != null) {
      String num = match.group(0)!;
      if (!num.startsWith('+88')) {
        num = '+88$num';
      }
      return num;
    }
    return null;
  }

  // ─── Readings from OCR text (pure, unit-tested) ────────────────────────────

  /// Converts a parsed result into a vote. Only fields that were actually read are included.
  static PlateReading readingFrom(RideOcrResult r, {double weight = 1.0, String source = ''}) {
    final number = r.classNumber != null && r.serialNumber != null
        ? '${r.classNumber}${r.serialNumber}'
        : null;
    return PlateReading(
      city: r.city,
      series: r.series,
      number: number,
      weight: weight,
      source: source,
    );
  }

  /// Reads the class + serial from OCR of the plate's bottom line only (digits whitelisted).
  /// Handles a lost separator and a separator misread as an extra digit.
  static PlateReading? readingFromNumberLine(String text, {String source = 'number-line'}) {
    final t = BdPlateConstants.normalizeDigits(text).replaceAll(RegExp(r'[—–―_~=]'), '-');
    final m = RegExp(r'(?<!\d)(\d{2})\s*[-.:,]?\s*(\d{4})(?!\d)').firstMatch(t);
    if (m != null) {
      return PlateReading(number: '${m.group(1)}${m.group(2)}', source: source);
    }
    final digits = t.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 6) {
      return PlateReading(number: digits, source: source);
    }
    // "31-9957" read as "3119957": the dash became a 1 (or 7). Weak evidence only.
    if (digits.length == 7 && (digits[2] == '1' || digits[2] == '7')) {
      return PlateReading(
        number: digits.substring(0, 2) + digits.substring(3),
        weight: 0.5,
        source: '$source(dash)',
      );
    }
    return null;
  }

  /// Reads the city + series from OCR of the plate's top line only
  static PlateReading? readingFromCityLine(String text, {String source = 'city-line'}) {
    final normalized = normalizeBanglaText(text);
    final city = _findBanglaCity(normalized);
    final series = _findBanglaSeries(city != null ? normalized.substring(city.end) : normalized);
    if (city != null || series != null) {
      return PlateReading(city: city?.city, series: series, source: source);
    }
    // English-printed plate
    final latin = fixLatinCityNames(normalizeOcrText(text));
    final m = RegExp(
      '\\b(${(cityAliases.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).map(RegExp.escape).join('|')})\\s*-?\\s*([A-Z]{1,4})\\b',
    ).firstMatch(latin);
    if (m == null) return null;
    final latinSeries = m.group(2)!;
    return PlateReading(
      city: cityAliases[m.group(1)!],
      series: _isKnownSeries(latinSeries) ? latinSeries : null,
      source: '$source(latin)',
    );
  }

  /// Builds the final result from the votes
  static RideOcrResult resultFromConsensus(
    PlateConsensus c, {
    String rawText = '',
    String? driverName,
    String? driverPhone,
    String source = 'device',
  }) {
    final formatted = c.isComplete
        ? '${c.city}-${c.series} ${c.classNumber}-${c.serialNumber}'
        : null;
    final confidence = c.isComplete
        ? math.min(c.cityConfidence, math.min(c.seriesConfidence, c.numberConfidence))
        : 0.0;
    return RideOcrResult(
      rawText: rawText,
      formattedPlate: formatted,
      city: c.city,
      series: c.series,
      classNumber: c.classNumber,
      serialNumber: c.serialNumber,
      driverName: driverName,
      driverPhone: driverPhone,
      confidence: confidence,
      isConfident: c.isConfident,
      candidatePlates: formatted != null ? [formatted] : const [],
      cityConfidence: c.cityConfidence,
      seriesConfidence: c.seriesConfidence,
      numberConfidence: c.numberConfidence,
      uncertainDigits: c.uncertainDigits,
      source: source,
    );
  }

  // ─── Photo preparation for the crop screen ─────────────────────────────────

  /// Bakes orientation, caps the size and suggests where the plate is (fractions 0-1 of the
  /// image as [left, top, right, bottom]) so the crop box starts close to it.
  Future<PreparedPlatePhoto?> preparePhoto(File photo) async {
    final tempDir = await getTemporaryDirectory();
    final out = '${tempDir.path}/plate_photo_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final normalized = await PlateImageProcessor.normalizePhoto(photo.path, out);
    if (normalized == null) return null;

    List<double>? suggestion;
    try {
      final latin = await _recognizeLatin(File(normalized.path));
      final area = latin.plateArea;
      if (area != null) {
        final w = normalized.width.toDouble(), h = normalized.height.toDouble();
        final bw = (area[2] - area[0]).toDouble(), bh = (area[3] - area[1]).toDouble();
        suggestion = [
          ((area[0] - bw * 0.1) / w).clamp(0.0, 1.0),
          ((area[1] - bh * 0.4) / h).clamp(0.0, 1.0),
          ((area[2] + bw * 0.1) / w).clamp(0.0, 1.0),
          ((area[3] + bh * 0.4) / h).clamp(0.0, 1.0),
        ];
      }
    } catch (e) {
      debugPrint('[RideOcrService] plate area suggestion failed: $e');
    }

    return PreparedPlatePhoto(
      file: File(normalized.path),
      width: normalized.width,
      height: normalized.height,
      suggestedRegion: suggestion,
    );
  }

  /// Cuts the plate out of a prepared photo; [region] is [left, top, right, bottom] in 0-1
  Future<File?> cropPlate(File photo, List<double> region) async {
    final tempDir = await getTemporaryDirectory();
    final out = '${tempDir.path}/plate_crop_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final path = await PlateImageProcessor.cropToFile(photo.path, out, region);
    return path == null ? null : File(path);
  }

  // ─── Recognition pipeline ──────────────────────────────────────────────────

  /// Serializes Tesseract calls: the plugin shares one native engine across calls
  Future<void> _tesseractQueue = Future.value();

  /// Reads a plate from [imageFile].
  ///
  /// [isPlateCrop] says the image is already cropped to the plate (from the crop screen).
  /// Every pass produces a vote; the result carries a per-field confidence and is only
  /// "confident" when independent passes agree.
  ///
  /// 1. ML Kit Latin: English plates and ride-app screenshots (clean digital text).
  /// 2. Gemini (when configured and online): strongest reader for Bangla plates.
  /// 3. Tesseract Bangla on pre-processed variants: the plate split into its two lines, the
  ///    number line read with a digits-only whitelist, each line binarized and in grayscale.
  Future<RideOcrResult> recognizePlate(
    File imageFile, {
    bool isPlateCrop = false,
    void Function(String message)? onProgress,
  }) async {
    final readings = <PlateReading>[];
    final rawTexts = <String>[];

    // 1. ML Kit Latin
    onProgress?.call('Reading text…');
    final latin = await _recognizeLatin(imageFile);
    final latinResult = latin.result;
    if (latinResult.rawText?.isNotEmpty == true) rawTexts.add(latinResult.rawText!);
    final driverName = latinResult.driverName;
    final driverPhone = latinResult.driverPhone;

    final latinReading = readingFrom(
      latinResult,
      // A screenshot's printed text is reliable; a camera photo of a plate is not
      weight: isPlateCrop ? 1.0 : 2.0,
      source: 'mlkit',
    );
    if (!latinReading.isEmpty) readings.add(latinReading);

    RideOcrResult current() => resultFromConsensus(
          PlateVoting.decide(readings),
          rawText: rawTexts.join('\n'),
          driverName: driverName,
          driverPhone: driverPhone,
          source: readings.any((r) => r.source == 'gemini') ? 'cloud' : 'device',
        );

    if (!isPlateCrop && latinResult.hasPlate) {
      debugPrint('[RideOcrService] ✅ plate from screenshot text: ${latinResult.formattedPlate}');
      return current();
    }

    // 2. Cloud reader
    final gemini = GeminiPlateReader.instance;
    if (gemini.isConfigured) {
      onProgress?.call('Reading plate with AI…');
      final cloud = await gemini.read(imageFile);
      if (cloud != null) {
        readings.add(cloud.reading);
        if (cloud.rawText.isNotEmpty) rawTexts.add(cloud.rawText);
        final result = current();
        if (result.isConfident) {
          debugPrint('[RideOcrService] ✅ plate from cloud: ${result.formattedPlate}');
          return result;
        }
      }
    }

    // 3. On-device Bangla OCR
    onProgress?.call('Reading Bangla plate on device…');
    final deviceReadings = await _readOnDevice(
      imageFile,
      isPlateCrop: isPlateCrop,
      textArea: isPlateCrop ? null : latin.plateArea,
      rawTexts: rawTexts,
    );
    readings.addAll(deviceReadings);

    final result = current();
    debugPrint('[RideOcrService] 🗳 ${readings.length} readings -> ${result.formattedPlate ?? '(partial)'} '
        'conf city=${result.cityConfidence.toStringAsFixed(2)} '
        'series=${result.seriesConfidence.toStringAsFixed(2)} '
        'number=${result.numberConfidence.toStringAsFixed(2)} uncertain=${result.uncertainDigits}');
    return result;
  }

  Future<List<PlateReading>> _readOnDevice(
    File imageFile, {
    required bool isPlateCrop,
    required List<int>? textArea,
    required List<String> rawTexts,
  }) async {
    final readings = <PlateReading>[];
    final tempDir = await getTemporaryDirectory();
    final prefix = '${tempDir.path}/plate_ocr_${DateTime.now().microsecondsSinceEpoch}';

    // Without a crop and without any text located, read the whole photo sparsely
    final useCrop = isPlateCrop || textArea != null;
    PlateVariantPaths? variants;
    try {
      variants = await PlateImageProcessor.buildVariants(
        imageFile.path,
        prefix,
        crop: isPlateCrop ? null : textArea,
        plateMode: isPlateCrop,
      );
      if (variants == null) return readings;

      Future<String> ocr(String path, String psm, {String whitelist = ''}) async {
        try {
          final text = await _runTesseract(path, psm, whitelist: whitelist);
          rawTexts.add(text);
          debugPrint('[RideOcrService] 🔍 ${path.split('_').skip(2).join('_')} psm$psm: '
              '${text.replaceAll('\n', ' | ')}');
          return text;
        } catch (e) {
          debugPrint('[RideOcrService] ❌ Tesseract error: $e');
          return '';
        }
      }

      bool agreed(List<PlateReading> list, String? Function(PlateReading) key) {
        final counts = <String, int>{};
        for (final r in list) {
          final k = key(r);
          if (k != null) counts[k] = (counts[k] ?? 0) + 1;
        }
        return counts.values.any((c) => c >= 2);
      }

      if (variants.isSplit) {
        // Number line: digits only, single text line. Stop once two passes agree.
        const digitWhitelist = '০১২৩৪৫৬৭৮৯0123456789-';
        final numberReads = <PlateReading>[];
        for (final path in [variants.bottomBinary!, variants.bottomGray!, variants.bottomBold!]) {
          final r = readingFromNumberLine(await ocr(path, '7', whitelist: digitWhitelist));
          if (r != null) numberReads.add(r);
          if (agreed(numberReads, (r) => r.number)) break;
        }
        readings.addAll(numberReads);

        // City line
        final cityReads = <PlateReading>[];
        for (final path in [variants.topBinary!, variants.topGray!]) {
          final r = readingFromCityLine(await ocr(path, '7'));
          if (r != null) cityReads.add(r);
          if (agreed(cityReads, (r) => r.city) && agreed(cityReads, (r) => r.series)) break;
        }
        readings.addAll(cityReads);
      }

      // Whole plate as a block: a cross-check when split, the main read when not
      final wholePasses = variants.isSplit
          ? [(variants.fullGray, '6')]
          : useCrop
              ? [(variants.fullBinary, '6'), (variants.fullGray, '6'), (variants.fullGray, '11')]
              : [(variants.fullGray, '11'), (variants.fullBinary, '11')];
      for (final (path, psm) in wholePasses) {
        final reading = readingFrom(parsePlateFromText(await ocr(path, psm)), source: 'tess-full');
        if (!reading.isEmpty) readings.add(reading);
      }
    } catch (e) {
      debugPrint('[RideOcrService] ❌ on-device OCR error: $e');
    } finally {
      for (final path in variants?.all ?? const <String>[]) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    return readings;
  }

  /// ML Kit Latin pass. Besides the parsed result it returns where the plate probably is
  /// ([left, top, right, bottom] in pixels): ML Kit locates Bangla text even though it can't
  /// read it.
  Future<({RideOcrResult result, List<int>? plateArea})> _recognizeLatin(File imageFile) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final RecognizedText recognizedText = await recognizer.processImage(inputImage);
      final raw = recognizedText.text;
      debugPrint('[RideOcrService] 🔍 ML Kit text length: ${raw.length}');
      return (
        result: parsePlateFromText(raw),
        plateArea: _plateAreaFrom(recognizedText.blocks.map((b) => b.boundingBox).toList()),
      );
    } catch (e) {
      debugPrint('[RideOcrService] ❌ OCR error: $e');
      return (result: const RideOcrResult(rawText: ''), plateArea: null);
    } finally {
      await recognizer.close();
    }
  }

  /// Union of the text blocks, unless that covers most of the photo (background signs, stickers):
  /// then the largest wide block, which on a vehicle photo is usually the plate.
  static List<int>? _plateAreaFrom(List<Rect> boxes) {
    if (boxes.isEmpty) return null;
    var union = boxes.first;
    for (final b in boxes.skip(1)) {
      union = union.expandToInclude(b);
    }
    var area = union;
    if (boxes.length > 1) {
      final largest = boxes.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
      if (union.width * union.height > 4 * largest.width * largest.height) area = largest;
    }
    return [area.left.floor(), area.top.floor(), area.right.ceil(), area.bottom.ceil()];
  }

  /// [whitelist] is always sent (empty clears it): the plugin keeps one Tesseract engine and
  /// variables persist across calls, so a digits-only whitelist would otherwise leak into the
  /// next city-line read.
  Future<String> _runTesseract(String imagePath, String psm, {String whitelist = ''}) {
    final run = _tesseractQueue.then(
      (_) => FlutterTesseractOcr.extractText(
        imagePath,
        language: 'ben',
        args: {
          'psm': psm,
          'preserve_interword_spaces': '1',
          'tessedit_char_whitelist': whitelist,
        },
      ).timeout(const Duration(seconds: 25)),
    );
    _tesseractQueue = run.then((_) {}, onError: (_) {});
    return run;
  }
}

/// A photo ready for the crop screen: orientation baked in, size capped
class PreparedPlatePhoto {
  final File file;
  final int width;
  final int height;

  /// Where the plate probably is, [left, top, right, bottom] as fractions 0-1; null if unknown
  final List<double>? suggestedRegion;

  const PreparedPlatePhoto({
    required this.file,
    required this.width,
    required this.height,
    this.suggestedRegion,
  });
}
