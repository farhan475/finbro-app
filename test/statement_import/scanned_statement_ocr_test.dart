import 'dart:io';

import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/scanner/domain/ocr_engine.dart';
import 'package:finbro_app/features/statement_import/domain/import_service.dart';
import 'package:finbro_app/features/statement_import/domain/scanned_statement_ocr.dart';
import 'package:finbro_app/features/statement_import/domain/statement_line_parser.dart';
import 'package:finbro_app/features/statement_import/domain/statement_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rows as ML Kit + `layoutRows` return them for a scanned BCA statement:
/// cells of one visual row joined by two spaces, page furniture included.
const _bcaPage1 = '''
BCA
REKENING TAHAPAN
PERIODE : SEPTEMBER 2026
TANGGAL  KETERANGAN  MUTASI  SALDO
01/09  SALDO AWAL  5,000,000.00
02/09  TRANSFER KE KOPI KENANGAN  50,000.00 DB  4,950,000.00
TRANSFER KE MERCHANT QRIS
Bersambung ke Halaman berikut''';

const _bcaPage2 = '''
TANGGAL  KETERANGAN  MUTASI  SALDO
03/09  TRANSFER DARI PT MAJU  2,000,000.00 CR  6,950,000.00
05/09  TARIKAN ATM  500,000.00 DB  6,450,000.00
SALDO AKHIR  6,450,000.00''';

/// Mandiri layout read by OCR: three amount columns and timestamps. The
/// second row keeps ML Kit's real misread "08: 02" (seen on device).
const _mandiriPage = '''
mandiri
Periode : 01 September 2026 s/d 30 September 2026
TANGGAL TRANSAKSI  KETERANGAN  MUTASI DEBET  MUTASI KREDIT  SALDO
01/09/2026 10:15  BAYAR VIA ALFAMART JKT  150.000,00  0,00  3.850.000,00
05/09/2026 08: 02  TRANSFER DARI BUDI  0,00  750.000,00  4.600.000,00''';

/// Scanned PDF stand-in: each render writes a small file naming the page
/// and rotation so the fake engine knows what it was handed.
class _FakePages implements ScannedPdfPages {
  _FakePages(this.count);

  @override
  final int count;
  final renders = <(int, int)>[];
  final files = <File>[];

  @override
  Future<File> render(int index, Directory dir, {int quarterTurns = 0}) async {
    renders.add((index, quarterTurns));
    final file = File('${dir.path}/page-$index-$quarterTurns.png');
    await file.writeAsString('$index:$quarterTurns');
    files.add(file);
    return file;
  }
}

class _FakeOcr implements OcrEngine {
  _FakeOcr(this.pages, {this.supported = true, this.angles = const {}, this.failOnPage});

  /// Recognised text per `(page, quarterTurns)`; missing → blank page.
  final Map<(int, int), String> pages;
  final bool supported;
  final Map<(int, int), double> angles;
  final int? failOnPage;

  @override
  bool get isSupported => supported;

  @override
  String get unsupportedMessage => ocrUnsupportedMessage;

  @override
  Future<OcrResult> recognize(String path) async {
    final parts = (await File(path).readAsString()).split(':');
    final key = (int.parse(parts[0]), int.parse(parts[1]));
    if (key.$1 == failOnPage) throw const OcrUnavailableException('Teks gagal dibaca');
    return OcrResult(text: pages[key] ?? '', dominantAngle: angles[key] ?? 0);
  }

  @override
  Future<void> close() async {}
}

Matcher _throwsImport(String message) =>
    throwsA(isA<StatementImportException>().having((e) => e.message, 'message', message));

void main() {
  final now = DateTime(2026, 10, 2, 10);
  late Directory work;

  setUp(() async => work = await Directory.systemTemp.createTemp('finbro-ocr-test-'));
  tearDown(() async => work.delete(recursive: true));

  ScannedStatementOcr reader(OcrEngine engine, {void Function(int, int)? onProgress}) =>
      ScannedStatementOcr(engine: engine, workDir: () async => work, onProgress: onProgress);

  test('two scanned BCA pages become statement rows; page images are removed', () async {
    final pages = _FakePages(2);
    final progress = <(int, int)>[];
    final lines = await reader(
      _FakeOcr({(0, 0): _bcaPage1, (1, 0): _bcaPage2}),
      onProgress: (done, total) => progress.add((done, total)),
    ).read(pages);

    final parse = parseStatementLines(lines, now: now);
    expect(parse.rows, hasLength(3));
    expect(parse.rows[0].date, DateTime(2026, 9, 2));
    expect(parse.rows[0].description, 'TRANSFER KE KOPI KENANGAN TRANSFER KE MERCHANT QRIS');
    expect(parse.rows[0].amount, 50000);
    expect(parse.rows[0].direction, StatementDirection.debit);
    expect(parse.rows[1].amount, 2000000);
    expect(parse.rows[1].direction, StatementDirection.credit);
    expect(parse.rows[1].balance, 6950000);
    expect(parse.rows[2].amount, 500000);
    expect(parse.closingBalance, 6450000);

    expect(progress, [(0, 2), (1, 2), (2, 2)]);
    expect(pages.files.every((f) => !f.existsSync()), isTrue);
    expect(work.listSync(), isEmpty, reason: 'per-run temp directory deleted');
  });

  test('scanned Mandiri page reaches review candidates and commits as statement rows', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: 'acc-bank', name: 'Mandiri', type: AccountType.bank, createdAt: now, updatedAt: now,
    ));
    final service = StatementImportService(db: db, ledger: LedgerService(db));

    final lines = await reader(_FakeOcr({(0, 0): _mandiriPage})).read(_FakePages(1));
    await service.loadParsedLines(lines, accountId: 'acc-bank', now: now);

    final candidates = service.candidates!;
    expect(candidates, hasLength(2));
    expect(candidates[0].row.date, DateTime(2026, 9, 1, 10, 15));
    expect(candidates[0].row.amount, 150000);
    expect(candidates[0].row.direction, StatementDirection.debit);
    expect(candidates[1].row.amount, 750000);
    expect(candidates[1].row.direction, StatementDirection.credit);
    expect(candidates[1].row.date, DateTime(2026, 9, 5, 8, 2));
    expect(candidates[1].row.description, 'TRANSFER DARI BUDI');

    final result = await service.commit(now: now);
    expect(result.imported, 2);
    final rows = await db.select(db.transactions).get();
    expect(rows.map((r) => r.sourceType).toSet(), {SourceType.statementImport});
  });

  test('a sideways page is rendered again upright and that text is used', () async {
    final pages = _FakePages(1);
    final lines = await reader(_FakeOcr(
      {(0, 0): 'garbled', (0, 3): _bcaPage2},
      angles: {(0, 0): 90},
    )).read(pages);

    expect(pages.renders, [(0, 0), (0, 3)]);
    expect(lines, isNot(contains('garbled')));
    expect(parseStatementLines(lines, now: now).rows, hasLength(2));
  });

  test('no recognised text on any page → ocrNoText rejection', () async {
    final pages = _FakePages(2);
    await expectLater(reader(_FakeOcr({})).read(pages), _throwsImport(StatementErrors.ocrNoText));
    expect(pages.renders, hasLength(2));
    expect(work.listSync(), isEmpty);
  });

  test('engine failure → ocrNoText rejection, temp files cleaned', () async {
    final pages = _FakePages(2);
    await expectLater(
      reader(_FakeOcr({(0, 0): _bcaPage1}, failOnPage: 1)).read(pages),
      _throwsImport(StatementErrors.ocrNoText),
    );
    expect(work.listSync(), isEmpty);
  });

  test('without on-device OCR (non-Android) → ocrUnavailable, nothing rendered', () async {
    final pages = _FakePages(1);
    await expectLater(
      reader(_FakeOcr({(0, 0): _bcaPage1}, supported: false)).read(pages),
      _throwsImport(StatementErrors.ocrUnavailable),
    );
    expect(pages.renders, isEmpty);
  });

  test('page cap: 30 pages are read, 31 are rejected before rendering', () async {
    final ok = _FakePages(maxScannedStatementPages);
    await reader(_FakeOcr({(0, 0): _bcaPage1})).read(ok);
    expect(ok.renders, hasLength(maxScannedStatementPages));

    final tooMany = _FakePages(maxScannedStatementPages + 1);
    await expectLater(
      reader(_FakeOcr({(0, 0): _bcaPage1})).read(tooMany),
      _throwsImport(StatementErrors.ocrTooManyPages),
    );
    expect(tooMany.renders, isEmpty);
  });

  test('cancel stops before the next page and cleans up', () async {
    final pages = _FakePages(3);
    late ScannedStatementOcr ocr;
    ocr = reader(
      _FakeOcr({(0, 0): _bcaPage1, (1, 0): _bcaPage2}),
      onProgress: (done, _) {
        if (done == 1) ocr.cancel();
      },
    );
    await expectLater(ocr.read(pages), throwsA(isA<StatementImportCancelled>()));
    expect(pages.renders, [(0, 0)]);
    expect(work.listSync(), isEmpty);
  });
}
