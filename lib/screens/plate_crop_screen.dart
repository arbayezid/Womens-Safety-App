import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/app_colors.dart';

/// Lets the user box the number plate in a photo before OCR. A tight crop is the single
/// biggest accuracy gain: background signs and stickers no longer confuse the reader.
///
/// Pops with the region as [left, top, right, bottom] fractions (0-1) of the image,
/// `[0, 0, 1, 1]` for "use whole photo", or null when cancelled.
class PlateCropScreen extends StatefulWidget {
  final File image;
  final int imageWidth;
  final int imageHeight;
  final List<double>? initialRegion;

  const PlateCropScreen({
    super.key,
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    this.initialRegion,
  });

  static const List<double> wholePhoto = [0, 0, 1, 1];

  @override
  State<PlateCropScreen> createState() => _PlateCropScreenState();
}

class _PlateCropScreenState extends State<PlateCropScreen> {
  static const double _touchTolerance = 28;
  static const double _minSidePx = 40;

  late Rect _region; // fractions 0-1 of the image

  // Edges being dragged; all false + _moving = move the whole box
  bool _dragLeft = false, _dragTop = false, _dragRight = false, _dragBottom = false;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.initialRegion;
    final valid = r != null && r.length == 4 && r[2] - r[0] > 0.03 && r[3] - r[1] > 0.02;
    _region = valid
        ? Rect.fromLTRB(r[0], r[1], r[2], r[3])
        : const Rect.fromLTRB(0.12, 0.38, 0.88, 0.62);
  }

  /// Where the image is drawn inside the available [size] (BoxFit.contain)
  Rect _imageRectIn(Size size) {
    final scale = math.min(size.width / widget.imageWidth, size.height / widget.imageHeight);
    final w = widget.imageWidth * scale, h = widget.imageHeight * scale;
    return Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  Rect _toScreen(Rect imageRect) => Rect.fromLTRB(
        imageRect.left + _region.left * imageRect.width,
        imageRect.top + _region.top * imageRect.height,
        imageRect.left + _region.right * imageRect.width,
        imageRect.top + _region.bottom * imageRect.height,
      );

  void _onPanStart(DragStartDetails d, Rect imageRect) {
    final box = _toScreen(imageRect);
    final p = d.localPosition;
    final withinY = p.dy >= box.top - _touchTolerance && p.dy <= box.bottom + _touchTolerance;
    final withinX = p.dx >= box.left - _touchTolerance && p.dx <= box.right + _touchTolerance;
    _dragLeft = withinY && (p.dx - box.left).abs() < _touchTolerance;
    _dragRight = withinY && (p.dx - box.right).abs() < _touchTolerance;
    _dragTop = withinX && (p.dy - box.top).abs() < _touchTolerance;
    _dragBottom = withinX && (p.dy - box.bottom).abs() < _touchTolerance;
    // A tiny box: prefer the far edges so it can still grow
    if (_dragLeft && _dragRight) _dragLeft = p.dx < box.center.dx;
    if (_dragLeft && _dragRight) _dragRight = false;
    if (_dragTop && _dragBottom) _dragTop = p.dy < box.center.dy;
    if (_dragTop && _dragBottom) _dragBottom = false;
    _moving = !(_dragLeft || _dragRight || _dragTop || _dragBottom) && box.contains(p);
  }

  void _onPanUpdate(DragUpdateDetails d, Rect imageRect) {
    final dx = d.delta.dx / imageRect.width;
    final dy = d.delta.dy / imageRect.height;
    final minW = _minSidePx / imageRect.width;
    final minH = _minSidePx / imageRect.height;

    setState(() {
      var l = _region.left, t = _region.top, r = _region.right, b = _region.bottom;
      if (_moving) {
        final shiftX = dx.clamp(-l, 1 - r);
        final shiftY = dy.clamp(-t, 1 - b);
        l += shiftX;
        r += shiftX;
        t += shiftY;
        b += shiftY;
      } else {
        // max/min keep clamp's bounds ordered even if the box started smaller than the minimum
        if (_dragLeft) l = (l + dx).clamp(0.0, math.max(0.0, r - minW));
        if (_dragRight) r = (r + dx).clamp(math.min(l + minW, 1.0), 1.0);
        if (_dragTop) t = (t + dy).clamp(0.0, math.max(0.0, b - minH));
        if (_dragBottom) b = (b + dy).clamp(math.min(t + minH, 1.0), 1.0);
      }
      _region = Rect.fromLTRB(l, t, r, b);
    });
  }

  void _onPanEnd() {
    _dragLeft = _dragTop = _dragRight = _dragBottom = _moving = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          'Select the number plate',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, constraints.maxHeight);
                  final imageRect = _imageRectIn(size);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) => _onPanStart(d, imageRect),
                    onPanUpdate: (d) => _onPanUpdate(d, imageRect),
                    onPanEnd: (_) => _onPanEnd(),
                    onPanCancel: _onPanEnd,
                    child: Stack(
                      children: [
                        Positioned.fromRect(
                          rect: imageRect,
                          child: Image.file(widget.image, fit: BoxFit.fill),
                        ),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _CropOverlayPainter(box: _toScreen(imageRect)),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Drag the box or its edges so it fits tightly around the plate, including both lines.\n'
                'বক্সটি শুধু নম্বর প্লেটের উপর রাখুন (দুই লাইনসহ)।',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12, height: 1.4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(PlateCropScreen.wholePhoto),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text('Use whole photo', style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).pop(
                        [_region.left, _region.top, _region.right, _region.bottom],
                      ),
                      icon: const Icon(Icons.document_scanner_rounded, size: 18, color: Colors.white),
                      label: Text(
                        'Read plate',
                        style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect box;

  _CropOverlayPainter({required this.box});

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(box);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.55));

    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Guide between the plate's two lines
    final mid = box.center.dy;
    final guide = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var x = box.left + 4; x < box.right - 4; x += 10) {
      canvas.drawLine(Offset(x, mid), Offset(math.min(x + 5, box.right - 4), mid), guide);
    }

    final handle = Paint()
      ..color = AppColors.primaryLight
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final len = math.min(22.0, math.min(box.width, box.height) / 2.5);
    for (final corner in [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight]) {
      final sx = corner.dx == box.left ? 1.0 : -1.0;
      final sy = corner.dy == box.top ? 1.0 : -1.0;
      canvas.drawLine(corner, corner.translate(sx * len, 0), handle);
      canvas.drawLine(corner, corner.translate(0, sy * len), handle);
    }
    for (final edgeMid in [box.centerLeft, box.centerRight]) {
      canvas.drawLine(edgeMid.translate(0, -len / 2), edgeMid.translate(0, len / 2), handle);
    }
    for (final edgeMid in [box.topCenter, box.bottomCenter]) {
      canvas.drawLine(edgeMid.translate(-len / 2, 0), edgeMid.translate(len / 2, 0), handle);
    }
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) => old.box != box;
}
