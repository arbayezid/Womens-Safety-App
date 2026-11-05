import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_safety/constants/bd_plate_constants.dart';
import 'package:smart_safety/services/gemini_plate_reader.dart';
import 'package:smart_safety/services/plate_consensus.dart';
import 'package:smart_safety/services/plate_image_processor.dart';
import 'package:smart_safety/services/ride_ocr_service.dart';

void main() {
  group('PlateVoting', () {
    test('two agreeing device passes are confident', () {
      final c = PlateVoting.decide(const [
        PlateReading(city: 'DHAKA METRO', series: 'GA', number: '319957'),
        PlateReading(city: 'DHAKA METRO', series: 'GA', number: '319957'),
      ]);
      expect(c.isConfident, isTrue);
      expect(c.classNumber, '31');
      expect(c.serialNumber, '9957');
      expect(c.uncertainDigits, isEmpty);
    });

    test('a single device pass is never confident on its own', () {
      final c = PlateVoting.decide(const [
        PlateReading(city: 'DHAKA METRO', series: 'GA', number: '319957'),
      ]);
      expect(c.isComplete, isTrue);
      expect(c.isConfident, isFalse);
      expect(c.numberConfidence, 0.5);
    });

    test('a high-confidence cloud read alone is confident', () {
      final c = PlateVoting.decide(const [
        PlateReading(city: 'DHAKA METRO', series: 'GA', number: '319957', weight: 2, source: 'gemini'),
      ]);
      expect(c.isConfident, isTrue);
    });

    test('per-digit voting repairs passes that each misread a different digit', () {
      final c = PlateVoting.decide(const [
        PlateReading(number: '319957'),
        PlateReading(number: '369957'), // 1 -> 6
        PlateReading(number: '319951'), // 7 -> 1
      ]);
      expect('${c.classNumber}${c.serialNumber}', '319957');
      // Positions 1 and 5 had 2 of 3 votes: below the 0.75 threshold, so flagged for the user
      expect(c.uncertainDigits, [1, 5]);
    });

    test('disagreement lowers confidence and flags the digit', () {
      final c = PlateVoting.decide(const [
        PlateReading(number: '319957'),
        PlateReading(number: '619957'),
      ]);
      expect(c.uncertainDigits, contains(0));
      expect(c.numberConfidence, lessThan(PlateVoting.confidentThreshold));
    });

    test('look-alike series read only by the cloud is flagged (Gemini read থ as খ)', () {
      const cloud = PlateReading(
        city: 'CHATTA METRO', series: 'KHA', number: '114863', weight: 2, source: PlateVoting.cloudSource,
      );
      final alone = PlateVoting.decide(const [cloud]);
      expect(alone.cityConfidence, 1.0);
      expect(alone.numberConfidence, 1.0);
      expect(alone.seriesConfidence, lessThan(PlateVoting.confidentThreshold));
      expect(alone.isConfident, isFalse);

      // Device OCR reading the real letter outvotes or at least contests it
      final contested = PlateVoting.decide(const [
        cloud,
        PlateReading(series: 'THA', source: 'city-line'),
        PlateReading(series: 'THA', source: 'city-line'),
      ]);
      expect(contested.seriesConfidence, lessThan(PlateVoting.confidentThreshold));

      // ...and agreement from the device makes it trusted
      final agreed = PlateVoting.decide(const [cloud, PlateReading(series: 'KHA', source: 'city-line')]);
      expect(agreed.seriesConfidence, 1.0);
    });

    test('implausible numbers and unknown cities/series are ignored', () {
      final c = PlateVoting.decide(const [
        PlateReading(city: 'ATLANTIS', series: 'ZZ', number: '019957'),
        PlateReading(number: '110000'),
      ]);
      expect(c.city, isNull);
      expect(c.series, isNull);
      expect(c.classNumber, isNull);
    });

    test('latinToDigits converts look-alike letters', () {
      expect(PlateVoting.latinToDigits('I1-22O3'), '11-2203');
      expect(PlateVoting.latinToDigits('SB'), '58');
    });

    test('editDistance', () {
      expect(PlateVoting.editDistance('DHAKA METRO', 'DHAKA MFTRO'), 1);
      expect(PlateVoting.editDistance('abc', 'abc'), 0);
      expect(PlateVoting.editDistance('', 'ab'), 2);
    });
  });

  group('Tolerant English parser', () {
    test('O/0 and I/1 confusions in the number', () {
      final r = RideOcrService.parsePlateFromText('DHAKA METR0-GA I1-22O3');
      expect(r.formattedPlate, 'DHAKA METRO-GA 11-2203');
    });

    test('garbled city name is fuzzy-matched', () {
      final r = RideOcrService.parsePlateFromText('DHAKA MFTRO-KHA 15-7890');
      expect(r.formattedPlate, 'DHAKA METRO-KHA 15-7890');
    });

    test('four-letter CHHA series', () {
      final r = RideOcrService.parsePlateFromText('DHAKA METRO-CHHA 11-2233');
      expect(r.formattedPlate, 'DHAKA METRO-CHHA 11-2233');
    });

    test('unknown series keeps city and number but no full plate', () {
      final r = RideOcrService.parsePlateFromText('DHAKA METRO-XQ 11-2233');
      expect(r.hasPlate, isFalse);
      expect(r.city, 'DHAKA METRO');
      expect(r.classNumber, '11');
      expect(r.serialNumber, '2233');
    });

    test('ordinary words are not turned into city names', () {
      expect(RideOcrService.fixLatinCityNames('TRIP DETAILS DRIVER'), 'TRIP DETAILS DRIVER');
    });
  });

  group('Line readers', () {
    test('number line with Bangla digits', () {
      expect(RideOcrService.readingFromNumberLine('৩১-৯৯৫৭')?.number, '319957');
    });

    test('number line without separator', () {
      expect(RideOcrService.readingFromNumberLine('৩১৯৯৫৭')?.number, '319957');
    });

    test('dash misread as a digit gives a weak reading', () {
      final r = RideOcrService.readingFromNumberLine('3119957');
      expect(r?.number, '319957');
      expect(r?.weight, 0.5);
    });

    test('garbage number line gives nothing', () {
      expect(RideOcrService.readingFromNumberLine('৩১-৯'), isNull);
    });

    test('Bangla city line', () {
      final r = RideOcrService.readingFromCityLine('ঢাকা মেট্রো-গ');
      expect(r?.city, 'DHAKA METRO');
      expect(r?.series, 'GA');
    });

    test('Bangla city with one wrong consonant is fuzzy-matched', () {
      // ণ misread as ন
      final r = RideOcrService.readingFromCityLine('নারায়নগঞ্জ-ক');
      expect(r?.city, 'NARAYANGANJ');
      expect(r?.series, 'KA');
    });

    test('English city line', () {
      final r = RideOcrService.readingFromCityLine('DHAKA METRO-GA');
      expect(r?.city, 'DHAKA METRO');
      expect(r?.series, 'GA');
    });

    test('consensus result is formatted', () {
      final result = RideOcrService.resultFromConsensus(PlateVoting.decide([
        RideOcrService.readingFromCityLine('ঢাকা মেট্রো-থ')!,
        RideOcrService.readingFromCityLine('ঢাকা মেট্রো-থ')!,
        RideOcrService.readingFromNumberLine('১১-২২৩৩')!,
        RideOcrService.readingFromNumberLine('১১-২২৩৩')!,
      ]));
      expect(result.formattedPlate, 'DHAKA METRO-THA 11-2233');
      expect(result.isConfident, isTrue);
    });
  });

  group('Gemini response parsing', () {
    test('valid high-confidence answer', () {
      final r = GeminiPlateReader.parseModelJson('''
        {"plate_found": true, "plate_text": "ঢাকা মেট্রো-গ ৩১-৯৯৫৭", "city": "DHAKA METRO",
         "series": "GA", "class_number": "31", "serial_number": "9957", "confidence": "high"}''');
      expect(r, isNotNull);
      expect(r!.reading.city, 'DHAKA METRO');
      expect(r.reading.series, 'GA');
      expect(r.reading.number, '319957');
      expect(r.reading.weight, 2.0);
    });

    test('Bangla digits and code fences are accepted', () {
      final r = GeminiPlateReader.parseModelJson('```json\n'
          '{"plate_found": true, "plate_text": "", "city": "UNKNOWN", "series": "THA",'
          ' "class_number": "১১", "serial_number": "২২৩৩", "confidence": "medium"}\n```');
      expect(r!.reading.city, isNull);
      expect(r.reading.number, '112233');
      expect(r.reading.weight, 1.25);
    });

    test('invalid fields are dropped, not trusted', () {
      final r = GeminiPlateReader.parseModelJson(
          '{"plate_found": true, "plate_text": "", "city": "PARIS", "series": "GA",'
          ' "class_number": "3", "serial_number": "99577", "confidence": "low"}');
      expect(r!.reading.city, isNull);
      expect(r.reading.number, isNull);
      expect(r.reading.series, 'GA');
    });

    test('no plate', () {
      expect(GeminiPlateReader.parseModelJson('{"plate_found": false}'), isNull);
      expect(GeminiPlateReader.parseModelJson('not json'), isNull);
    });

    test('extracts text from a generateContent response, skipping thoughts', () {
      const body = '{"candidates":[{"content":{"parts":['
          '{"text":"thinking...","thought":true},{"text":"{\\"a\\":1}"}]}}]}';
      expect(GeminiPlateReader.extractResponseText(body), '{"a":1}');
    });

    test('lite models never count as confident on their own', () {
      const json = '{"plate_found": true, "plate_text": "", "city": "CHATTA METRO",'
          ' "series": "GA", "class_number": "11", "serial_number": "4863", "confidence": "high"}';
      final lite = GeminiPlateReader.parseModelJson(json, model: 'gemini-3.5-flash-lite')!;
      final full = GeminiPlateReader.parseModelJson(json, model: 'gemini-3.5-flash')!;
      expect(lite.reading.weight, 1.0);
      expect(full.reading.weight, 2.0);
      expect(PlateVoting.decide([lite.reading]).isConfident, isFalse);
      expect(PlateVoting.decide([full.reading]).isConfident, isTrue);
    });

    test('model chain and retry rules', () {
      final chain = GeminiPlateReader.modelChain;
      expect(chain.toSet().length, chain.length, reason: 'no duplicates');
      expect(chain, contains('gemini-3.5-flash-lite'));
      expect(chain.last, 'gemini-3.8-flash', reason: 'the model that can hang goes last');
      for (final code in [404, 429, 500, 503, 0]) {
        expect(GeminiPlateReader.shouldTryNextModel(code), isTrue, reason: '$code');
      }
      for (final code in [400, 401, 403]) {
        expect(GeminiPlateReader.shouldTryNextModel(code), isFalse, reason: '$code');
      }
    });

    test('prompt warns about look-alike series letters', () {
      expect(GeminiPlateReader.buildPrompt(), contains('থ (THA, CNG) vs খ (KHA)'));
    });

    test('prompt lists cities and series', () {
      final prompt = GeminiPlateReader.buildPrompt();
      expect(prompt, contains('ঢাকা = DHAKA METRO'));
      expect(prompt, contains('থ = THA'));
    });
  });

  group('PlateImageProcessor', () {
    /// White plate with two black text bands and a black frame
    LumImage twoLinePlate({bool withFrame = true}) {
      const w = 200, h = 100;
      final lum = LumImage.blank(w, h);
      void fill(int x0, int y0, int x1, int y1) {
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            // Dashed "characters" rather than solid bars
            if ((x ~/ 6) % 2 == 0) lum.data[y * w + x] = 0;
          }
        }
      }

      fill(20, 15, 180, 40); // line 1
      fill(30, 58, 170, 85); // line 2
      if (withFrame) {
        for (var x = 0; x < w; x++) {
          lum.data[x] = 0;
          lum.data[(h - 1) * w + x] = 0;
        }
      }
      return lum;
    }

    test('Otsu separates a bimodal image', () {
      final data = Uint8List.fromList([...List.filled(50, 20), ...List.filled(50, 230)]);
      final t = PlateImageProcessor.otsuThreshold(data);
      expect(t, inInclusiveRange(20, 229));
    });

    test('finds the gap between the two plate lines', () {
      final binary = PlateImageProcessor.removeBorderLines(twoLinePlate());
      final split = PlateImageProcessor.findLineSplit(binary);
      expect(split, isNotNull);
      expect(split!, inInclusiveRange(41, 57));
    });

    test('a single text line is not split', () {
      const w = 200, h = 60;
      final lum = LumImage.blank(w, h);
      for (var y = 15; y < 45; y++) {
        for (var x = 10; x < 190; x++) {
          if ((x ~/ 6) % 2 == 0) lum.data[y * w + x] = 0;
        }
      }
      expect(PlateImageProcessor.findLineSplit(lum), isNull);
    });

    test('frame lines are removed', () {
      final cleaned = PlateImageProcessor.removeBorderLines(twoLinePlate());
      expect(cleaned.data.sublist(0, 200).every((v) => v == 255), isTrue);
    });

    test('white plate text stays dark; inverted plates are detected', () {
      final plate = twoLinePlate(withFrame: false);
      expect(PlateImageProcessor.inkFraction(plate), lessThan(0.5));
      expect(PlateImageProcessor.inkFraction(PlateImageProcessor.invert(plate)), greaterThan(0.5));
    });

    test('padding and PNG encoding', () {
      final padded = PlateImageProcessor.pad(twoLinePlate(), 10);
      expect(padded.width, 220);
      expect(padded.height, 120);
      expect(padded.at(0, 0), 255);
      final png = img.encodePng(PlateImageProcessor.toImage(padded));
      final decoded = img.decodePng(png)!;
      expect(decoded.width, 220);
    });

    test('luminance round trip from an RGB image', () {
      final image = img.Image(width: 4, height: 2);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      image.setPixelRgb(1, 1, 0, 0, 0);
      final lum = PlateImageProcessor.toLuminance(image);
      expect(lum.at(0, 0), 255);
      expect(lum.at(1, 1), 0);
    });
  });

  test('expected series per ride type', () {
    expect(BdPlateConstants.expectedSeriesFor('CNG'), {'THA'});
    expect(BdPlateConstants.expectedSeriesFor('CNG')!.contains('KHA'), isFalse);
    expect(BdPlateConstants.expectedSeriesFor('Bike (Ride-share)'), containsAll(['HA', 'LA']));
    expect(BdPlateConstants.expectedSeriesFor('Rickshaw / Other'), isNull);
    // Every expected series is a real BRTA series
    final known = BdPlateConstants.seriesList.map((s) => s.english).toSet();
    for (final type in BdPlateConstants.rideTypes) {
      expect(known.containsAll(BdPlateConstants.expectedSeriesFor(type) ?? const {}), isTrue, reason: type);
    }
  });
}
