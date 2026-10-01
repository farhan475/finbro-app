import 'receipt_parser.dart';
import 'scan_models.dart';
import 'screenshot_parser.dart';

/// Parses OCR text with the parser matching the chosen [source].
ScanParse parseScanText(ScanSource source, String text, {required DateTime now}) =>
    switch (source) {
      ScanSource.receipt => const ReceiptParser().parse(text, now: now),
      ScanSource.screenshot => const ScreenshotParser().parse(text, now: now),
    };
