import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/accounts/data/account_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Account-level multi-currency: currency persists through the repository,
/// kurs edits land in exchange_rates, and cross-currency transfers are
/// rejected by LedgerService (owner rule: no automatic conversion).
void main() {
  late AppDatabase db;
  late AccountRepository repo;
  late LedgerService ledger;
  final now = DateTime(2026, 9, 15, 12);

  setUp(() async {
    db = AppDatabase.memory();
    repo = AccountRepository(db);
    ledger = LedgerService(db);
  });
  tearDown(() => db.close());

  test('create stores the chosen currency; default is IDR', () async {
    final idr = await repo.create(name: 'BCA', type: AccountType.bank, openingBalance: 100000);
    final usd = await repo.create(
      name: 'Wise',
      type: AccountType.bank,
      openingBalance: 10000, // $100.00
      currency: Currency.usd,
    );
    expect((await getAccount(db, idr)).currency, 'IDR');
    expect((await getAccount(db, usd)).currency, 'USD');
  });

  test('update can change the currency of a fresh account', () async {
    final id = await repo.create(name: 'Wise', type: AccountType.bank, openingBalance: 0);
    await repo.update(id, name: 'Wise', type: AccountType.bank, openingBalance: 0, currency: Currency.sgd);
    expect((await getAccount(db, id)).currency, 'SGD');
  });

  test('non-IDR form flow upserts the kurs shown to the user', () async {
    // Simulates AccountFormScreen saving a USD account with kurs 16250.
    final id = await repo.create(
      name: 'Wise',
      type: AccountType.bank,
      openingBalance: 10000,
      currency: Currency.usd,
    );
    await db.into(db.exchangeRates).insertOnConflictUpdate(
      ExchangeRatesCompanion.insert(code: 'USD', rateToIdr: 16250, updatedAt: Value(now)),
    );
    final rate = await (db.select(db.exchangeRates)..where((r) => r.code.equals('USD')))
        .getSingle();
    expect(rate.rateToIdr, 16250);
    expect((await getAccount(db, id)).currency, 'USD');
  });

  test('transfer between different currencies is rejected with guidance', () async {
    final idr = await repo.create(name: 'BCA', type: AccountType.bank, openingBalance: 1000000);
    final usd = await repo.create(
      name: 'Wise',
      type: AccountType.bank,
      openingBalance: 0,
      currency: Currency.usd,
    );
    await expectLater(
      ledger.create(TransactionDraft(
        type: TransactionType.transfer,
        amount: 50000,
        accountId: idr,
        transferToAccountId: usd,
        transactionAt: now,
      )),
      throwsA(
        isA<LedgerValidationException>().having(
          (e) => e.message,
          'message',
          'Transfer antar mata uang berbeda belum didukung. '
              'Pindahkan via dua transaksi atau samakan mata uang akun.',
        ),
      ),
    );
    // Rejected posting must not leave a row behind.
    final count = await db.customSelect('SELECT COUNT(*) AS c FROM transactions').getSingle();
    expect(count.read<int>('c'), 0);
  });

  test('transfer between same-currency accounts still succeeds', () async {
    final a = await repo.create(name: 'Wise1', type: AccountType.bank, openingBalance: 10000, currency: Currency.usd);
    final b = await repo.create(name: 'Wise2', type: AccountType.bank, openingBalance: 0, currency: Currency.usd);
    final txId = await ledger.create(TransactionDraft(
      type: TransactionType.transfer,
      amount: 4000,
      accountId: a,
      transferToAccountId: b,
      transactionAt: now,
    ));
    expect(txId, isNotEmpty);
    final rows = await db.select(db.transactions).get();
    expect(rows.single.transferToAccountId, b);
  });

  test('expense on a USD account posts normally (amount = minor units)', () async {
    final usd = await repo.create(name: 'Wise', type: AccountType.bank, openingBalance: 10000, currency: Currency.usd);
    final txId = await ledger.create(TransactionDraft(
      type: TransactionType.expense,
      amount: 1250, // $12.50
      accountId: usd,
      categoryId: SystemCategories.food,
      transactionAt: now,
    ));
    final tx = await (db.select(db.transactions)..where((t) => t.id.equals(txId))).getSingle();
    expect(tx.amount, 1250);
    expect((await getAccount(db, usd)).currency, 'USD');
  });
}

Future<Account> getAccount(AppDatabase db, String id) =>
    (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingle();
