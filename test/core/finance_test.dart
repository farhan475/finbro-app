import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/finance/finance_math.dart';
import 'package:finbro_app/core/finance/finance_service.dart';
import 'package:finbro_app/core/formatting/dates.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late FinanceService finance;
  final now = DateTime(2026, 9, 15, 12);

  Future<String> account(String name, int opening, {AccountType type = AccountType.bank}) async {
    final id = 'acc-$name';
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(
        id: id,
        name: name,
        type: type,
        openingBalance: Value(opening),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<int> balanceOf(String id) async =>
      (await finance.accountBalances()).firstWhere((b) => b.account.id == id).balance;

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    finance = FinanceService(db, clock: () => now);
  });
  tearDown(() => db.close());

  test('A: income increases balance', () async {
    final bca = await account('BCA', 1000000);
    await ledger.create(TransactionDraft(
      type: TransactionType.income, amount: 500000, accountId: bca,
      categoryId: SystemCategories.salary, transactionAt: now,
    ));
    expect(await balanceOf(bca), 1500000);
  });

  test('B: expense decreases balance', () async {
    final bca = await account('BCA', 1000000);
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 200000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    expect(await balanceOf(bca), 800000);
  });

  test('C: transfer moves money, total unchanged, not income/expense', () async {
    final bca = await account('BCA', 1000000);
    final gopay = await account('GoPay', 0, type: AccountType.ewallet);
    await ledger.create(TransactionDraft(
      type: TransactionType.transfer, amount: 300000, accountId: bca,
      transferToAccountId: gopay, transactionAt: now,
    ));
    expect(await balanceOf(bca), 700000);
    expect(await balanceOf(gopay), 300000);
    expect(await finance.totalBalance(), 1000000);
    final s = await finance.summary(Period.month(now));
    expect((s.income, s.expense), (0, 0));
  });

  test('transfer to same account is rejected', () async {
    final bca = await account('BCA', 1000000);
    expect(
      () => ledger.create(TransactionDraft(
        type: TransactionType.transfer, amount: 1, accountId: bca,
        transferToAccountId: bca, transactionAt: now,
      )),
      throwsA(isA<LedgerValidationException>()),
    );
  });

  test('archived account rejects new transactions', () async {
    final bca = await account('BCA', 0);
    await (db.update(db.accounts)..where((a) => a.id.equals(bca)))
        .write(const AccountsCompanion(isActive: Value(false)));
    expect(
      () => ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: 1, accountId: bca,
        categoryId: SystemCategories.food, transactionAt: now,
      )),
      throwsA(isA<LedgerValidationException>()),
    );
  });

  test('delete restores balance; drafts do not count', () async {
    final bca = await account('BCA', 1000000);
    final id = await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 250000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    await ledger.create(
      TransactionDraft(
        type: TransactionType.expense, amount: 999, accountId: bca,
        categoryId: SystemCategories.food, transactionAt: now,
      ),
      status: TransactionStatus.draft,
    );
    expect(await balanceOf(bca), 750000);
    await ledger.delete(id);
    expect(await balanceOf(bca), 1000000);
  });

  test('D/E: budget usage 85% and over-budget variance', () async {
    final bca = await account('BCA', 5000000);
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
      id: 'b1', categoryId: SystemCategories.food,
      periodStart: DateTime(2026, 9, 1), periodEnd: DateTime(2026, 9, 30),
      amount: 1000000, createdAt: now, updatedAt: now,
    ));
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 850000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: DateTime(2026, 9, 30, 23, 59),
    ));
    var item = (await finance.budgetUsages(now)).single;
    expect(item.usage, 85);
    expect(item.status, BudgetStatus.warning);

    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 250000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: DateTime(2026, 9, 2),
    ));
    item = (await finance.budgetUsages(now)).single;
    expect(item.variance, -100000);
    expect(item.status, BudgetStatus.over);
  });

  test('F: emergency coverage = balance / avg essential', () {
    expect(emergencyCoverage(6000000, 2000000), 3);
    expect(emergencyCoverage(6000000, 0), isNull);
  });

  test('emergency status uses completed lookback months', () async {
    final bca = await account('BCA', 50000000);
    for (final m in [6, 7, 8]) {
      await ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: 2000000, accountId: bca,
        categoryId: SystemCategories.food, transactionAt: DateTime(2026, m, 10),
      ));
    }
    // Current-month essential spending is excluded from the lookback.
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 9000000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: now,
    ));
    await db.into(db.goals).insert(GoalsCompanion.insert(
      id: 'g1', name: 'Emergency Fund', type: GoalType.emergency,
      targetAmount: 6000000, currentAmount: const Value(6000000),
      createdAt: now, updatedAt: now,
    ));
    final e = await finance.emergencyStatus(now);
    expect(e.avgEssentialMonthly, 2000000);
    expect(e.coverageMonths, 3);
  });

  test('allocation follows §19 and residual goes to flexible', () {
    const plan = AllocationPlan(
      essential: 45, family: 10, emergency: 10, savings: 15, development: 10, personal: 10,
    );
    final a = allocateIncome(5000000, plan);
    expect(a[PlanningBucket.essential], 2250000);
    expect(a[PlanningBucket.savings], 750000);
    expect(a[PlanningBucket.flexible], 0);
    final odd = allocateIncome(1000003, plan);
    expect(odd.values.fold<int>(0, (s, v) => s + v), 1000003);
    expect(plan.validate(), isNull);
    expect(
      const AllocationPlan(essential: 50, family: 10, emergency: 10, savings: 15, development: 10, personal: 10)
          .validate(),
      isNotNull,
    );
  });

  test('percent change is N/A when previous is zero', () {
    expect(percentChange(100, 0), isNull);
    expect(percentChange(150, 100), 50);
  });

  test('available to spend subtracts reserves, obligations and buffer', () async {
    final bca = await account('BCA', 10000000);
    await ledger.create(TransactionDraft(
      type: TransactionType.income, amount: 5000000, accountId: bca,
      categoryId: SystemCategories.salary, transactionAt: now,
    ));
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 200000, accountId: bca,
      categoryId: SystemCategories.family, transactionAt: now,
    ));
    await db.into(db.goals).insert(GoalsCompanion.insert(
      id: 'g1', name: 'Laptop', type: GoalType.custom, targetAmount: 15000000,
      currentAmount: const Value(1000000), createdAt: now, updatedAt: now,
    ));
    await db.into(db.recurringRules).insert(RecurringRulesCompanion.insert(
      id: 'r1', type: TransactionType.expense, name: 'Internet', amount: 300000,
      accountId: bca, categoryId: 'sys-expense-bills',
      frequency: RecurringFrequency.monthly, startDate: DateTime(2026, 1, 1),
      createdAt: now, updatedAt: now,
    ));
    await db.into(db.recurringInstances).insert(RecurringInstancesCompanion.insert(
      id: 'i1', recurringRuleId: 'r1', dueDate: DateTime(2026, 9, 28), amount: 300000,
      status: RecurringStatus.scheduled, createdAt: now, updatedAt: now,
    ));
    await (db.update(db.planningSettings)..where((s) => s.id.equals(planningSettingsId)))
        .write(const PlanningSettingsCompanion(minimumCashBuffer: Value(500000)));

    final a = await finance.availableToSpendBreakdown(now);
    expect(a.totalBalance, 14800000);
    expect(a.goalReserve, 1000000);
    expect(a.familyReserve, 300000); // 10% × 5.000.000 − 200.000
    expect(a.upcomingObligations, 300000);
    expect(a.value, 14800000 - 1000000 - 300000 - 300000 - 500000);
  });

  test('a future-dated transaction does not change the balance before its date', () async {
    final bca = await account('BCA', 1000000);
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 300000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: DateTime(2026, 9, 20),
    ));
    expect(await balanceOf(bca), 1000000);
    expect(await finance.totalBalance(), 1000000);

    finance = FinanceService(db, clock: () => DateTime(2026, 9, 20, 8));
    expect(await balanceOf(bca), 700000);
  });

  test('net saved counts transfers into savings accounts, not goal contributions', () async {
    final bca = await account('BCA', 10000000);
    final tabungan = await account('Tabungan', 0, type: AccountType.savings);
    await ledger.create(TransactionDraft(
      type: TransactionType.transfer, amount: 2000000, accountId: bca,
      transferToAccountId: tabungan, transactionAt: now,
    ));
    await ledger.create(TransactionDraft(
      type: TransactionType.transfer, amount: 500000, accountId: tabungan,
      transferToAccountId: bca, transactionAt: now,
    ));
    await db.into(db.goals).insert(GoalsCompanion.insert(
      id: 'g1', name: 'Dana Darurat', type: GoalType.emergency,
      targetAmount: 6000000, createdAt: now, updatedAt: now,
    ));
    await db.into(db.goalMovements).insert(GoalMovementsCompanion.insert(
      id: 'm1', goalId: 'g1', amount: 1500000,
      movementType: MovementType.contribution, movementAt: now,
    ));
    expect(await finance.netSaved(Period.month(now)), 1500000);
  });

  test('development allocation ignores goal adjustments', () async {
    await db.into(db.goals).insert(GoalsCompanion.insert(
      id: 'g1', name: 'Kursus', type: GoalType.development,
      targetAmount: 3000000, createdAt: now, updatedAt: now,
    ));
    for (final (id, amount, type) in [
      ('m1', 400000, MovementType.contribution),
      ('m2', 900000, MovementType.adjustment),
    ]) {
      await db.into(db.goalMovements).insert(GoalMovementsCompanion.insert(
        id: id, goalId: 'g1', amount: amount, movementType: type, movementAt: now,
      ));
    }
    expect(await finance.developmentAllocation(Period.month(now)), 400000);
  });

  test('average essential spending ignores months before the first transaction', () async {
    final bca = await account('BCA', 50000000);
    await ledger.create(TransactionDraft(
      type: TransactionType.expense, amount: 3000000, accountId: bca,
      categoryId: SystemCategories.food, transactionAt: DateTime(2026, 8, 10),
    ));
    expect(await finance.averageEssentialMonthly(now, 6), 3000000);
    expect(await finance.averageEssentialMonthly(now, 0), 0);
  });

  test('a budget ending on a date includes that whole calendar day', () async {
    final bca = await account('BCA', 5000000);
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
      id: 'b1', categoryId: SystemCategories.food,
      periodStart: DateTime(2026, 9, 1), periodEnd: DateTime(2026, 9, 14),
      amount: 1000000, createdAt: now, updatedAt: now,
    ));
    for (final at in [DateTime(2026, 9, 14, 23, 59), DateTime(2026, 9, 15)]) {
      await ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: 100000, accountId: bca,
        categoryId: SystemCategories.food, transactionAt: at,
      ));
    }
    final b = await (db.select(db.budgets)..where((b) => b.id.equals('b1'))).getSingle();
    expect(await finance.budgetActual(b), 100000);
  });
}
