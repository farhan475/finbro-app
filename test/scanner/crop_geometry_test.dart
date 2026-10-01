import 'package:finbro_app/features/scanner/domain/crop_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dragging a corner never inverts the box or leaves the image', () {
    const c = CropRect(0.2, 0.2, 0.8, 0.8);
    final shrunk = c.dragCorner(CropCorner.topLeft, const Offset(0.9, 0.9));
    expect(shrunk, const CropRect(0.7, 0.7, 0.8, 0.8));
    final grown = c.dragCorner(CropCorner.bottomRight, const Offset(5, 5));
    expect(grown, const CropRect(0.2, 0.2, 1, 1));
  });

  test('moving keeps the size and clamps at the edges', () {
    const c = CropRect(0.1, 0.1, 0.5, 0.4);
    expect(c.translate(const Offset(2, -2)), const CropRect(0.6, 0, 1, 0.3));
  });

  test('four clockwise rotations return the same region', () {
    const c = CropRect(0.1, 0.2, 0.5, 0.9);
    var r = c;
    for (var i = 0; i < 4; i++) {
      r = r.rotatedClockwise();
    }
    expect(r, c);
    // Top-left region of a portrait image ends up top-right after one turn.
    expect(const CropRect(0, 0, 0.5, 0.5).rotatedClockwise(), const CropRect(0.5, 0, 1, 0.5));
  });

  test('pixel mapping stays inside the image and is at least 1px', () {
    expect(CropRect.full.toPixels(1000, 2000), (x: 0, y: 0, width: 1000, height: 2000));
    final p = const CropRect(0.25, 0.5, 0.75, 1).toPixels(101, 99);
    expect(p.x + p.width <= 101 && p.y + p.height <= 99, isTrue);
    expect(const CropRect(0.999, 0.999, 1, 1).toPixels(10, 10).width, 1);
  });
}
