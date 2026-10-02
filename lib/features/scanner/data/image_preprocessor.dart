import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/utilities/ids.dart';
import '../domain/crop_geometry.dart';

/// Image preparation before OCR using only `dart:ui` (no extra packages).
/// Output files are temporary scan copies; nothing here touches the DB.
abstract final class ImagePreprocessor {
  /// Longest side fed to OCR. Larger photos are slower and do not read
  /// better; ML Kit recommends ~16px character height, well within this.
  static const maxSide = 2400;

  /// Longest side of a source image: the picker downsizes photos to it and
  /// cropping never decodes larger, bounding memory on high-megapixel cameras
  /// while leaving a small crop enough detail.
  static const maxSourceSide = 4000.0;

  /// Directory for temporary scan copies (cleared by [discard]).
  static Future<Directory> tempDir() async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'scan'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Returns [path] unchanged when no rotation/crop is requested and the
  /// image is already small enough; otherwise writes a rotated (clockwise
  /// [quarterTurns]), cropped ([crop], in rotated coordinates) and
  /// downscaled PNG copy and returns its path. Decoding applies the camera's
  /// EXIF orientation.
  static Future<String> prepare(String path, {int quarterTurns = 0, CropRect crop = CropRect.full}) async {
    final turns = quarterTurns % 4;
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    if (turns == 0 && crop.isFull && math.max(w, h) <= maxSide) {
      descriptor.dispose();
      buffer.dispose();
      return path;
    }
    // Decode only as large as the kept region needs to come out at about
    // [maxSide] (a full-frame image straight to the downscaled size), and
    // never above [maxSourceSide] so a huge photo cannot exhaust memory.
    final (srcW, srcH) = turns.isOdd ? (h, w) : (w, h);
    final cropLongest = math.max((crop.right - crop.left) * srcW, (crop.bottom - crop.top) * srcH);
    final decodeScale = [1.0, maxSide / cropLongest, maxSourceSide / math.max(w, h)].reduce(math.min);
    final codec = await descriptor.instantiateCodec(
      targetWidth: (w * decodeScale).round(),
      targetHeight: (h * decodeScale).round(),
    );
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();

    final iw = image.width;
    final ih = image.height;
    final rotW = turns.isOdd ? ih : iw;
    final rotH = turns.isOdd ? iw : ih;
    final region = crop.toPixels(rotW, rotH);
    final outScale = math.min(1.0, maxSide / math.max(region.width, region.height));
    final outW = math.max(1, (region.width * outScale).round());
    final outH = math.max(1, (region.height * outScale).round());

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..scale(outScale)
      ..translate(-region.x.toDouble(), -region.y.toDouble())
      ..translate(rotW / 2, rotH / 2)
      ..rotate(turns * math.pi / 2)
      ..translate(-iw / 2, -ih / 2)
      ..drawImage(image, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.medium);
    final picture = recorder.endRecording();
    final out = await picture.toImage(outW, outH);
    picture.dispose();
    image.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (data == null) return path;
    final target = File(p.join((await tempDir()).path, '${newId()}.png'));
    await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return target.path;
  }

  /// Quarter turns that bring text at [angle] degrees upright, or 0 when the
  /// text is already roughly upright.
  static int quarterTurnsFor(double angle) {
    final a = ((angle % 360) + 360) % 360;
    if (a < 45 || a >= 315) return 0;
    if (a < 135) return 3;
    if (a < 225) return 2;
    return 1;
  }

  /// Deletes temporary scan files: our own rotated/downscaled copies, and on
  /// Android the image_picker cache copies. Elsewhere (desktop) the picker
  /// returns the user's original file, which must never be deleted.
  static Future<void> discard(Iterable<String> paths) async {
    final root = Platform.isAndroid ? (await getTemporaryDirectory()).path : (await tempDir()).path;
    for (final path in paths.toSet()) {
      if (!p.isWithin(root, path)) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // Best effort: the OS clears the cache directory eventually.
      }
    }
  }
}
