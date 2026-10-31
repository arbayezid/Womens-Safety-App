import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../constants/bd_plate_constants.dart';

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

  /// Parses a plate from text using a tolerant regex for Bangladesh plates.
  /// Handles formats like:
  /// - `DHAKA METRO-GA 11-2233`
  /// - `DHAKA METRO GA 112233`
  /// - `CHATTA METRO-HA 12 3456`
  /// - `DHAKA-THA 11-2233`
  /// - `GAZIPUR-HA 11-2233`
  static RideOcrResult parsePlateFromText(String rawInput) {
    final clean = normalizeOcrText(rawInput);
    if (clean.isEmpty) {
      return const RideOcrResult();
    }

    // Build city pattern from known city keys
    final sortedCities = cityAliases.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final cityPattern = sortedCities.map(RegExp.escape).join('|');

    // Regex allowing missing or extra spaces, hyphens, and standard structure
    // Group 1: City
    // Group 2: Series (1 to 3 letters)
    // Group 3: Class (2 digits)
    // Group 4: Serial (4 digits)
    final plateRegex = RegExp(
      '\\b($cityPattern)\\s*[-]?\\s*([A-Z]{1,3})\\s*[-]?\\s*(\\d{2})\\s*[-]?\\s*(\\d{4})\\b',
      caseSensitive: false,
    );

    final matches = plateRegex.allMatches(clean);
    final candidates = <String>[];
    String? bestFormatted;
    String? bestCity;
    String? bestSeries;
    String? bestClass;
    String? bestSerial;

    for (final match in matches) {
      final matchedCityRaw = match.group(1)?.trim().toUpperCase() ?? '';
      final matchedSeriesRaw = match.group(2)?.trim().toUpperCase() ?? '';
      final matchedClass = match.group(3)?.trim() ?? '';
      final matchedSerial = match.group(4)?.trim() ?? '';

      final stdCity = cityAliases[matchedCityRaw] ?? matchedCityRaw;
      final stdSeries = matchedSeriesRaw;

      final formatted = '$stdCity-$stdSeries $matchedClass-$matchedSerial';
      candidates.add(formatted);

      if (bestFormatted == null) {
        bestFormatted = formatted;
        bestCity = stdCity;
        bestSeries = stdSeries;
        bestClass = matchedClass;
        bestSerial = matchedSerial;
      }
    }

    // Attempt loose fallback if standard city regex didn't match:
    // Any word followed by 1-3 letters and 2 digits and 4 digits
    if (bestFormatted == null) {
      final looseRegex = RegExp(
        r'\b([A-Z\s]{3,20}?)\s*[-]?\s*([A-Z]{1,3})\s*[-]?\s*(\d{2})\s*[-]?\s*(\d{4})\b',
      );
      final looseMatch = looseRegex.firstMatch(clean);
      if (looseMatch != null) {
        final rawCity = looseMatch.group(1)?.trim().toUpperCase() ?? '';
        final rawSeries = looseMatch.group(2)?.trim().toUpperCase() ?? '';
        final rawClass = looseMatch.group(3)?.trim() ?? '';
        final rawSerial = looseMatch.group(4)?.trim() ?? '';

        // Only accept if rawCity looks somewhat like a city (at least 3 alpha chars) and the series
        // is a real BRTA series, so text like "TRIP FARE 12 3456" is not taken for a plate
        final isKnownSeries = BdPlateConstants.seriesList.any((s) => s.english == rawSeries);
        if (RegExp(r'^[A-Z\s]+$').hasMatch(rawCity) && rawCity.length >= 3 && isKnownSeries) {
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

    // Plates are printed in Bangla on the vehicle itself: fall back to the Bangla parser
    if (bestFormatted == null) {
      final bangla = parseBanglaPlate(rawInput);
      if (bangla.hasPlate || bangla.hasNumber || bangla.city != null || bangla.series != null) {
        return RideOcrResult(driverName: driverName, driverPhone: driverPhone).mergeWith(bangla);
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

  /// Serializes Tesseract calls: the plugin shares one native engine across calls
  Future<void> _tesseractQueue = Future.value();

  /// Reads a plate from the given image file.
  ///
  /// 1. ML Kit Latin OCR: fast, handles English plates and ride-app screenshots.
  /// 2. If no full plate was found, Tesseract Bangla OCR (ML Kit has no Bengali model), first on the
  ///    whole photo, then cropped to the text area ML Kit located, since a tight crop reads best.
  Future<RideOcrResult> recognizePlate(File imageFile) async {
    final latin = await _recognizeLatin(imageFile);
    var result = latin.result;
    if (result.hasPlate) return result;

    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final passes = <({String name, List<int>? crop, String psm})>[
      (name: 'full', crop: null, psm: '11'), // sparse text: finds the plate anywhere in the photo
      if (latin.textArea != null) (name: 'crop', crop: latin.textArea, psm: '6'), // uniform block
    ];

    for (final pass in passes) {
      final outPath = '${tempDir.path}/plate_ocr_${stamp}_${pass.name}.png';
      try {
        final prepared = await _prepareForTesseract(imageFile.path, outPath, pass.crop);
        if (prepared == null) continue;

        final text = await _runTesseract(prepared, pass.psm);
        debugPrint('[RideOcrService] 🔍 Bangla OCR (${pass.name}) text: ${text.replaceAll('\n', ' | ')}');
        result = result.mergeWith(parsePlateFromText(text));
        if (result.hasPlate) break;
      } catch (e) {
        debugPrint('[RideOcrService] ❌ Bangla OCR (${pass.name}) error: $e');
      } finally {
        try {
          await File(outPath).delete();
        } catch (_) {}
      }
    }
    return result;
  }

  /// ML Kit Latin pass. Besides the parsed result it returns the bounding box of all detected text
  /// as [left, top, right, bottom]: ML Kit still locates Bangla text even though it can't read it.
  Future<({RideOcrResult result, List<int>? textArea})> _recognizeLatin(File imageFile) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final RecognizedText recognizedText = await recognizer.processImage(inputImage);
      final raw = recognizedText.text;
      debugPrint('[RideOcrService] 🔍 OCR Extracted text length: ${raw.length}');

      List<int>? area;
      for (final block in recognizedText.blocks) {
        final r = block.boundingBox;
        area = area == null
            ? [r.left.floor(), r.top.floor(), r.right.ceil(), r.bottom.ceil()]
            : [
                math.min(area[0], r.left.floor()),
                math.min(area[1], r.top.floor()),
                math.max(area[2], r.right.ceil()),
                math.max(area[3], r.bottom.ceil()),
              ];
      }
      return (result: parsePlateFromText(raw), textArea: area);
    } catch (e) {
      debugPrint('[RideOcrService] ❌ OCR error: $e');
      return (result: const RideOcrResult(rawText: ''), textArea: null);
    } finally {
      await recognizer.close();
    }
  }

  Future<String> _runTesseract(String imagePath, String psm) {
    final run = _tesseractQueue.then(
      (_) => FlutterTesseractOcr.extractText(
        imagePath,
        language: 'ben',
        args: {'psm': psm, 'preserve_interword_spaces': '1'},
      ).timeout(const Duration(seconds: 25)),
    );
    _tesseractQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Grayscale + contrast-stretched copy of the photo, optionally cropped to [crop]
  /// ([left, top, right, bottom], padded generously because ML Kit may only box part of the plate)
  /// and scaled to a size Tesseract handles well. Runs off the UI isolate.
  static Future<String?> _prepareForTesseract(String srcPath, String outPath, List<int>? crop) {
    return Isolate.run(() {
      var image = img.decodeImage(File(srcPath).readAsBytesSync());
      if (image == null) return null;
      image = img.bakeOrientation(image);

      if (crop != null) {
        final w = crop[2] - crop[0];
        final h = crop[3] - crop[1];
        final left = math.max(0, crop[0] - (w * 0.15).round());
        final top = math.max(0, crop[1] - (h * 0.6).round());
        final right = math.min(image.width, crop[2] + (w * 0.15).round());
        final bottom = math.min(image.height, crop[3] + (h * 0.6).round());
        if (right - left < 20 || bottom - top < 20) return null;
        image = img.copyCrop(image, x: left, y: top, width: right - left, height: bottom - top);
      }

      final longest = math.max(image.width, image.height);
      const minSide = 1000, maxSide = 1600;
      if (longest > maxSide || longest < minSide) {
        final scale = (longest > maxSide ? maxSide : minSide) / longest;
        image = img.copyResize(
          image,
          width: (image.width * scale).round(),
          height: (image.height * scale).round(),
          interpolation: img.Interpolation.cubic,
        );
      }

      image = img.grayscale(image);
      image = img.normalize(image, min: 0, max: 255);

      File(outPath).writeAsBytesSync(img.encodePng(image));
      return outPath;
    });
  }
}
