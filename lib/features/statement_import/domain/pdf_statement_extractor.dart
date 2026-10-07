/// PDF statement text extraction with pdfrx.
///
/// The PDFium engine already runs its native calls on its own background
/// worker isolate; the page text is composed into parser-ready lines with
/// `Isolate.run` (same compute pattern as the zip backup) so large
/// statements never block the UI. A PDF without any text layer (scanned
/// pages only) is read with on-device OCR ([ScannedStatementOcr]).
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../../core/utilities/app_logger.dart';
import 'scanned_statement_ocr.dart';
import 'statement_models.dart';

/// Result of extracting the text layer of one PDF statement.
class PdfExtractResult {
  const PdfExtractResult({
    this.lines = const [],
    this.needsPassword = false,
    this.ocrPages = 0,
    this.textPages = 0,
    this.totalPages = 0,
  });

  /// Text lines of every page in reading order, blanks removed.
  final List<String> lines;

  /// The file is password protected and [PdfTextExtractor.extract] was not
  /// given a working password; retry with one.
  final bool needsPassword;

  /// Pages read with OCR because the file has no text layer at all
  /// (scanned statement); 0 for a regular text PDF.
  final int ocrPages;
  final int textPages;
  final int totalPages;
}

/// Reads statement text out of a PDF. Implementations must never prompt on
/// their own; an encrypted file without a working [password] yields
/// [PdfExtractResult.needsPassword] so the caller can ask the user.
abstract class PdfTextExtractor {
  Future<PdfExtractResult> extract(Uint8List bytes, {String? password});
}

/// Thrown by the password provider to abort the engine's retry loop; an
/// encrypted document is being opened without a usable password.
class _PasswordNeeded implements Exception {
  const _PasswordNeeded();
}

/// pdfrx-backed extractor for the statement import flow. A file without
/// any text layer goes through [ocr].
class PdfrxTextExtractor implements PdfTextExtractor {
  const PdfrxTextExtractor({required this.ocr});

  final ScannedStatementOcr ocr;

  @override
  Future<PdfExtractResult> extract(Uint8List bytes, {String? password}) async {
    await pdfrxFlutterInitialize();
    var passwordAsked = false;
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(
        bytes,
        sourceName: 'statement.pdf',
        firstAttemptByEmptyPassword: true,
        passwordProvider: () {
          // Ask at most once per call: the engine retries the provider on
          // every wrong password and would otherwise loop forever on a
          // constant wrong answer.
          if (password == null || password.isEmpty || passwordAsked) {
            throw const _PasswordNeeded();
          }
          passwordAsked = true;
          return password;
        },
      );
    } on _PasswordNeeded {
      return const PdfExtractResult(needsPassword: true);
    } on PdfPasswordException {
      return const PdfExtractResult(needsPassword: true);
    } catch (e, s) {
      AppLogger.error('Membuka PDF mutasi gagal', e, s);
      throw const StatementImportException(StatementErrors.unreadable);
    }
    try {
      final lines = <String>[];
      var textPages = 0;
      for (final page in doc.pages) {
        final text = await page.loadStructuredText();
        final pageLines = await _pageLines(text);
        if (pageLines.isEmpty) continue;
        textPages++;
        lines.addAll(pageLines);
      }
      if (textPages == 0) {
        final ocrLines = await ocr.read(_PdfrxScannedPages(doc));
        return PdfExtractResult(lines: ocrLines, ocrPages: doc.pages.length, totalPages: doc.pages.length);
      }
      return PdfExtractResult(lines: lines, textPages: textPages, totalPages: doc.pages.length);
    } on StatementImportException {
      rethrow;
    } on StatementImportCancelled {
      rethrow;
    } catch (e, s) {
      AppLogger.error('Membaca teks PDF mutasi gagal', e, s);
      throw const StatementImportException(StatementErrors.unreadable);
    } finally {
      await doc.dispose();
    }
  }

  /// One list entry per printed line. Runs in a separate isolate; only
  /// plain Dart data (strings, numbers) crosses the boundary.
  Future<List<String>> _pageLines(PdfPageText text) {
    final fragments = [
      for (final f in text.fragments) (text: f.text, top: f.bounds.top),
    ];
    return Isolate.run(() => _composeLines(text.fullText, fragments));
  }
}

/// Page scale for OCR rendering: 3× the 72 dpi PDF unit (216 dpi) keeps
/// small statement print around ML Kit's recommended character height.
const _ocrScale = 3.0;

/// Longest rendered side in pixels; bounds memory (~36 MB BGRA at most)
/// for scans whose page size is already in scanner pixels.
const _ocrMaxSide = 3000.0;

/// Renders pages of an open pdfrx document to PNG files for OCR.
class _PdfrxScannedPages implements ScannedPdfPages {
  _PdfrxScannedPages(this.doc);

  final PdfDocument doc;

  @override
  int get count => doc.pages.length;

  @override
  Future<File> render(int index, Directory dir, {int quarterTurns = 0}) async {
    final page = doc.pages[index];
    final turns = quarterTurns % 4;
    final scale = math.min(_ocrScale, _ocrMaxSide / math.max(page.width, page.height));
    final (w, h) = turns.isOdd ? (page.height, page.width) : (page.width, page.height);
    final rendered = await page.render(
      fullWidth: (w * scale).roundToDouble(),
      fullHeight: (h * scale).roundToDouble(),
      rotationOverride: PdfPageRotation.values[(page.rotation.index + turns) % 4],
      annotationRenderingMode: PdfAnnotationRenderingMode.none,
    );
    if (rendered == null) throw StateError('Halaman PDF ${index + 1} gagal dirender');
    final ui.Image image;
    try {
      image = await rendered.createImage();
    } finally {
      rendered.dispose();
    }
    final ByteData? png;
    try {
      png = await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
    if (png == null) throw StateError('Halaman PDF ${index + 1} gagal dikodekan');
    final file = File(p.join(dir.path, 'page-${index + 1}-$turns.png'));
    await file.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), flush: true);
    return file;
  }
}

/// Groups a page's text into lines: engine line breaks when present,
/// otherwise fragments are merged by vertical (baseline) distance.
List<String> _composeLines(String fullText, List<({String text, double top})> fragments) {
  final lines = [
    for (final l in fullText.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.length > 1 || fullText.trim().isEmpty) return lines;

  final out = <String>[];
  final buf = StringBuffer();
  double? top;
  for (final f in fragments) {
    if (top != null && (f.top - top).abs() > 2.0) {
      final line = buf.toString().trim();
      if (line.isNotEmpty) out.add(line);
      buf.clear();
    }
    top = f.top;
    buf
      ..write(f.text)
      ..write(' ');
  }
  final last = buf.toString().trim();
  if (last.isNotEmpty) out.add(last);
  return out;
}

/// Drives [PdfTextExtractor.extract] with the password dialog: asks up to
/// [maxAttempts] times when the file needs a password, gives up with
/// [StatementErrors.wrongPassword] afterwards (user cancel counts as an
/// attempt and ends the loop).
Future<PdfExtractResult> extractWithPassword(
  PdfTextExtractor extractor,
  Uint8List bytes, {
  required Future<String?> Function(int attempt) askPassword,
  int maxAttempts = 3,
}) async {
  var result = await extractor.extract(bytes);
  for (var attempt = 1; result.needsPassword && attempt <= maxAttempts; attempt++) {
    final password = await askPassword(attempt);
    if (password == null || password.isEmpty) {
      throw const StatementImportException(StatementErrors.wrongPassword);
    }
    result = await extractor.extract(bytes, password: password);
  }
  if (result.needsPassword) {
    throw const StatementImportException(StatementErrors.wrongPassword);
  }
  return result;
}
