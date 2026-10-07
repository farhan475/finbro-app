import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/finance/finance_service.dart';
import 'package:finbro_app/core/formatting/dates.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/backup/domain/csv_export.dart';
import 'package:finbro_app/features/transactions/domain/day_groups.dart';
import 'package:flutter_test/flutter_test.dart';

/// Multi-currency (schema v5): all cross-account aggregates are reported in
/// rupiah via the manual kurs in `exchange_rates`. Amounts of non-IDR
/// accounts are MINOR units (USD 1024 = $10.24); conversion is
/// ROUND(minor × rate_to_idr / 10^decimals) with rate_to_idr = rupiah per
/// 1 whole unit. IDR rows keep the exact legacy numbers (rate 1.0, divisor 1).
void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late FinanceService finance;
  final now = DateTime(2026, 9, 15, 12);

  Future<String> account(
    String name,
    int opening, {
    AccountType type = AccountType.bank,
    String currency = 'IDR',
  }) async {
    final id = 'acc-$name';
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(
        id: id,
        name: name,
        type: type,
        openingBalance: Value(opening),
        currency: Value(currency),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<void> setRate(String code, double rate) async {
    await db.into(db.exchangeRates).insertOnConflictUpdate(
      ExchangeRatesCompanion.insert(code: code, rateToIdr: rate, updatedAt: Value(now)),
    );
  }

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    finance = FinanceService(db, clock: () => now);
  });
  tearDown(() => db.close());

  test('default rates are seeded (fresh install)', () async {
    final usd = await (db.select(db.exchangeRates)..where((r) => r.code.equals('USD')))
        .getSingleOrNull();
    expect(usd, isNotNull);
    expect(usd!.rateToIdr, greaterThan(0));
  });

  test('IDR-only data keeps legacy numbers', () async {
    final bca = await account('BCA', 1000000);
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 250000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    expect(await finance.totalBalance(), 750000);
    final s = await finance.summary(Period.month(now));
    expect((s.income, s.expense), (0, 250000));
  });

  test('totalBalance converts a USD account at its manual kurs', () async {
    await setRate('USD', 16000);
    final bca = await account('BCA', 1000000);
    final usd = await account('Wise', 10000, currency: 'USD'); // $100.00
    expect(await finance.totalBalance(), 1000000 + 100 * 16000);

    // Changing the kurs changes the reported IDR total (manual kurs is live).
    await setRate('USD', 16250);
    expect(await finance.totalBalance(), 1000000 + 100 * 16250);

    // Nominal balance stays in the account's own currency (minor units).
    final rows = await finance.accountBalances();
    final wise = rows.firstWhere((b) => b.account.id == usd);
    final bcaRow = rows.firstWhere((b) => b.account.id == bca);
    expect(wise.balance, 10000);
    expect(wise.idrBalance, 1625000);
    expect(bcaRow.balance, 1000000);
    expect(bcaRow.idrBalance, 1000000);
  });

  test('summary converts income/expense of a USD account with rounding', () async {
    // Minor units at rate 16250: 1024¢ -> 1024×16250/100 = 166,400;
    // 333¢ -> 333×16250/100 = 54,112.5 -> 54,113 (half away from zero).
    await setRate('USD', 16250);
    final usd = await account('Wise', 0, currency: 'USD');
    await ledger.create(TransactionDraft(
      type: TransactionType.income, amount: 1024, accountId: usd,
      categoryId: SystemCategories.salary, transactionAt: now,
    ));
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 333, accountId: usd,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    final s = await finance.summary(Period.month(now));
    expect(s.income, 166400);
    expect(s.expense, 54113);
    // Per-row rounding: 691¢ -> 112,287.5 -> 112,288.
    final rows = await finance.accountBalances();
    expect(rows.firstWhere((b) => b.account.id == usd).balance, 1024 - 333);
    expect(rows.firstWhere((b) => b.account.id == usd).idrBalance, 112288);
  });

  test('monthlyTrend and spendingByCategory report IDR', () async {
    await setRate('USD', 10000);
    final usd = await account('Wise', 0, currency: 'USD');
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 1500, accountId: usd,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    final trend = await finance.monthlyTrend(now);
    expect(trend.last.expense, 1500 * 10000 ~/ 100);
    final cats = await finance.spendingByCategory(Period.month(now));
    expect(cats.single.amount, 150000);
    expect(cats.single.share, 100);
  });

  test('budget actual converts across accounts sharing a category', () async {
    await setRate('USD', 8000);
    final bca = await account('BCA', 0);
    final usd = await account('Wise', 0, currency: 'USD');
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 100000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 1000, accountId: usd,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    final budgetId = 'b1';
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
      id: budgetId,
      categoryId: SystemCategories.food,
      periodStart: DateTime(now.year, now.month, 1),
      periodEnd: DateTime(now.year, now.month + 1, 0),
      amount: 500000,
      createdAt: now,
      updatedAt: now,
    ));
    final usages = await finance.budgetUsages(now);
    // 100000 IDR + 1000¢ USD × 8000 / 100 = 100000 + 80000 = 180000.
    expect(usages.single.actual, 180000);
  });

  test('ATS goal reserve converts linked USD savings account', () async {
    await setRate('USD', 16000);
    final savings = await account('Wise', 5000, type: AccountType.savings, currency: 'USD');
    await db.into(db.goals).insert(GoalsCompanion.insert(
      id: 'g1',
      name: 'Laptop',
      type: GoalType.savings,
      targetAmount: 20000000,
      currentAmount: const Value(0),
      linkedAccountId: Value(savings),
      createdAt: now,
      updatedAt: now,
    ));
    final available = await finance.availableToSpendBreakdown(now);
    expect(available.goalReserve, 50 * 16000);
    final emergency = await finance.emergencyStatus(now);
    expect(emergency.balance, 0); // no emergency-type goals
  });

  test('upcomingObligations converts a rule on a USD account', () async {
    await setRate('USD', 16000);
    final usd = await account('Wise', 0, currency: 'USD');
    final ruleId = 'r1';
    await db.into(db.recurringRules).insert(RecurringRulesCompanion.insert(
      id: ruleId,
      type: TransactionType.expense,
      name: 'Netflix',
      amount: 1500,
      accountId: usd,
      categoryId: 'sys-expense-subscription',
      frequency: RecurringFrequency.monthly,
      dayOfMonth: Value(10),
      startDate: DateTime(now.year, now.month, 1),
      createdAt: now,
      updatedAt: now,
    ));
    await db.into(db.recurringInstances).insert(RecurringInstancesCompanion.insert(
      id: 'i1',
      recurringRuleId: ruleId,
      dueDate: DateTime(now.year, now.month, 10),
      amount: 1500,
      status: RecurringStatus.scheduled,
      createdAt: now,
      updatedAt: now,
    ));
    expect(await finance.upcomingObligations(now), 15 * 16000);
  });

  test('cross-currency transfer is rejected', () async {
    await account('BCA', 1000000);
    final usd = await account('Wise', 0, currency: 'USD');
    await expectLater(
      ledger.create(TransactionDraft(
        type: TransactionType.transfer, amount: 50000, accountId: 'acc-BCA',
        transferToAccountId: usd, transactionAt: now,
      )),
      throwsA(
        isA<LedgerValidationException>().having(
          (e) => e.message, 'message', contains('mata uang')),
      ),
    );
  });

  test('same-currency transfer still works between USD accounts', () async {
    final a = await account('Wise1', 10000, currency: 'USD');
    final b = await account('Wise2', 0, currency: 'USD');
    await setRate('USD', 16000);
    await ledger.create(TransactionDraft(
      type: TransactionType.transfer, amount: 4000, accountId: a,
      transferToAccountId: b, transactionAt: now,
    ));
    final rows = await finance.accountBalances();
    expect(rows.firstWhere((r) => r.account.id == a).balance, 6000);
    expect(rows.firstWhere((r) => r.account.id == b).balance, 4000);
    expect(await finance.totalBalance(), 100 * 16000);
  });

  test('netSaved converts a USD savings transfer into IDR', () async {
    await setRate('USD', 16000);
    final savings = await account('Wise', 0, type: AccountType.savings, currency: 'USD');
    final cash = await account('WiseCash', 0, type: AccountType.cash, currency: 'USD');
    await ledger.create(TransactionDraft(
      type: TransactionType.transfer, amount: 2500, accountId: cash,
      transferToAccountId: savings, transactionAt: now,
    ));
    // cash -> savings counts as net saving: 2500¢ × 16000 / 100.
    expect(await finance.netSaved(Period.month(now)), 400000);
    final rows = await finance.accountBalances();
    expect(rows.firstWhere((r) => r.account.id == savings).idrBalance, 400000);
  });

  group('account-bound lists', () {
    late String bca;
    late String usd;

    setUp(() async {
      await setRate('USD', 16000);
      bca = await account('BCA', 0);
      usd = await account('Wise', 0, currency: 'USD');
      await ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: 100000, accountId: bca,
        categoryId: SystemCategories.food, transactionAt: now,
      ));
      // $12.50 -> 1250¢ × 16000 / 100 = Rp 200.000.
      await ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: 1250, accountId: usd,
        categoryId: SystemCategories.food, transactionAt: now, note: 'Kopi',
      ));
    });

    test('topExpenses ranks by rupiah value, not raw minor units', () async {
      final top = await finance.topExpenses(Period.month(now));
      expect([for (final t in top) (t.accountId, t.amount)], [(usd, 1250), (bca, 100000)]);
    });

    test('day-group totals sum in rupiah via the account kurs', () async {
      final accounts = {for (final a in await db.select(db.accounts).get()) a.id: a};
      final rates = {for (final r in await db.select(db.exchangeRates).get()) r.code: r.rateToIdr};
      final rows = await db.select(db.transactions).get();
      final groups = groupByDay(rows, idrOf: idrConverter(accounts, rates));
      expect(groups.single.expense, 300000);
    });

    test('CSV carries the currency and a whole-unit amount', () async {
      final lines = (await buildTransactionsCsv(db)).substring(1).trim().split('\r\n');
      expect(lines.first.split(',').sublist(2, 4), ['amount', 'currency']);
      expect(lines.where((l) => l.contains(',expense,12.50,USD,Food,Wise,,Kopi,')), hasLength(1));
      expect(lines.where((l) => l.contains(',expense,100000,IDR,Food,BCA,,')), hasLength(1));
    });
  });
}
