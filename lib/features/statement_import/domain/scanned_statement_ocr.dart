/// OCR for scanned (image-only) PDF statements: pages are rendered one at a
/// time to a temporary PNG, read with the on-device [OcrEngine] and deleted
/// again; the recognised rows become statement lines for
/// `parseStatementLines`, exactly like a PDF text layer.
library;

import 'dart:io';

import '../../../core/utilities/app_logger.dart';
import '../../scanner/data/image_preprocessor.dart';
import '../../scanner/domain/ocr_engine.dart';
import 'statement_models.dart';

/// Pages of a scanned PDF, rendered on demand so only one page image is in
/// memory (and on disk) at a time.
abstract interface class ScannedPdfPages {
  int get count;

  /// Renders page [index] (0-based) as a PNG file inside [dir], turned
  /// clockwise by [quarterTurns]. The caller deletes the file.
  Future<File> render(int index, Directory dir, {int quarterTurns = 0});
}

/// Reads the text of a scanned PDF statement page by page. One instance
/// serves one import: [cancel] stops it before the next page.
class ScannedStatementOcr {
  ScannedStatementOcr({
    required this.engine,
    required this.workDir,
    this.onProgress,
    this.maxPages = maxScannedStatementPages,
  });

  final OcrEngine engine;

  /// Parent of the per-run temporary directory for page images.
  final Future<Directory> Function() workDir;

  /// Called with `(0, total)` before the first page and after every page.
  final void Function(int done, int total)? onProgress;
  final int maxPages;

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Stops the run before the next page; [read] then throws
  /// [StatementImportCancelled].
  void cancel() => _cancelled = true;

  /// Statement lines of every page in reading order. Throws
  /// [StatementImportException] when OCR is not available on this device,
  /// the file has more than [maxPages] pages, or no text was recognised.
  Future<List<String>> read(ScannedPdfPages pages) async {
    if (!engine.isSupported) throw const StatementImportException(StatementErrors.ocrUnavailable);
    final total = pages.count;
    if (total > maxPages) throw const StatementImportException(StatementErrors.ocrTooManyPages);

    final dir = await (await workDir()).createTemp('finbro-statement-ocr-');
    final lines = <String>[];
    try {
      onProgress?.call(0, total);
      for (var i = 0; i < total; i++) {
        _throwIfCancelled();
        lines.addAll(await _readPage(pages, i, dir));
        onProgress?.call(i + 1, total);
      }
      _throwIfCancelled();
    } on OcrUnavailableException catch (e) {
      AppLogger.error('OCR PDF mutasi gagal', e);
      throw const StatementImportException(StatementErrors.ocrNoText);
    } finally {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Best effort: the OS clears the cache directory eventually.
      }
    }
    if (lines.isEmpty) throw const StatementImportException(StatementErrors.ocrNoText);
    return lines;
  }

  /// One page's rows; a sideways/upside-down scan is rendered again turned
  /// upright (same rule as the receipt scanner) and read once more.
  Future<List<String>> _readPage(ScannedPdfPages pages, int index, Directory dir) async {
    var result = await _recognize(pages, index, dir, 0);
    final turns = ImagePreprocessor.quarterTurnsFor(result.dominantAngle);
    if (turns != 0) {
      _throwIfCancelled();
      result = await _recognize(pages, index, dir, turns);
    }
    return [
      for (final line in result.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  Future<OcrResult> _recognize(ScannedPdfPages pages, int index, Directory dir, int quarterTurns) async {
    final image = await pages.render(index, dir, quarterTurns: quarterTurns);
    try {
      return await engine.recognize(image.path);
    } finally {
      try {
        await image.delete();
      } on FileSystemException {
        // Removed with the run directory.
      }
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const StatementImportCancelled();
  }
}
