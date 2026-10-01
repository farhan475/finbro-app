import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Crop region in normalized coordinates (0..1) of the image **as displayed
/// after rotation**. Pure value type so drag logic and pixel mapping are
/// testable without decoding images.
class CropRect {
  const CropRect(this.left, this.top, this.right, this.bottom)
    : assert(left < right && top < bottom);

  static const full = CropRect(0, 0, 1, 1);

  /// Smallest side as a fraction of the image, so the box stays grabbable.
  static const minSide = 0.1;

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get isFull => left <= 0 && top <= 0 && right >= 1 && bottom >= 1;

  Rect toRect(Size size) =>
      Rect.fromLTRB(left * size.width, top * size.height, right * size.width, bottom * size.height);

  /// Moves the whole box by [delta] (normalized), clamped inside the image.
  CropRect translate(Offset delta) {
    final w = right - left;
    final h = bottom - top;
    final l = (left + delta.dx).clamp(0.0, 1.0 - w);
    final t = (top + delta.dy).clamp(0.0, 1.0 - h);
    return CropRect(l, t, l + w, t + h);
  }

  /// Moves one corner by [delta] (normalized). The opposite corner stays put;
  /// the box never inverts or shrinks below [minSide].
  CropRect dragCorner(CropCorner corner, Offset delta) {
    var l = left, t = top, r = right, b = bottom;
    if (corner.isLeft) {
      l = (l + delta.dx).clamp(0.0, r - minSide);
    } else {
      r = (r + delta.dx).clamp(l + minSide, 1.0);
    }
    if (corner.isTop) {
      t = (t + delta.dy).clamp(0.0, b - minSide);
    } else {
      b = (b + delta.dy).clamp(t + minSide, 1.0);
    }
    return CropRect(l, t, r, b);
  }

  /// The same region after rotating the image a quarter turn clockwise.
  CropRect rotatedClockwise() => CropRect(1 - bottom, left, 1 - top, right);

  /// Integer pixel rectangle inside an image of [width]×[height], at least
  /// 1×1 and never outside the image.
  ({int x, int y, int width, int height}) toPixels(int width, int height) {
    final x = (left * width).floor().clamp(0, width - 1);
    final y = (top * height).floor().clamp(0, height - 1);
    final r = (right * width).ceil().clamp(x + 1, width);
    final b = (bottom * height).ceil().clamp(y + 1, height);
    return (x: x, y: y, width: r - x, height: b - y);
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      (other.left - left).abs() < 1e-9 &&
      (other.top - top).abs() < 1e-9 &&
      (other.right - right).abs() < 1e-9 &&
      (other.bottom - bottom).abs() < 1e-9;

  @override
  int get hashCode => Object.hash(
    (left * 1e6).round(),
    (top * 1e6).round(),
    (right * 1e6).round(),
    (bottom * 1e6).round(),
  );

  @override
  String toString() => 'CropRect($left, $top, $right, $bottom)';
}

enum CropCorner {
  topLeft(isLeft: true, isTop: true),
  topRight(isLeft: false, isTop: true),
  bottomLeft(isLeft: true, isTop: false),
  bottomRight(isLeft: false, isTop: false);

  const CropCorner({required this.isLeft, required this.isTop});
  final bool isLeft;
  final bool isTop;
}

/// Size of an image after [quarterTurns] clockwise turns.
Size rotatedSize(Size size, int quarterTurns) =>
    quarterTurns.isOdd ? Size(size.height, size.width) : size;

/// Scale that fits [content] inside [box] (contain fit).
double containScale(Size content, Size box) =>
    math.min(box.width / content.width, box.height / content.height);
