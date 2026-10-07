import 'dart:typed_data';

import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/statement_import/domain/import_service.dart';
import 'package:finbro_app/features/statement_import/domain/pdf_statement_extractor.dart';
import 'package:finbro_app/features/statement_import/domain/statement_models.dart';
import 'package:finbro_app/features/statement_import/domain/statement_line_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text lines as pdfrx would extract them from BCA-style e-statement PDFs:
/// date, description, `amount DB/CR`, balance; saldo lines; footers.
const _bcaPdfLines = [
  'PT. MAJU JAYA',
  'Halaman : 1',
  'Tanggal Keterangan Saldo',
  'Saldo Awal 5,000,000.00',
  '02/09 TRANSFER KE KOPI KENANGAN 50,000.00 DB 1,950,000.00',
  'TRANSFER KE MERCHANT QRIS',
  '03/09 TRANSFER DARI PT MAJU 2,000,000.00 CR 3,950,000.00',
  'Saldo Akhir 3,950,000.00',
];

/// Mandiri-style layout: timestamped dates, MUTASI DEBET/KREDIT/SALDO
/// columns (zero column printed), "Periode" header, "Halaman x dari y".
const _mandiriPdfLines = [
  'MANDIRI',
  'Periode : 01 September 2026 s/d 30 September 2026',
  'TANGGAL TRANSAKSI KETERANGAN CBG MUTASI DEBET MUTASI KREDIT SALDO',
  '01/09/2026 10:15 BAYAR VIA ALFAMART JKT 150.000,00 0,00 3.850.000,00',
  '05/09/2026 08:02 TRANSFER DARI BUDI 0,00 750.000,00 4.600.000,00',
  'Mutasi Debet 150.000,00',
  'Mutasi Kredit 750.000,00',
  'Halaman : 1 dari 2',
];

/// Extractor stub for [extractWithPassword] tests; native pdfrx is not
/// available in the Linux test environment.
class _FakeExtractor implements PdfTextExtractor {
  _FakeExtractor({this.encrypted = true, this.needsPasswordFor = const {}});

  /// Whether the simulated file needs a password at all.
  final bool encrypted;

  /// Passwords that still report `needsPassword` (wrong attempts).
  final Set<String> needsPasswordFor;
  var calls = 0;
  String? lastPassword;

  @override
  Future<PdfExtractResult> extract(Uint8List bytes, {String? password}) async {
    calls++;
    lastPassword = password;
    if (encrypted && (password == null || needsPasswordFor.contains(password))) {
      return const PdfExtractResult(needsPassword: true);
    }
    return PdfExtractResult(lines: _bcaPdfLines, textPages: 1, totalPages: 1);
  }
}

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late StatementImportService service;
  final now = DateTime(2026, 10, 2, 10);

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    service = StatementImportService(db: db, ledger: ledger);
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: 'acc-bank', name: 'BCA', type: AccountType.bank, createdAt: now, updatedAt: now,
    ));
  });

  tearDown(() async => db.close());

  group('PDF text pipeline (parseStatementLines)', () {
    test('BCA-style lines become rows with amount, direction and balance', () {
      final parse = parseStatementLines(_bcaPdfLines, now: now);

      expect(parse.rows, hasLength(2));
      final first = parse.rows[0];
      expect(first.date, DateTime(2026, 9, 2));
      expect(first.description, 'TRANSFER KE KOPI KENANGAN TRANSFER KE MERCHANT QRIS');
      expect(first.amount, 50000);
      expect(first.direction, StatementDirection.debit);
      expect(first.balance, 1950000);
      final second = parse.rows[1];
      expect(second.date, DateTime(2026, 9, 3));
      expect(second.amount, 2000000);
      expect(second.direction, StatementDirection.credit);
      expect(second.balance, 3950000);

      // Saldo lines and page furniture do not leak into rows.
      expect(parse.openingBalance, 5000000);
      expect(parse.closingBalance, 3950000);
      expect(parse.skippedLines, 0);
    });

    test('Mandiri-style lines: three amount columns and timestamps', () {
      final parse = parseStatementLines(_mandiriPdfLines, now: now);

      expect(parse.rows, hasLength(2));
      expect(parse.rows[0].date, DateTime(2026, 9, 1, 10, 15));
      expect(parse.rows[0].hasTime, isTrue);
      expect(parse.rows[0].amount, 150000);
      expect(parse.rows[0].direction, StatementDirection.debit);
      expect(parse.rows[0].balance, 3850000);
      expect(parse.rows[1].amount, 750000);
      expect(parse.rows[1].direction, StatementDirection.credit);
      expect(parse.rows[1].balance, 4600000);
      expect(parse.formatLabel, 'Mandiri');
      expect(parse.skippedLines, 0);
    });

    test('a data line without amounts is skipped, not fatal', () {
      final parse = parseStatementLines([
        ..._bcaPdfLines.take(4),
        '02/09 BIAYA ADMIN',
        ..._bcaPdfLines.skip(4),
      ], now: now);
      expect(parse.rows, hasLength(2));
      expect(parse.skippedLines, 1);
    });

    test('only summary lines → noRows error', () {
      expect(
        () => parseStatementLines(['Saldo Awal 5,000,000.00', 'Halaman : 1'], now: now),
        throwsA(isA<StatementImportException>().having((e) => e.message, 'message', StatementErrors.noRows)),
      );
    });
  });

  group('loadParsedLines (PDF service path)', () {
    test('builds candidates and flags duplicates like the CSV flow', () async {
      await ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: 50000, accountId: 'acc-bank',
        categoryId: 'sys-expense-other', transactionAt: DateTime(2026, 9, 3),
        note: 'Transfer ke Kopi Kenangan',
      ));

      await service.loadParsedLines(_bcaPdfLines, accountId: 'acc-bank', now: now);

      expect(service.analysis, isNull, reason: 'PDF mode has no CSV column analysis');
      final candidates = service.candidates!;
      expect(candidates, hasLength(2));
      expect(candidates[0].row.amount, 50000);
      expect(candidates[0].isDuplicate, isTrue, reason: 'amount+date+merchant match');
      expect(candidates[1].isDuplicate, isFalse);
      expect(service.skippedLines, 0);
      expect(service.suggestCategory(candidates[0].row), 'sys-expense-other');
      expect(service.suggestCategory(candidates[1].row), 'sys-income-other');
    });

    test('commit posts accepted rows to the ledger', () async {
      await service.loadParsedLines(_bcaPdfLines, accountId: 'acc-bank', now: now);
      service.categoryIds[0] = 'sys-expense-other';

      final result = await service.commit(now: now);
      expect(result.imported, 2);
      expect(result.skipped, 0);

      final rows = await db.select(db.transactions).get();
      expect(rows, hasLength(2));
      final debit = rows.singleWhere((r) => r.amount == 50000);
      expect(debit.type, TransactionType.expense);
      expect(debit.status, TransactionStatus.confirmed);
      expect(debit.sourceType, SourceType.statementImport);
      expect(debit.note, 'TRANSFER KE KOPI KENANGAN TRANSFER KE MERCHANT QRIS');
      expect(debit.transactionAt, DateTime(2026, 9, 2));
      expect(rows.singleWhere((r) => r.amount == 2000000).type, TransactionType.income);
    });
  });

  group('extractWithPassword', () {
    test('plain PDF needs no password and returns the lines', () async {
      final extractor = _FakeExtractor(encrypted: false);
      final result = await extractWithPassword(
        extractor,
        Uint8List(0),
        askPassword: (_) => throw StateError('must not ask'),
      );
      expect(result.lines, _bcaPdfLines);
      expect(result.needsPassword, isFalse);
      expect(extractor.calls, 1);
    });

    test('wrong password then correct password succeeds', () async {
      final extractor = _FakeExtractor(needsPasswordFor: {'salah'});
      final asked = <int>[];
      final result = await extractWithPassword(
        extractor,
        Uint8List(0),
        askPassword: (attempt) async {
          asked.add(attempt);
          return attempt == 1 ? 'salah' : 'benar';
        },
      );
      expect(result.lines, _bcaPdfLines);
      expect(extractor.lastPassword, 'benar');
      expect(extractor.calls, 3, reason: 'initial attempt plus two password attempts');
      expect(asked, [1, 2]);
    });

    test('user cancel throws wrongPassword', () async {
      final extractor = _FakeExtractor();
      await expectLater(
        extractWithPassword(extractor, Uint8List(0), askPassword: (_) async => null),
        throwsA(isA<StatementImportException>().having((e) => e.message, 'message', StatementErrors.wrongPassword)),
      );
    });

    test('three wrong attempts exhaust the retry loop', () async {
      final extractor = _FakeExtractor(needsPasswordFor: {'a', 'b', 'c'});
      await expectLater(
        extractWithPassword(
          extractor,
          Uint8List(0),
          askPassword: (attempt) async => switch (attempt) { 1 => 'a', 2 => 'b', 3 => 'c', _ => 'd' },
        ),
        throwsA(isA<StatementImportException>().having((e) => e.message, 'message', StatementErrors.wrongPassword)),
      );
      expect(extractor.calls, 4, reason: 'initial attempt plus three password attempts');
    });
  });
}
