import 'dart:typed_data';

import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/statement_import/domain/import_service.dart';
import 'package:finbro_app/features/statement_import/domain/statement_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// BCA-style layout the parser preset detects: date, description, branch,
/// `amount DB/CR`, balance; footer with saldo lines.
const _bcaCsv = '''
"02/09","TRANSFER KE KOPI KENANGAN","KCU JAKARTA","50,000.00 DB","1,950,000.00"
"03/09","TRANSFER DARI PT MAJU","KCU JAKARTA","2,000,000.00 CR","3,950,000.00"
''';

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

  Uint8List csv(String text) => Uint8List.fromList(text.codeUnits);

  test('load parses rows, suggests categories and flags duplicates', () async {
    // An existing transaction matching the first statement row: same account,
    // amount, note merchant and within the ±2 day window.
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 50000, accountId: 'acc-bank',
      categoryId: 'sys-expense-other', transactionAt: DateTime(2026, 9, 3),
      note: 'Transfer ke Kopi Kenangan',
    ));

    await service.load(csv(_bcaCsv), accountId: 'acc-bank', now: now);

    final candidates = service.candidates!;
    expect(candidates, hasLength(2));
    expect(candidates[0].row.amount, 50000);
    expect(candidates[0].row.direction, StatementDirection.debit);
    expect(candidates[0].row.description, 'TRANSFER KE KOPI KENANGAN');
    expect(candidates[0].isDuplicate, isTrue, reason: 'amount+date+merchant match');
    expect(candidates[1].row.direction, StatementDirection.credit);
    expect(candidates[1].isDuplicate, isFalse);
    expect(service.suggestCategory(candidates[0].row), 'sys-expense-other');
    expect(service.suggestCategory(candidates[1].row), 'sys-income-other');
  });

  test('commit posts included rows as confirmed with chosen categories', () async {
    await service.load(csv(_bcaCsv), accountId: 'acc-bank', now: now);
    service.excluded.add(1); // skip the credit row
    service.categoryIds[0] = 'sys-expense-other';

    final result = await service.commit(now: now);
    expect(result.imported, 1);
    expect(result.skipped, 0);

    final rows = await db.select(db.transactions).get();
    expect(rows, hasLength(1));
    final t = rows.single;
    expect(t.type, TransactionType.expense);
    expect(t.amount, 50000);
    expect(t.status, TransactionStatus.confirmed);
    expect(t.sourceType, SourceType.statementImport);
    expect(t.note, 'TRANSFER KE KOPI KENANGAN');
    expect(t.transactionAt, DateTime(2026, 9, 2));
  });

  test('a row rejected by ledger validation is skipped, not fatal', () async {
    await service.load(csv(_bcaCsv), accountId: 'acc-bank', now: now);
    // Point the row at a category of the wrong type → validation throws.
    service.categoryIds[0] = 'sys-income-other';
    service.categoryIds[1] = 'sys-income-other';

    final result = await service.commit(now: now);
    expect(result.imported, 1, reason: 'only the mis-categorised row fails');
    expect(result.skipped, 1);
  });

  test('duplicate rows can be excluded and then commit imports the rest', () async {
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 50000, accountId: 'acc-bank',
      categoryId: 'sys-expense-other', transactionAt: DateTime(2026, 9, 3),
      note: 'Transfer ke Kopi Kenangan',
    ));
    await service.load(csv(_bcaCsv), accountId: 'acc-bank', now: now);
    service.excluded.add(0);

    final result = await service.commit(now: now);
    expect(result.imported, 1);
    final rows = await db.select(db.transactions).get();
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.amount), {50000, 2000000});
  });
}
