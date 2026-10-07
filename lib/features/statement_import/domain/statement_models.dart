/// Bank statement (mutasi rekening) import: parsed rows and parse results.
/// Pure data; no Flutter or database imports so parsers stay unit-testable.
library;

/// Money direction of one mutation as seen from the imported account.
enum StatementDirection {
  /// Money in (kredit / CR / K).
  credit,

  /// Money out (debet / DB / D).
  debit,
}

/// One mutation read from a statement. [amount] is integer rupiah, always
/// positive; [direction] carries the sign.
class StatementRow {
  const StatementRow({
    required this.date,
    required this.description,
    required this.amount,
    required this.direction,
    this.balance,
    this.hasTime = false,
    this.pending = false,
    this.directionGuessed = false,
  });

  /// Local date (midnight) or date + time when the statement has one
  /// ([hasTime]).
  final DateTime date;
  final String description;
  final int amount;
  final StatementDirection direction;

  /// Running balance after this row when the statement shows one.
  final int? balance;
  final bool hasTime;

  /// BCA "PEND": not yet booked by the bank; [date] is a stand-in.
  final bool pending;

  /// Neither a column, a CR/DB marker, a sign nor a balance change told the
  /// direction; the parser assumed debit.
  final bool directionGuessed;

  /// Signed effect on the account balance.
  int get signedAmount => direction == StatementDirection.credit ? amount : -amount;
}

/// Result of parsing one statement file.
class StatementParse {
  const StatementParse({
    required this.rows,
    this.formatLabel,
    this.openingBalance,
    this.closingBalance,
    this.skippedLines = 0,
  });

  final List<StatementRow> rows;

  /// Detected bank layout (e.g. "BCA") or a generic label.
  final String? formatLabel;

  /// "Saldo awal" / opening balance printed on the statement.
  final int? openingBalance;

  /// "Saldo akhir" / closing balance, or the last row's running balance.
  final int? closingBalance;

  /// Data lines that looked like transactions but could not be read.
  final int skippedLines;

  DateTime? get firstDate => rows.isEmpty ? null : rows.map((r) => r.date).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime? get lastDate => rows.isEmpty ? null : rows.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Failure shown to the user as-is ([message] is Indonesian and never
/// contains amounts or descriptions, so it may also be logged).
class StatementImportException implements Exception {
  const StatementImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Thrown when the user cancels a running statement read (OCR of a scanned
/// PDF); the flow ends quietly without an error message.
class StatementImportCancelled implements Exception {
  const StatementImportCancelled();
}

abstract final class StatementErrors {
  static const unreadable = 'File tidak dapat dibaca. Pastikan file CSV atau PDF mutasi rekening tidak rusak.';
  static const tooLarge = 'File terlalu besar (maksimal 20 MB).';
  static const noRows = 'Tidak ada transaksi yang ditemukan di file ini.';
  static const unsupported =
      'Format file tidak didukung. Gunakan CSV atau PDF mutasi rekening (Excel: simpan dulu sebagai CSV).';
  static const unsupportedLayout =
      'Susunan kolom mutasi tidak dikenali. Atur kolom secara manual atau gunakan file CSV dari bank.';
  static const wrongPassword = 'Kata sandi PDF salah atau tidak diisi.';
  static const ocrUnavailable =
      'PDF ini berupa hasil scan (tanpa teks). Pembacaan teks dari gambar (OCR) hanya tersedia di Android. '
      'Unduh ulang mutasi sebagai PDF teks atau CSV dari internet/mobile banking.';
  static const ocrNoText =
      'Teks pada PDF hasil scan tidak terbaca. Pastikan hasil scan jelas dan tegak, atau unduh ulang mutasi '
      'sebagai PDF teks atau CSV dari internet/mobile banking.';
  static const ocrTooManyPages =
      'PDF hasil scan maksimal $maxScannedStatementPages halaman. Pisahkan file per periode yang lebih pendek.';
}

/// Page cap for reading a scanned PDF with OCR: each page is rendered and
/// recognised on the device, so longer files take too long.
const maxScannedStatementPages = 30;
