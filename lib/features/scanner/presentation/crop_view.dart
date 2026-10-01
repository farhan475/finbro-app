import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../domain/crop_geometry.dart';

/// Result of the crop step: clockwise quarter turns + region in rotated
/// coordinates. Passed to `ImagePreprocessor.prepare`.
typedef CropChoice = ({int quarterTurns, CropRect crop});

/// Crop + rotate step before OCR (07-ocr §3). Drag corners to resize, drag
/// inside to move. Nothing is written until the user continues.
class CropView extends StatefulWidget {
  const CropView({super.key, required this.imagePath, required this.onDone});

  final String imagePath;
  final ValueChanged<CropChoice> onDone;

  @override
  State<CropView> createState() => _CropViewState();
}

class _CropViewState extends State<CropView> {
  ui.Image? _image;
  int _turns = 0;
  CropRect _crop = CropRect.full;
  CropCorner? _dragCorner;
  bool _moving = false;

  static const _handleHit = 32.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Decode a screen-sized preview (EXIF orientation applied by the codec).
    final bytes = await File(widget.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1200);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _rotate() => setState(() {
    _turns = (_turns + 1) % 4;
    _crop = _crop.rotatedClockwise();
  });

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(
            'Geser sudut untuk memotong area struk/screenshot. Area di luar kotak tidak dibaca.',
            style: context.text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: image == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : LayoutBuilder(builder: (context, c) => _editor(image, Size(c.maxWidth, c.maxHeight))),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              children: [
                IconButton.outlined(
                  tooltip: 'Putar 90°',
                  onPressed: image == null ? null : _rotate,
                  icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: 'Reset',
                  onPressed: image == null ? null : () => setState(() => _crop = CropRect.full),
                  icon: const Icon(Icons.crop_free),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: image == null ? null : () => widget.onDone((quarterTurns: _turns, crop: _crop)),
                    child: const Text('Baca teks'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _editor(ui.Image image, Size box) {
    final rotated = rotatedSize(Size(image.width.toDouble(), image.height.toDouble()), _turns);
    final scale = containScale(rotated, Size(box.width - 32, box.height - 16));
    final shown = Size(rotated.width * scale, rotated.height * scale);
    final cropRect = _crop.toRect(shown);

    CropCorner? cornerAt(Offset p) {
      for (final c in CropCorner.values) {
        final corner = Offset(c.isLeft ? cropRect.left : cropRect.right, c.isTop ? cropRect.top : cropRect.bottom);
        if ((corner - p).distance <= _handleHit) return c;
      }
      return null;
    }

    return Center(
      child: SizedBox.fromSize(
        size: shown,
        child: GestureDetector(
          onPanStart: (d) {
            _dragCorner = cornerAt(d.localPosition);
            _moving = _dragCorner == null && cropRect.contains(d.localPosition);
          },
          onPanUpdate: (d) {
            final delta = Offset(d.delta.dx / shown.width, d.delta.dy / shown.height);
            final corner = _dragCorner;
            if (corner != null) {
              setState(() => _crop = _crop.dragCorner(corner, delta));
            } else if (_moving) {
              setState(() => _crop = _crop.translate(delta));
            }
          },
          onPanEnd: (_) {
            _dragCorner = null;
            _moving = false;
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              RotatedBox(quarterTurns: _turns, child: RawImage(image: image, fit: BoxFit.fill)),
              CustomPaint(painter: _CropPainter(cropRect)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);
  final Rect rect;
  static const shade = Colors.black54;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(outside, Paint()..color = shade);
    // Light outline + thin dark halo so the frame is visible on any photo.
    canvas.drawRect(rect, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.black38);
    canvas.drawRect(rect, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white);
    final thirds = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), thirds);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), thirds);
    }
    final handle = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 18.0;
    for (final (cx, cy, sx, sy) in [
      (rect.left, rect.top, 1.0, 1.0),
      (rect.right, rect.top, -1.0, 1.0),
      (rect.left, rect.bottom, 1.0, -1.0),
      (rect.right, rect.bottom, -1.0, -1.0),
    ]) {
      canvas.drawLine(Offset(cx, cy), Offset(cx + len * sx, cy), handle);
      canvas.drawLine(Offset(cx, cy), Offset(cx, cy + len * sy), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}
