import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/seed.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../scanner/domain/merchant_text.dart';
import 'csv_statement_parser.dart';
import 'statement_line_parser.dart';
import 'statement_models.dart';

/// One parsed statement row shown for review, plus its duplicate check.
class ImportCandidate {
  ImportCandidate({required this.row, this.duplicateOf});

  final StatementRow row;

  /// Existing transaction this row would duplicate, if any.
  LedgerTransaction? duplicateOf;

  bool get isDuplicate => duplicateOf != null;
}

/// Result of a completed import.
class ImportResult {
  const ImportResult({required this.imported, required this.skipped});
  final int imported;
  final int skipped;
}

/// Duplicate thresholds shared with the review UI: an existing transaction
/// inside ±[days] of the statement row scores on amount, day distance and
/// note similarity; [minScore] or more marks the row as a duplicate.
abstract final class DuplicateWindow {
  static const days = 2;
  static const minScore = 6;
}

/// Service for the bank statement import flow: analyze a CSV, review parsed
/// rows with duplicate detection, then post the accepted rows to the ledger.
///
/// Rows are posted as **confirmed** transactions — the bank statement is the
/// source of truth. Category is a suggestion (system "other" categories) that
/// the user may change per row before confirming the import; the description
/// becomes the note.
class StatementImportService {
  StatementImportService({required this.db, required this.ledger});

  final AppDatabase db;
  final LedgerService ledger;

  /// Account the statement belongs to, set by [load].
  String? accountId;

  /// Analyzed file state for the review screen.
  CsvAnalysis? analysis;

  /// Parsed rows of the current analysis with their duplicate matches.
  List<ImportCandidate>? candidates;

  /// Data lines the parser could not read (from the last [load]/[remap]).
  int get skippedLines => _skipped;
  int _skipped = 0;

  /// Category suggestion per parsed row index, editable by the user.
  Map<int, String?> categoryIds = {};

  /// Row indexes the user excluded from the import.
  Set<int> excluded = {};

  /// Parses [bytes] (CSV) into [accountId] and prepares review candidates.
  /// Throws [StatementImportException] with a user-facing message.
  Future<void> load(Uint8List bytes, {required String accountId, required DateTime now}) async {
    final a = analyzeCsv(bytes, now: now);
    final parse = parseCsvStatement(a, a.mapping, now: now);
    this.accountId = accountId;
    analysis = a;
    categoryIds = {};
    excluded = {};
    candidates = [for (final r in parse.rows) ImportCandidate(row: r)];
    _skipped = parse.skippedLines;
    await _refreshDuplicates();
  }

  /// Prepares review candidates from statement lines already extracted as
  /// text (PDF import; [parseStatementLines] also drives the OCR path).
  /// No CSV analysis exists, so the review screen hides the column mapping.
  Future<void> loadParsedLines(
    List<String> lines, {
    required String accountId,
    required DateTime now,
    String? formatLabel = 'PDF',
  }) async {
    final parse = parseStatementLines(lines, now: now, formatLabel: formatLabel);
    this.accountId = accountId;
    analysis = null;
    categoryIds = {};
    excluded = {};
    candidates = [for (final r in parse.rows) ImportCandidate(row: r)];
    _skipped = parse.skippedLines;
    await _refreshDuplicates();
  }

  /// Re-parses rows after the user changed the column mapping.
  Future<void> remap(ColumnMapping mapping, {required DateTime now}) async {
    final a = analysis;
    if (a == null) return;
    final parse = parseCsvStatement(a, mapping, now: now);
    candidates = [for (final r in parse.rows) ImportCandidate(row: r)];
    _skipped = parse.skippedLines;
    categoryIds.removeWhere((k, _) => k >= parse.rows.length);
    excluded.removeWhere((i) => i >= parse.rows.length);
    await _refreshDuplicates();
  }

  /// Category suggestion for [row]: income rows → "Penghasilan lain",
  /// expenses → "Pengeluaran lain". Statement descriptions never map cleanly
  /// to a budget category, so the user picks the real one during review.
  String? suggestCategory(StatementRow row) =>
      row.direction == StatementDirection.credit ? SystemCategories.otherIncome : SystemCategories.otherExpense;

  /// Marks duplicates for every row with one bounded query: exact-amount
  /// transactions on the same account inside the statement's date range
  /// (widened by [DuplicateWindow.days]), then per-row scoring.
  Future<void> _refreshDuplicates() async {
    final candidates = this.candidates;
    final account = accountId;
    if (candidates == null || candidates.isEmpty || account == null) return;
    var min = candidates.first.row.date, max = min;
    for (final c in candidates) {
      final d = c.row.date;
      if (d.isBefore(min)) min = d;
      if (d.isAfter(max)) max = d;
    }
    final from = DateTime(min.year, min.month, min.day - DuplicateWindow.days);
    final to = DateTime(max.year, max.month, max.day + DuplicateWindow.days + 1);
    final amounts = {for (final c in candidates) c.row.amount};
    final near = await (db.select(db.transactions)
          ..where(
            (t) =>
                t.amount.isIn(amounts) &
                t.accountId.equals(account) &
                t.status.equalsValue(TransactionStatus.voided).not() &
                t.type.equalsValue(TransactionType.transfer).not() &
                t.transactionAt.isBiggerOrEqualValue(sqlDateTime(from)) &
                t.transactionAt.isSmallerThanValue(sqlDateTime(to)),
          ))
        .get();
    for (final c in candidates) {
      c.duplicateOf = _matchDuplicate(c.row, near);
    }
  }

  LedgerTransaction? _matchDuplicate(StatementRow row, List<LedgerTransaction> near) {
    LedgerTransaction? best;
    var bestScore = 0;
    for (final t in near) {
      var score = 0;
      if (t.amount == row.amount) score += 4;
      final days = row.date.difference(t.transactionAt).inDays.abs();
      if (days <= DuplicateWindow.days) score += days == 0 ? 3 : 2;
      if (merchantsSimilar(row.description, t.note)) score += 2;
      if (row.hasTime &&
          row.date.year == t.transactionAt.year &&
          row.date.month == t.transactionAt.month &&
          row.date.day == t.transactionAt.day &&
          row.date.hour == t.transactionAt.hour &&
          row.date.minute == t.transactionAt.minute) {
        // Statements with a timestamp: the same minute is a strong signal.
        score += 3;
      }
      if (score >= DuplicateWindow.minScore && score > bestScore) {
        best = t;
        bestScore = score;
      }
    }
    return best;
  }

  /// Posts all included candidates as confirmed ledger transactions, inside
  /// one SQLite transaction; returns how many were created and skipped.
  Future<ImportResult> commit({required DateTime now}) async {
    final candidates = this.candidates;
    final account = accountId;
    if (candidates == null || account == null) throw StateError('load() must run first');

    final included = [
      for (var i = 0; i < candidates.length; i++)
        if (!excluded.contains(i)) (index: i, candidate: candidates[i]),
    ];
    var imported = 0;
    var skipped = 0;
    await db.transaction(() async {
      for (final (index: i, candidate: item) in included) {
        final row = item.row;
        try {
          final type =
              row.direction == StatementDirection.credit ? TransactionType.income : TransactionType.expense;
          await ledger.create(
            TransactionDraft(
              type: type,
              amount: row.amount,
              accountId: account,
              categoryId: categoryIds[i] ?? suggestCategory(row),
              transactionAt: row.date,
              note: row.description,
              sourceType: SourceType.statementImport,
            ),
          );
          imported++;
        } catch (e, s) {
          skipped++;
          // Row-level failures (archived account, category mismatch) must not
          // abort the batch; the user sees the counts afterwards.
          AppLogger.error('Impor mutasi: baris $i ditolak', e, s);
        }
      }
    });
    return ImportResult(imported: imported, skipped: skipped);
  }
}

final statementImportServiceProvider = Provider<StatementImportService>(
  (ref) => StatementImportService(
    db: ref.watch(databaseProvider),
    ledger: ref.watch(ledgerServiceProvider),
  ),
);
