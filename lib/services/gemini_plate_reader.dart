import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../constants/bd_plate_constants.dart';
import 'plate_consensus.dart';
import 'plate_image_processor.dart';
import 'ride_ocr_service.dart';

/// What the cloud model read from the image
class CloudPlateReading {
  final PlateReading reading;
  final String rawText;

  /// 'high' | 'medium' | 'low', as judged by the model itself
  final String confidence;

  const CloudPlateReading({
    required this.reading,
    required this.rawText,
    required this.confidence,
  });
}

/// Optional cloud plate reader using the Gemini API (free tier, Google AI Studio key).
///
/// Bangla plates are hard for on-device Tesseract; a multimodal model reads them far more
/// reliably. Enabled only when the app is built with
/// `--dart-define=GEMINI_API_KEY=...` (or `--dart-define-from-file=secrets.json`); without a
/// key, or when offline, the app silently uses on-device OCR only.
class GeminiPlateReader {
  GeminiPlateReader._();
  static final GeminiPlateReader instance = GeminiPlateReader._();

  static const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const String _model = String.fromEnvironment('GEMINI_MODEL', defaultValue: 'gemini-3.5-flash');

  /// Tried in order after [_model] when a model is retired (404), rate-limited (429),
  /// overloaded (5xx) or too slow. Google retires model names for new keys regularly
  /// (gemini-2.5-flash was closed to new users by Nov 2026), so one name is not enough.
  /// Measured Nov 2026 on the free tier: 3.5-flash often answers 503 within ~3s when busy,
  /// 3.5-flash-lite read a test plate correctly in ~2s, 3.8-flash could hang, so it goes last.
  static const List<String> _fallbackModels = [
    'gemini-3.5-flash',
    'gemini-3.5-flash-lite',
    'gemini-flash-latest',
    'gemini-3.8-flash',
  ];

  /// Per-attempt limit, and the limit for all attempts together: after that the
  /// on-device OCR takes over, so the user is never left waiting on the network.
  static const Duration _attemptTimeout = Duration(seconds: 12);
  static const Duration _totalBudget = Duration(seconds: 30);

  bool get isConfigured => _apiKey.isNotEmpty;

  @visibleForTesting
  static List<String> get modelChain => {_model, ..._fallbackModels}.toList();

  /// Whether a failed attempt is worth retrying on the next model
  @visibleForTesting
  static bool shouldTryNextModel(int status) =>
      status == 404 || status == 429 || status >= 500 || status == 0;

  /// Reads the plate in [image]. Returns null when not configured, offline, on any API error,
  /// or when the model saw no plate. Never throws.
  Future<CloudPlateReading?> read(File image) async {
    if (!isConfigured) return null;
    try {
      final bytes = await PlateImageProcessor.encodeForUpload(image.path);
      if (bytes == null) return null;

      final deadline = DateTime.now().add(_totalBudget);
      for (final model in modelChain) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining < const Duration(seconds: 3)) break;
        final timeout = remaining < _attemptTimeout ? remaining : _attemptTimeout;

        ({int status, String body}) response;
        try {
          response = await _generate(model, bytes, timeout);
          // Older models reject the thinking setting: same model again without it
          if (response.status == 400 && response.body.toLowerCase().contains('thinking')) {
            response = await _generate(model, bytes, timeout, lowThinking: false);
          }
        } on TimeoutException {
          debugPrint('[GeminiPlateReader] ⏱ $model timed out');
          continue;
        } on SocketException catch (e) {
          // Offline: other models won't do better
          debugPrint('[GeminiPlateReader] 📵 offline: ${e.message}');
          return null;
        }

        if (response.status == 200) {
          final text = extractResponseText(response.body);
          if (text == null) return null;
          debugPrint('[GeminiPlateReader] 🔍 $model: $text');
          return parseModelJson(text, model: model);
        }
        debugPrint('[GeminiPlateReader] ❌ $model HTTP ${response.status}: ${_shorten(response.body)}');
        if (!shouldTryNextModel(response.status)) return null; // bad key, bad request: stop
      }
      return null;
    } catch (e) {
      debugPrint('[GeminiPlateReader] ❌ $e');
      return null;
    }
  }

  Future<({int status, String body})> _generate(
    String model,
    List<int> jpeg,
    Duration timeout, {
    bool lowThinking = true,
  }) async {
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:generateContent',
    );
    final payload = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(jpeg)},
            },
            {'text': buildPrompt()},
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
        'responseSchema': _responseSchema,
        // Reading a plate needs little reasoning; low thinking cut latency from ~11s to ~2s
        if (lowThinking) 'thinkingConfig': {'thinkingLevel': 'low'},
      },
    });

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      Future<({int status, String body})> send() async {
        final request = await client.postUrl(uri);
        request.headers.contentType = ContentType.json;
        request.headers.set('x-goog-api-key', _apiKey);
        request.add(utf8.encode(payload));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        return (status: response.statusCode, body: body);
      }

      return await send().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static final Map<String, dynamic> _responseSchema = {
    'type': 'OBJECT',
    'properties': {
      'plate_found': {'type': 'BOOLEAN'},
      'plate_text': {
        'type': 'STRING',
        'description': 'The plate exactly as printed, both lines, original script',
      },
      'city': {
        'type': 'STRING',
        'format': 'enum',
        'enum': [...BdPlateConstants.metroCities, 'UNKNOWN'],
      },
      'series': {
        'type': 'STRING',
        'format': 'enum',
        'enum': [...BdPlateConstants.seriesList.map((s) => s.english), 'UNKNOWN'],
      },
      'class_number': {'type': 'STRING', 'description': '2 ASCII digits, or empty'},
      'serial_number': {'type': 'STRING', 'description': '4 ASCII digits, or empty'},
      'confidence': {
        'type': 'STRING',
        'format': 'enum',
        'enum': ['high', 'medium', 'low'],
      },
    },
    'required': [
      'plate_found',
      'plate_text',
      'city',
      'series',
      'class_number',
      'serial_number',
      'confidence',
    ],
  };

  @visibleForTesting
  static String buildPrompt() {
    final cities = RideOcrService.banglaCityAliases.entries
        .map((e) => '${e.key} = ${e.value}')
        .join(', ');
    final series = BdPlateConstants.seriesList.map((s) => '${s.bengali} = ${s.english}').join(', ');
    return '''
You read Bangladesh (BRTA) vehicle registration plates. The image is either a photo of a vehicle number plate or a ride-hailing app screenshot (Uber, Pathao, Obhai).

Plates are normally printed in Bangla on two lines:
  line 1: district / metro name + series letter, e.g. "ঢাকা মেট্রো-গ"
  line 2: 2-digit class number + 4-digit serial, e.g. "৩১-৯৯৫৭"
Some plates and most app screenshots use English, e.g. "DHAKA METRO-GA 31-9957".

Rules:
- Transcribe exactly what is printed. Never guess, complete or invent characters.
- Convert Bangla digits to ASCII: ০=0 ১=1 ২=2 ৩=3 ৪=4 ৫=5 ৬=6 ৭=7 ৮=8 ৯=9. Take special care with ৩/৬/৯, ১/৭ and ৪/৮.
- city: Bangla to code: $cities. "মেট্রো" after the name means METRO. Use UNKNOWN if not readable.
- series: the single Bangla letter after the city: $series. Use UNKNOWN if not readable.
  These letters look alike, so check the exact shape before answering: থ (THA, CNG) vs খ (KHA); ব (BA) vs র (RA); ঘ (GHA) vs ম (MA); ড (DA) vs ড় ; চ (CHA) vs ছ (CHHA); জ (JA) vs ঝ (JHA).
  If you cannot tell which of two look-alike letters it is, set confidence to "medium".
- class_number must be exactly 2 digits and serial_number exactly 4 digits; leave a field empty if any of its digits is unreadable.
- If several plates are visible, read the largest, clearest one.
- confidence: "high" only if every character is clearly legible; "medium" if any character needed interpretation; "low" if blurry, partly hidden or cut off.
- plate_found is false if no vehicle number plate or plate number is visible.''';
  }

  /// Pulls the model's text out of a generateContent response body
  @visibleForTesting
  static String? extractResponseText(String body) {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final parts = (candidates.first as Map?)?['content']?['parts'];
    if (parts is! List) return null;
    final text = parts
        .whereType<Map>()
        .where((p) => p['thought'] != true)
        .map((p) => p['text'])
        .whereType<String>()
        .join();
    return text.isEmpty ? null : text;
  }

  /// Validates the model's JSON answer against BRTA plate rules; invalid fields are dropped
  /// rather than trusted.
  ///
  /// Lite models get a lower vote: in testing gemini-3.5-flash-lite read থ as খ on a small
  /// plate while still claiming "high" confidence. Their answer then needs an agreeing
  /// on-device read before a field counts as confident.
  @visibleForTesting
  static CloudPlateReading? parseModelJson(String text, {String model = ''}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(_stripCodeFence(text));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['plate_found'] != true) return null;

    final cityRaw = decoded['city']?.toString().trim().toUpperCase();
    final seriesRaw = decoded['series']?.toString().trim().toUpperCase();
    final classRaw = BdPlateConstants.normalizeDigits(decoded['class_number']?.toString() ?? '')
        .replaceAll(RegExp(r'\D'), '');
    final serialRaw = BdPlateConstants.normalizeDigits(decoded['serial_number']?.toString() ?? '')
        .replaceAll(RegExp(r'\D'), '');
    final confidence = decoded['confidence']?.toString().toLowerCase() ?? 'low';

    final city = BdPlateConstants.metroCities.contains(cityRaw) ? cityRaw : null;
    final series = BdPlateConstants.seriesList.any((s) => s.english == seriesRaw) ? seriesRaw : null;
    final number = classRaw.length == 2 && serialRaw.length == 4 ? '$classRaw$serialRaw' : null;
    final validNumber = number != null && PlateVoting.isPlausibleNumber(number) ? number : null;

    if (city == null && series == null && validNumber == null) return null;

    final isLite = model.contains('lite');
    final weight = switch (confidence) {
      'high' => isLite ? 1.0 : 2.0,
      'medium' => isLite ? 0.75 : 1.25,
      _ => 0.5,
    };
    return CloudPlateReading(
      reading: PlateReading(
        city: city,
        series: series,
        number: validNumber,
        weight: weight,
        source: PlateVoting.cloudSource,
      ),
      rawText: decoded['plate_text']?.toString() ?? '',
      confidence: confidence,
    );
  }

  static String _stripCodeFence(String text) {
    final t = text.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    return fence.firstMatch(t)?.group(1) ?? t;
  }

  static String _shorten(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
