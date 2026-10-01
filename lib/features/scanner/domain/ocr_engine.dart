/// On-device OCR abstraction. Parsers only see text, so they stay testable;
/// the ML Kit implementation lives in `data/mlkit_ocr_engine.dart`.
library;

import 'ocr_layout.dart';

/// Recognised text of one image.
class OcrResult {
  const OcrResult({required this.text, this.lines = const [], this.dominantAngle = 0});

  /// Rows rebuilt from line boxes (see [layoutRows]); falls back to the
  /// engine's plain text when no geometry is available.
  final String text;
  final List<OcrLine> lines;

  /// Median rotation of recognised lines in degrees (0 = upright). Used to
  /// detect sideways/upside-down photos that need a rotation fix.
  final double dominantAngle;

  bool get isEmpty => text.trim().isEmpty;
}

/// Thrown when OCR cannot run; [message] is shown to the user as-is.
class OcrUnavailableException implements Exception {
  const OcrUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class OcrEngine {
  /// False on platforms without on-device OCR (everything except Android).
  bool get isSupported;

  /// Message shown when [isSupported] is false.
  String get unsupportedMessage;

  /// Recognises Latin text in the image at [path]. Throws
  /// [OcrUnavailableException] when OCR is not available.
  Future<OcrResult> recognize(String path);

  Future<void> close();
}

const ocrUnsupportedMessage = 'OCR hanya tersedia di Android';
