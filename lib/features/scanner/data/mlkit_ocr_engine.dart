import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/ocr_engine.dart';
import '../domain/ocr_layout.dart';

/// On-device Latin text recognition (Google ML Kit). Works offline; the
/// model ships with the app. Only Android is supported (01-prd §7.9).
class MlKitOcrEngine implements OcrEngine {
  TextRecognizer? _recognizer;

  @override
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  @override
  String get unsupportedMessage => ocrUnsupportedMessage;

  @override
  Future<OcrResult> recognize(String path) async {
    if (!isSupported) throw const OcrUnavailableException(ocrUnsupportedMessage);
    final recognizer = _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
    final RecognizedText result;
    try {
      result = await recognizer.processImage(InputImage.fromFilePath(path));
    } on Exception catch (e) {
      throw OcrUnavailableException('Teks gagal dibaca: $e');
    }
    final lines = <OcrLine>[];
    final angles = <double>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final r = line.boundingBox;
        lines.add(OcrLine(line.text, left: r.left, top: r.top, right: r.right, bottom: r.bottom));
        final a = line.angle;
        if (a != null) angles.add(a);
      }
    }
    angles.sort();
    final laidOut = layoutRows(lines);
    return OcrResult(
      text: laidOut.isEmpty ? result.text : laidOut,
      lines: lines,
      dominantAngle: angles.isEmpty ? 0 : angles[angles.length ~/ 2],
    );
  }

  @override
  Future<void> close() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}

final ocrEngineProvider = Provider<OcrEngine>((ref) {
  final engine = MlKitOcrEngine();
  ref.onDispose(engine.close);
  return engine;
});
