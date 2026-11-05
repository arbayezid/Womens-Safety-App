import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Grayscale image as one luminance byte per pixel
class LumImage {
  final int width;
  final int height;
  final Uint8List data;

  LumImage(this.width, this.height, this.data);

  LumImage.blank(this.width, this.height, {int fill = 255})
      : data = Uint8List(width * height)..fillRange(0, width * height, fill);

  int at(int x, int y) => data[y * width + x];
}

/// Pre-processed images for the plate OCR passes.
///
/// BRTA plates have two lines (city + series on top, class-serial number below). When the
/// splitter finds the gap between them, [top] and [bottom] hold each line separately so each
/// can be read with its own Tesseract settings.
class PlateVariantPaths {
  final String fullGray;
  final String fullBinary;
  final String? topGray;
  final String? topBinary;
  final String? bottomGray;
  final String? bottomBinary;
  final String? bottomBold;

  const PlateVariantPaths({
    required this.fullGray,
    required this.fullBinary,
    this.topGray,
    this.topBinary,
    this.bottomGray,
    this.bottomBinary,
    this.bottomBold,
  });

  bool get isSplit => topGray != null && bottomGray != null;

  List<String> get all => [
        fullGray,
        fullBinary,
        if (topGray != null) topGray!,
        if (topBinary != null) topBinary!,
        if (bottomGray != null) bottomGray!,
        if (bottomBinary != null) bottomBinary!,
        if (bottomBold != null) bottomBold!,
      ];
}

/// Image operations for plate OCR. File operations run on a background isolate;
/// the pixel helpers are pure and unit-tested.
class PlateImageProcessor {
  PlateImageProcessor._();

  /// Target height of the whole plate crop handed to Tesseract (two text lines)
  static const int plateTargetHeight = 260;

  /// Bakes the EXIF orientation into the pixels and caps the size, so the crop screen,
  /// ML Kit and the OCR passes all work in the same pixel coordinates.
  static Future<({String path, int width, int height})?> normalizePhoto(
    String srcPath,
    String outPath, {
    int maxSide = 2400,
  }) {
    return Isolate.run(() {
      var image = img.decodeImage(File(srcPath).readAsBytesSync());
      if (image == null) return null;
      image = img.bakeOrientation(image);
      final longest = math.max(image.width, image.height);
      if (longest > maxSide) {
        final scale = maxSide / longest;
        image = img.copyResize(
          image,
          width: (image.width * scale).round(),
          height: (image.height * scale).round(),
          interpolation: img.Interpolation.cubic,
        );
      }
      File(outPath).writeAsBytesSync(img.encodeJpg(image, quality: 94));
      return (path: outPath, width: image.width, height: image.height);
    });
  }

  /// Crops [rect] (left, top, right, bottom as fractions 0-1 of the image) with a small margin.
  static Future<String?> cropToFile(
    String srcPath,
    String outPath,
    List<double> rect, {
    double margin = 0.04,
  }) {
    return Isolate.run(() {
      final image = img.decodeImage(File(srcPath).readAsBytesSync());
      if (image == null) return null;
      final w = image.width, h = image.height;
      final rw = (rect[2] - rect[0]) * w, rh = (rect[3] - rect[1]) * h;
      final left = (rect[0] * w - rw * margin).floor().clamp(0, w - 1);
      final top = (rect[1] * h - rh * margin).floor().clamp(0, h - 1);
      final right = (rect[2] * w + rw * margin).ceil().clamp(left + 1, w);
      final bottom = (rect[3] * h + rh * margin).ceil().clamp(top + 1, h);
      if (right - left < 16 || bottom - top < 8) return null;
      final crop = img.copyCrop(image, x: left, y: top, width: right - left, height: bottom - top);
      File(outPath).writeAsBytesSync(img.encodeJpg(crop, quality: 95));
      return outPath;
    });
  }

  /// JPEG bytes sized for the cloud reader: at most [maxSide], and tiny plate crops scaled up
  /// to [minSide] so thin Bangla strokes (থ vs খ) survive the model's own resizing.
  static Future<Uint8List?> encodeForUpload(String srcPath, {int maxSide = 1600, int minSide = 900}) {
    return Isolate.run(() {
      var image = img.decodeImage(File(srcPath).readAsBytesSync());
      if (image == null) return null;
      image = img.bakeOrientation(image);
      final longest = math.max(image.width, image.height);
      if (longest > maxSide || longest < minSide) {
        final scale = (longest > maxSide ? maxSide : minSide) / longest;
        image = img.copyResize(
          image,
          width: (image.width * scale).round(),
          height: (image.height * scale).round(),
          interpolation: img.Interpolation.cubic,
        );
      }
      return img.encodeJpg(image, quality: 92);
    });
  }

  /// Builds the Tesseract input images from [srcPath], optionally cropped to [crop]
  /// ([left, top, right, bottom] in pixels; padded generously because ML Kit often boxes
  /// only part of a Bangla plate). [plateMode] says [srcPath] is already a tight plate crop.
  /// Files are written as `<outPrefix>_<name>.png`.
  static Future<PlateVariantPaths?> buildVariants(
    String srcPath,
    String outPrefix, {
    List<int>? crop,
    bool plateMode = false,
  }) {
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
        if (right - left < 20 || bottom - top < 10) return null;
        image = img.copyCrop(image, x: left, y: top, width: right - left, height: bottom - top);
      }

      // Plate crops: scale so the two text lines are ~100px tall each. Whole photos are kept
      // large (longest side 1600) so a sparse-text pass can still find the plate somewhere.
      final isPlate = plateMode || crop != null;
      final int width, height;
      if (isPlate) {
        final scale = plateTargetHeight / image.height;
        width = math.min((image.width * scale).round(), 1400);
        height = math.max(1, (image.height * (width / image.width)).round());
      } else {
        final scale = 1600 / math.max(image.width, image.height);
        width = (image.width * scale).round();
        height = (image.height * scale).round();
      }
      image = img.copyResize(image, width: width, height: height, interpolation: img.Interpolation.cubic);

      var gray = sharpen(stretchContrast(toLuminance(image)));
      var binary = binarize(gray);
      // Make the text dark on a light background whatever the plate colour
      if (inkFraction(binary) > 0.5) {
        gray = invert(gray);
        binary = invert(binary);
      }
      binary = removeBorderLines(binary);

      void write(LumImage lum, String name) {
        File('${outPrefix}_$name.png').writeAsBytesSync(img.encodePng(toImage(pad(lum, 14))));
      }

      write(gray, 'full_gray');
      write(binary, 'full_bin');

      final split = isPlate ? findLineSplit(binary) : null;
      if (split == null) {
        return PlateVariantPaths(
          fullGray: '${outPrefix}_full_gray.png',
          fullBinary: '${outPrefix}_full_bin.png',
        );
      }

      write(rows(gray, 0, split), 'top_gray');
      write(rows(binary, 0, split), 'top_bin');
      final bottomBinary = rows(binary, split, binary.height);
      write(rows(gray, split, gray.height), 'bottom_gray');
      write(bottomBinary, 'bottom_bin');
      write(thicken(bottomBinary), 'bottom_bold');

      return PlateVariantPaths(
        fullGray: '${outPrefix}_full_gray.png',
        fullBinary: '${outPrefix}_full_bin.png',
        topGray: '${outPrefix}_top_gray.png',
        topBinary: '${outPrefix}_top_bin.png',
        bottomGray: '${outPrefix}_bottom_gray.png',
        bottomBinary: '${outPrefix}_bottom_bin.png',
        bottomBold: '${outPrefix}_bottom_bold.png',
      );
    });
  }

  // ─── Pure pixel helpers ────────────────────────────────────────────────────

  static LumImage toLuminance(img.Image image) {
    final src = image.format == img.Format.uint8 ? image : image.convert(format: img.Format.uint8);
    final out = Uint8List(src.width * src.height);
    for (final p in src) {
      final l = src.numChannels >= 3 ? 0.299 * p.r + 0.587 * p.g + 0.114 * p.b : p.r;
      out[p.y * src.width + p.x] = l.round().clamp(0, 255);
    }
    return LumImage(src.width, src.height, out);
  }

  static img.Image toImage(LumImage lum) => img.Image.fromBytes(
        width: lum.width,
        height: lum.height,
        bytes: Uint8List.fromList(lum.data).buffer,
        numChannels: 1,
      );

  /// Linear stretch between the 1st and 99th luminance percentiles
  static LumImage stretchContrast(LumImage src) {
    final hist = List<int>.filled(256, 0);
    for (final v in src.data) {
      hist[v]++;
    }
    final n = src.data.length;
    var lo = 0, hi = 255, acc = 0;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= n * 0.01) {
        lo = i;
        break;
      }
    }
    acc = 0;
    for (var i = 255; i >= 0; i--) {
      acc += hist[i];
      if (acc >= n * 0.01) {
        hi = i;
        break;
      }
    }
    if (hi - lo < 10) return src;
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (((src.data[i] - lo) * 255) / (hi - lo)).round().clamp(0, 255);
    }
    return LumImage(src.width, src.height, out);
  }

  /// Unsharp mask with a 3x3 box blur
  static LumImage sharpen(LumImage src, {double amount = 0.8}) {
    final w = src.width, h = src.height;
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var sum = 0, count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            sum += src.data[yy * w + xx];
            count++;
          }
        }
        final v = src.data[y * w + x];
        out[y * w + x] = (v + amount * (v - sum / count)).round().clamp(0, 255);
      }
    }
    return LumImage(w, h, out);
  }

  /// Otsu's method: the threshold that best separates ink from background
  static int otsuThreshold(Uint8List data) {
    final hist = List<int>.filled(256, 0);
    for (final v in data) {
      hist[v]++;
    }
    final total = data.length;
    var sumAll = 0.0;
    for (var i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }
    var sumBg = 0.0, weightBg = 0, best = 0.0, threshold = 127;
    for (var t = 0; t < 256; t++) {
      weightBg += hist[t];
      if (weightBg == 0) continue;
      final weightFg = total - weightBg;
      if (weightFg == 0) break;
      sumBg += t * hist[t];
      final meanBg = sumBg / weightBg;
      final meanFg = (sumAll - sumBg) / weightFg;
      final between = weightBg * weightFg * (meanBg - meanFg) * (meanBg - meanFg);
      if (between > best) {
        best = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /// Pure black (0) / white (255) image; pixels at or below the Otsu threshold become ink
  static LumImage binarize(LumImage src) {
    final t = otsuThreshold(src.data);
    final out = Uint8List(src.data.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = src.data[i] <= t ? 0 : 255;
    }
    return LumImage(src.width, src.height, out);
  }

  static double inkFraction(LumImage binary) {
    var ink = 0;
    for (final v in binary.data) {
      if (v < 128) ink++;
    }
    return binary.data.isEmpty ? 0 : ink / binary.data.length;
  }

  static LumImage invert(LumImage src) {
    final out = Uint8List(src.data.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = 255 - src.data[i];
    }
    return LumImage(src.width, src.height, out);
  }

  /// Whites out rows/columns that are almost entirely ink: the plate frame and its shadow,
  /// which Tesseract otherwise reads as `|`, `1` or `-`.
  static LumImage removeBorderLines(LumImage src, {double fill = 0.8}) {
    final w = src.width, h = src.height;
    final out = Uint8List.fromList(src.data);
    for (var y = 0; y < h; y++) {
      var ink = 0;
      for (var x = 0; x < w; x++) {
        if (src.data[y * w + x] < 128) ink++;
      }
      if (ink > w * fill) out.fillRange(y * w, (y + 1) * w, 255);
    }
    for (var x = 0; x < w; x++) {
      var ink = 0;
      for (var y = 0; y < h; y++) {
        if (src.data[y * w + x] < 128) ink++;
      }
      if (ink > h * fill) {
        for (var y = 0; y < h; y++) {
          out[y * w + x] = 255;
        }
      }
    }
    return LumImage(w, h, out);
  }

  /// Finds the blank band between the two plate lines from the horizontal ink profile.
  /// Returns the row to split at, or null when the image doesn't look like two lines.
  static int? findLineSplit(LumImage binary) {
    final w = binary.width, h = binary.height;
    if (h < 20) return null;

    final profile = List<double>.filled(h, 0);
    for (var y = 0; y < h; y++) {
      var ink = 0;
      for (var x = 0; x < w; x++) {
        if (binary.data[y * w + x] < 128) ink++;
      }
      profile[y] = ink.toDouble();
    }
    // Smooth over ~2% of the height
    final r = math.max(1, h ~/ 50);
    final smooth = List<double>.filled(h, 0);
    for (var y = 0; y < h; y++) {
      var sum = 0.0, count = 0;
      for (var k = y - r; k <= y + r; k++) {
        if (k < 0 || k >= h) continue;
        sum += profile[k];
        count++;
      }
      smooth[y] = sum / count;
    }

    final peak = smooth.reduce(math.max);
    if (peak <= 0) return null;

    final from = (h * 0.25).floor(), to = (h * 0.75).ceil();
    var valleyRow = -1;
    var valley = double.infinity;
    for (var y = from; y < to; y++) {
      if (smooth[y] < valley) {
        valley = smooth[y];
        valleyRow = y;
      }
    }
    if (valleyRow < 0 || valley > peak * 0.2) return null;

    // Centre of the low band around the valley, not just its first row
    final limit = valley + peak * 0.05;
    var a = valleyRow, b = valleyRow;
    while (a > from && smooth[a - 1] <= limit) {
      a--;
    }
    while (b < to - 1 && smooth[b + 1] <= limit) {
      b++;
    }
    final split = (a + b) ~/ 2;

    // Both halves must actually contain text
    double inkIn(int y0, int y1) {
      var s = 0.0;
      for (var y = y0; y < y1; y++) {
        s += profile[y];
      }
      return s;
    }

    final totalInk = inkIn(0, h);
    if (inkIn(0, split) < totalInk * 0.15 || inkIn(split, h) < totalInk * 0.15) return null;
    return split;
  }

  /// Rows [y0, y1) of [src]
  static LumImage rows(LumImage src, int y0, int y1) {
    final h = y1 - y0;
    return LumImage(
      src.width,
      h,
      Uint8List.fromList(src.data.sublist(y0 * src.width, y1 * src.width)),
    );
  }

  /// White border around the text; Tesseract reads characters touching the edge poorly
  static LumImage pad(LumImage src, int p) {
    final out = LumImage.blank(src.width + 2 * p, src.height + 2 * p);
    for (var y = 0; y < src.height; y++) {
      out.data.setRange(
        (y + p) * out.width + p,
        (y + p) * out.width + p + src.width,
        src.data,
        y * src.width,
      );
    }
    return out;
  }

  /// 3x3 dilation of the ink: reconnects strokes broken by glare or a low-res photo
  static LumImage thicken(LumImage binary) {
    final w = binary.width, h = binary.height;
    final out = Uint8List.fromList(binary.data);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (binary.data[y * w + x] >= 128) continue;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            out[yy * w + xx] = 0;
          }
        }
      }
    }
    return LumImage(w, h, out);
  }
}
