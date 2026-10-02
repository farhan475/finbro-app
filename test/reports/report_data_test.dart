import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/finance/finance_service.dart';
import 'package:finbro_app/core/formatting/dates.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/features/dashboard/data/dashboard_providers.dart';
import 'package:finbro_app/features/reports/data/report_providers.dart';
import 'package:finbro_app/features/reports/domain/health_metrics.dart';
import 'package:finbro_app/features/reports/domain/report_shaping.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late String bca;
  final now = DateTime(2026, 9, 15, 12);

  Future<void> expense(int amount, DateTime at, {String category = SystemCategories.food}) => ledger.create(
    TransactionDraft(type: TransactionType.expense, amount: amount, accountId: bca, categoryId: category, transactionAt: at),
  );

  Future<void> income(int amount, DateTime at) => ledger.create(
    TransactionDraft(
      type: TransactionType.income,
      amount: amount,
      accountId: bca,
      categoryId: SystemCategories.salary,
      transactionAt: at,
    ),
  );

  Future<void> goal(String id, GoalType type, int current, {int priority = 0, DateTime? created}) =>
      db.into(db.goals).insert(
        GoalsCompanion.insert(
          id: id,
          name: id,
          type: type,
          targetAmount: 20000000,
          currentAmount: Value(current),
          priority: Value(priority),
          createdAt: created ?? now,
          updatedAt: now,
        ),
      );

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Keeps [p] alive (it may be autoDispose) while awaiting its value.
  Future<T> readAsync<T>(ProviderContainer c, FutureProvider<T> p) {
    c.listen(p, (_, _) {});
    return c.read(p.future);
  }

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    bca = 'acc-bca';
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(
        id: bca,
        name: 'BCA',
        type: AccountType.bank,
        openingBalance: const Value(20000000),
        createdAt: now,
        updatedAt: now,
      ),
    );
  });
  tearDown(() => db.close());

  test('report overview compares with the same elapsed span of last month', () async {
    await expense(100000, DateTime(2026, 8, 10));
    await expense(900000, DateTime(2026, 8, 20)); // after 15 Aug: not comparable
    await expense(150000, DateTime(2026, 9, 5));
    await income(5000000, DateTime(2026, 9, 1));

    final c = container();
    final q = (scope: ReportScope.monthly, anchor: DateTime(2026, 9));
    final o = await readAsync(c, reportOverviewProvider(q));

    expect(o.partial, isTrue);
    expect(o.previousPeriod, Period(DateTime(2026, 8), DateTime(2026, 8, 16)));
    expect(o.current.expense, 150000);
    expect(o.previous.expense, 100000);
    expect(o.previous.income, 0); // → Income change renders N/A
    expect(o.slices.single.label, 'Food');
    expect(o.topTransactions.single.amount, 150000);
  });

  test('past month overview compares with the full previous month', () async {
    await expense(100000, DateTime(2026, 7, 31));
    await expense(300000, DateTime(2026, 8, 31));
    final c = container();
    final q = (scope: ReportScope.monthly, anchor: DateTime(2026, 8));
    final o = await readAsync(c, reportOverviewProvider(q));
    expect(o.partial, isFalse);
    expect(o.previous.expense, 100000);
    expect(o.current.expense, 300000);
  });

  test('upcoming list: open instances due within 14 days incl. overdue, soonest first', () async {
    await db.into(db.recurringRules).insert(
      RecurringRulesCompanion.insert(
        id: 'r1',
        type: TransactionType.expense,
        name: 'Internet',
        amount: 300000,
        accountId: bca,
        categoryId: 'sys-expense-bills',
        frequency: RecurringFrequency.monthly,
        startDate: DateTime(2026, 1, 1),
        createdAt: now,
        updatedAt: now,
      ),
    );
    Future<void> instance(String id, DateTime due, RecurringStatus status) => db.into(db.recurringInstances).insert(
      RecurringInstancesCompanion.insert(
        id: id,
        recurringRuleId: 'r1',
        dueDate: due,
        amount: 300000,
        status: status,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await instance('late', DateTime(2026, 9, 10), RecurringStatus.pending);
    await instance('soon', DateTime(2026, 9, 29), RecurringStatus.scheduled);
    await instance('done', DateTime(2026, 9, 1), RecurringStatus.confirmed);
    await instance('skipped', DateTime(2026, 9, 20), RecurringStatus.skipped);
    await instance('beyond', DateTime(2026, 9, 30), RecurringStatus.scheduled); // 15 days out

    final c = container();
    final items = await readAsync(c, upcomingRecurringProvider);
    expect([for (final i in items) i.instance.id], ['late', 'soon']);
    expect(items.first.rule.name, 'Internet');
  });

  test('dashboard goals: top 2 active by priority, then oldest', () async {
    await goal('low', GoalType.custom, 0, priority: 1);
    await goal('high', GoalType.savings, 0, priority: 3);
    await goal('mid-old', GoalType.custom, 0, priority: 2, created: DateTime(2026, 1, 1));
    await goal('mid-new', GoalType.custom, 0, priority: 2);
    final c = container();
    final goals = await readAsync(c, homeGoalsProvider);
    expect([for (final g in goals) g.goal.id], ['high', 'mid-old']);
  });

  test('dashboard cash flow is cumulative up to today', () async {
    await income(5000000, DateTime(2026, 9, 1, 9));
    await expense(200000, DateTime(2026, 9, 3));
    await expense(999999, DateTime(2026, 9, 20)); // future-dated this month
    final c = container();
    final points = await readAsync(c, homeCashFlowProvider);
    expect(points, hasLength(15));
    expect(points.last.income, 5000000);
    expect(points.last.expense, 200000);
  });

  group('financial health panel', () {
    test('ratios, benchmarks and emergency coverage from real data', () async {
      for (final m in [6, 7, 8]) {
        await expense(2000000, DateTime(2026, m, 10));
      }
      await income(5000000, DateTime(2026, 9, 1));
      await expense(1000000, DateTime(2026, 9, 2)); // food: essential
      await expense(400000, DateTime(2026, 9, 3), category: SystemCategories.family);
      await goal('ef', GoalType.emergency, 7000000);

      final finance = FinanceService(db);
      final metrics = await finance.metrics(now);
      final panel = {for (final m in buildHealthMetrics(metrics, await finance.planningSettings())) m.kind: m};

      expect(panel.keys, HealthMetricKind.values);
      expect(panel[HealthMetricKind.essentialRatio]!.value, '20,0%');
      expect(panel[HealthMetricKind.essentialRatio]!.benchmark, contains('45%'));
      expect(panel[HealthMetricKind.essentialRatio]!.comparison, 'Di bawah rencana 45%');
      expect(panel[HealthMetricKind.familyRatio]!.value, '8,0%');
      expect(panel[HealthMetricKind.savingsRate]!.benchmark, contains('25%'));
      expect(panel[HealthMetricKind.budgetUsage]!.value, 'N/A');
      expect(panel[HealthMetricKind.emergencyCoverage]!.value, '3,5 bulan');
      expect(panel[HealthMetricKind.emergencyCoverage]!.comparison, 'Mencapai target');
      expect(panel[HealthMetricKind.netCashFlow]!.value, '+Rp 3.600.000');
      for (final m in panel.values) {
        expect(m.source, isNotEmpty, reason: m.title);
      }
      expect(
        healthSummary(metrics),
        contains('Emergency fund menutup 3,5 bulan dari target 3 bulan.'),
      );
    });

    test('no income: ratios are N/A without a comparison', () async {
      await expense(100000, DateTime(2026, 9, 2));
      final finance = FinanceService(db);
      final metrics = await finance.metrics(now);
      final panel = {for (final m in buildHealthMetrics(metrics, await finance.planningSettings())) m.kind: m};
      for (final k in [
        HealthMetricKind.savingsRate,
        HealthMetricKind.essentialRatio,
        HealthMetricKind.familyRatio,
        HealthMetricKind.developmentRatio,
        HealthMetricKind.recurringRatio,
      ]) {
        expect(panel[k]!.value, 'N/A', reason: k.title);
        expect(panel[k]!.comparison, isNull, reason: k.title);
      }
      expect(panel[HealthMetricKind.emergencyCoverage]!.value, 'N/A');
      expect(healthSummary(metrics).first, 'Expense melebihi income sebesar Rp 100.000 pada periode ini.');
    });
  });

  test('comparePlan is factual around the target', () {
    expect(comparePlan(null, 45), isNull);
    expect(comparePlan(45.2, 45), 'Sesuai rencana 45%');
    expect(comparePlan(50, 45), 'Di atas rencana 45%');
    expect(comparePlan(10, 45), 'Di bawah rencana 45%');
  });
}
