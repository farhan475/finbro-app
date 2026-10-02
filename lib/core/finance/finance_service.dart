import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/seed.dart';
import '../formatting/dates.dart';
import '../providers.dart';
import 'finance_math.dart';

final financeServiceProvider = Provider<FinanceService>(
  (ref) => FinanceService(ref.watch(databaseProvider)),
);

class AccountBalance {
  const AccountBalance(this.account, this.balance);
  final Account account;
  final int balance;
}

class PeriodSummary {
  const PeriodSummary({required this.income, required this.expense});
  final int income;
  final int expense;

  /// §7 Net Cash Flow (transfers excluded).
  int get netCashFlow => income - expense;
}

class CategoryAmount {
  const CategoryAmount({
    required this.categoryId,
    required this.name,
    required this.icon,
    required this.amount,
    required this.share,
  });
  final String categoryId;
  final String name;
  final String? icon;
  final int amount;

  /// §16 Category Share in percent.
  final double share;
}

class MonthPoint {
  const MonthPoint(this.month, this.income, this.expense);
  final DateTime month;
  final int income;
  final int expense;
  int get net => income - expense;
}

class BudgetUsageItem {
  const BudgetUsageItem({required this.budget, required this.category, required this.actual});
  final Budget budget;
  final Category category;
  final int actual;

  double get usage => budgetUsage(actual, budget.amount);
  int get variance => budgetVariance(budget.amount, actual);
  BudgetStatus get status => budgetStatus(
    actual,
    budget.amount,
    attention: budget.attentionThreshold,
    warning: budget.warningThreshold,
    over: budget.overThreshold,
  );
}

/// §4 breakdown so the UI can explain the number.
class AvailableToSpend {
  const AvailableToSpend({
    required this.totalBalance,
    required this.goalReserve,
    required this.familyReserve,
    required this.userReserve,
    required this.upcomingObligations,
    required this.minimumCashBuffer,
  });
  final int totalBalance;
  final int goalReserve;
  final int familyReserve;
  final int userReserve;
  final int upcomingObligations;
  final int minimumCashBuffer;

  int get reserved => goalReserve + familyReserve + userReserve;
  int get value => availableToSpend(
    totalBalance: totalBalance,
    reserved: reserved,
    upcomingObligations: upcomingObligations,
    minimumCashBuffer: minimumCashBuffer,
  );
}

class EmergencyStatus {
  const EmergencyStatus({
    required this.balance,
    required this.avgEssentialMonthly,
    required this.targetMonths,
    required this.lookbackMonths,
  });
  final int balance;
  final double avgEssentialMonthly;
  final int targetMonths;
  final int lookbackMonths;

  double? get coverageMonths => emergencyCoverage(balance, avgEssentialMonthly);
  int get targetAmount => (avgEssentialMonthly * targetMonths).round();
}

/// Metric panel (§20): value + source rule, no opaque score.
class FinancialMetrics {
  const FinancialMetrics({
    required this.summary,
    required this.netSaved,
    required this.essentialExpense,
    required this.familySupport,
    required this.developmentAllocation,
    required this.recurringExpense,
    required this.budgetUsed,
    required this.budgetTotal,
    required this.emergency,
    required this.available,
  });
  final PeriodSummary summary;
  final int netSaved;
  final int essentialExpense;
  final int familySupport;
  final int developmentAllocation;
  final int recurringExpense;
  final int budgetUsed;
  final int budgetTotal;
  final EmergencyStatus emergency;
  final AvailableToSpend available;

  double? get savingsRate => ratioPercent(netSaved, summary.income);
  double? get essentialRatio => ratioPercent(essentialExpense, summary.income);
  double? get familyRatio => ratioPercent(familySupport, summary.income);
  double? get developmentRatio => ratioPercent(developmentAllocation, summary.income);
  double? get recurringRatio => ratioPercent(recurringExpense, summary.income);
  double? get budgetUsage => ratioPercent(budgetUsed, budgetTotal);
}

/// Read-side calculations from 03-financial-rules-and-formulas.md. Every
/// figure is recomputed from confirmed source rows.
class FinanceService {
  FinanceService(this.db);
  final AppDatabase db;

  static const _confirmed = "status = 'confirmed'";

  Future<int> _scalar(String sql, List<Object?> args) async {
    final row = await db
        .customSelect(sql, variables: [for (final a in args) Variable(a)])
        .getSingle();
    return (row.data.values.first as int?) ?? 0;
  }

  /// §2 Calculated Balance per account (replayed from transactions).
  Future<List<AccountBalance>> accountBalances({bool includeArchived = false}) async {
    final rows = await db.customSelect(
      '''
      SELECT a.id AS id,
        a.opening_balance
        + COALESCE((SELECT SUM(CASE t.type WHEN 'income' THEN t.amount ELSE -t.amount END)
            FROM transactions t WHERE t.account_id = a.id AND t.$_confirmed), 0)
        + COALESCE((SELECT SUM(t.amount) FROM transactions t
            WHERE t.transfer_to_account_id = a.id AND t.type = 'transfer' AND t.$_confirmed), 0)
        AS balance
      FROM accounts a
      ''',
      readsFrom: {db.accounts, db.transactions},
    ).get();
    final balances = {for (final r in rows) r.read<String>('id'): r.read<int>('balance')};
    final q = db.select(db.accounts)
      ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]);
    if (!includeArchived) q.where((a) => a.isActive.equals(true));
    final accounts = await q.get();
    return [for (final a in accounts) AccountBalance(a, balances[a.id] ?? a.openingBalance)];
  }

  /// §3 Total Balance (active accounts only).
  Future<int> totalBalance() async =>
      (await accountBalances()).fold<int>(0, (s, b) => s + b.balance);

  /// §5–§7 for a period.
  Future<PeriodSummary> summary(Period p) async {
    final rows = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN amount END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN amount END), 0) AS expense
      FROM transactions
      WHERE $_confirmed AND transaction_at >= ? AND transaction_at < ?
      ''',
      variables: [Variable(sqlDateTime(p.start)), Variable(sqlDateTime(p.end))],
      readsFrom: {db.transactions},
    ).getSingle();
    return PeriodSummary(income: rows.read<int>('income'), expense: rows.read<int>('expense'));
  }

  /// §16 spending by category, largest first.
  Future<List<CategoryAmount>> spendingByCategory(Period p) async {
    final rows = await db.customSelect(
      '''
      SELECT c.id AS id, c.name AS name, c.icon AS icon, SUM(t.amount) AS total
      FROM transactions t JOIN categories c ON c.id = t.category_id
      WHERE t.type = 'expense' AND t.$_confirmed
        AND t.transaction_at >= ? AND t.transaction_at < ?
      GROUP BY c.id ORDER BY total DESC
      ''',
      variables: [Variable(sqlDateTime(p.start)), Variable(sqlDateTime(p.end))],
      readsFrom: {db.transactions, db.categories},
    ).get();
    final total = rows.fold<int>(0, (s, r) => s + r.read<int>('total'));
    return [
      for (final r in rows)
        CategoryAmount(
          categoryId: r.read<String>('id'),
          name: r.read<String>('name'),
          icon: r.readNullable<String>('icon'),
          amount: r.read<int>('total'),
          share: ratioPercent(r.read<int>('total'), total) ?? 0,
        ),
    ];
  }

  /// FR-RPT-003 largest expense transactions.
  Future<List<LedgerTransaction>> topExpenses(Period p, {int limit = 5}) {
    return (db.select(db.transactions)
          ..where(
            (t) =>
                t.type.equalsValue(TransactionType.expense) &
                t.status.equalsValue(TransactionStatus.confirmed) &
                t.transactionAt.isBiggerOrEqualValue(sqlDateTime(p.start)) &
                t.transactionAt.isSmallerThanValue(sqlDateTime(p.end)),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.amount)])
          ..limit(limit))
        .get();
  }

  /// Monthly income/expense for the [months] months ending with [now]'s month.
  Future<List<MonthPoint>> monthlyTrend(DateTime now, {int months = 6}) async {
    final out = <MonthPoint>[];
    for (var i = months - 1; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i);
      final s = await summary(Period.month(m));
      out.add(MonthPoint(m, s.income, s.expense));
    }
    return out;
  }

  /// Daily income/expense inside a period (line chart within a month).
  Future<Map<DateTime, PeriodSummary>> dailyTotals(Period p) async {
    final rows = await db.customSelect(
      '''
      SELECT substr(transaction_at, 1, 10) AS day,
        COALESCE(SUM(CASE WHEN type = 'income' THEN amount END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN amount END), 0) AS expense
      FROM transactions
      WHERE $_confirmed AND transaction_at >= ? AND transaction_at < ?
      GROUP BY day
      ''',
      variables: [Variable(sqlDateTime(p.start)), Variable(sqlDateTime(p.end))],
      readsFrom: {db.transactions},
    ).get();
    return {
      for (final r in rows)
        DateTime.parse(r.read<String>('day')): PeriodSummary(
          income: r.read<int>('income'),
          expense: r.read<int>('expense'),
        ),
    };
  }

  Future<int> _expenseWhere(Period p, String categoryFilter) => _scalar(
    '''
    SELECT COALESCE(SUM(t.amount), 0) FROM transactions t
    JOIN categories c ON c.id = t.category_id
    WHERE t.type = 'expense' AND t.$_confirmed AND $categoryFilter
      AND t.transaction_at >= ? AND t.transaction_at < ?
    ''',
    [sqlDateTime(p.start), sqlDateTime(p.end)],
  );

  /// §9 expense in categories with expense_nature = essential.
  Future<int> essentialExpense(Period p) =>
      _expenseWhere(p, "c.expense_nature = 'essential'");

  /// §10 expense in planning bucket family.
  Future<int> familySupportExpense(Period p) =>
      _expenseWhere(p, "c.planning_bucket = 'family'");

  /// §11 development-bucket expense + net contributions to development goals.
  Future<int> developmentAllocation(Period p) async {
    final spent = await _expenseWhere(p, "c.planning_bucket = 'development'");
    final contributed = await _scalar(
      '''
      SELECT COALESCE(SUM(m.amount), 0) FROM goal_movements m
      JOIN goals g ON g.id = m.goal_id
      WHERE g.type = 'development' AND m.movement_at >= ? AND m.movement_at < ?
      ''',
      [sqlDateTime(p.start), sqlDateTime(p.end)],
    );
    return spent + contributed;
  }

  /// §14 average essential expense over completed lookback months.
  Future<double> averageEssentialMonthly(DateTime now, int lookbackMonths) async {
    final total = await essentialExpense(Period.completedMonths(now, lookbackMonths));
    return total / lookbackMonths;
  }

  /// §15 confirmed expenses that came from recurring instances.
  Future<int> recurringExpense(Period p) => _scalar(
    '''
    SELECT COALESCE(SUM(amount), 0) FROM transactions
    WHERE type = 'expense' AND $_confirmed AND recurring_instance_id IS NOT NULL
      AND transaction_at >= ? AND transaction_at < ?
    ''',
    [sqlDateTime(p.start), sqlDateTime(p.end)],
  );

  /// §8 Net Amount Saved (approved rule #12):
  /// net contributions to savings/emergency/development goals that are not
  /// already represented by a transfer into a savings account
  /// + net transfers into savings-type accounts from non-savings accounts.
  Future<int> netSaved(Period p) async {
    final range = [sqlDateTime(p.start), sqlDateTime(p.end)];
    final goalPart = await _scalar(
      '''
      SELECT COALESCE(SUM(m.amount), 0) FROM goal_movements m
      JOIN goals g ON g.id = m.goal_id
      LEFT JOIN transactions t ON t.id = m.transaction_id
      LEFT JOIN accounts dst ON dst.id = t.transfer_to_account_id
      WHERE g.type IN ('savings', 'emergency', 'development')
        AND m.movement_type <> 'adjustment'
        AND m.movement_at >= ? AND m.movement_at < ?
        AND (t.id IS NULL OR dst.type IS NULL OR dst.type <> 'savings')
      ''',
      range,
    );
    final transferPart = await _scalar(
      '''
      SELECT COALESCE(SUM(CASE
          WHEN dst.type = 'savings' AND src.type <> 'savings' THEN t.amount
          WHEN src.type = 'savings' AND dst.type <> 'savings' THEN -t.amount
          ELSE 0 END), 0)
      FROM transactions t
      JOIN accounts src ON src.id = t.account_id
      JOIN accounts dst ON dst.id = t.transfer_to_account_id
      WHERE t.type = 'transfer' AND t.$_confirmed
        AND t.transaction_at >= ? AND t.transaction_at < ?
      ''',
      range,
    );
    return goalPart + transferPart;
  }

  Future<PlanningSetting> planningSettings() => (db.select(db.planningSettings)
        ..where((s) => s.id.equals(planningSettingsId)))
      .getSingle();

  /// Upcoming Obligations: open recurring expense instances due up to the end
  /// of [now]'s month (includes overdue, still-unpaid ones).
  Future<int> upcomingObligations(DateTime now) => _scalar(
    '''
    SELECT COALESCE(SUM(i.amount), 0) FROM recurring_instances i
    JOIN recurring_rules r ON r.id = i.recurring_rule_id
    WHERE r.type = 'expense' AND i.status IN ('scheduled', 'pending')
      AND i.due_date <= ?
    ''',
    [sqlDate(monthEnd(now))],
  );

  /// §4 with approved reserve rule #10.
  Future<AvailableToSpend> availableToSpendBreakdown(DateTime now) async {
    final settings = await planningSettings();
    final month = Period.month(now);
    final goalReserve = await _scalar(
      'SELECT COALESCE(SUM(MAX(current_amount, 0)), 0) FROM goals WHERE is_active = 1',
      const [],
    );
    final income = (await summary(month)).income;
    final familySpent = await familySupportExpense(month);
    final familyPlanned = income * settings.familyPercent ~/ 100;
    final familyReserve = familyPlanned > familySpent ? familyPlanned - familySpent : 0;
    return AvailableToSpend(
      totalBalance: await totalBalance(),
      goalReserve: goalReserve,
      familyReserve: familyReserve,
      userReserve: settings.userReserve,
      upcomingObligations: await upcomingObligations(now),
      minimumCashBuffer: settings.minimumCashBuffer,
    );
  }

  /// Emergency Fund Balance = sum of active emergency goals (rule #9).
  Future<EmergencyStatus> emergencyStatus(DateTime now) async {
    final settings = await planningSettings();
    final balance = await _scalar(
      "SELECT COALESCE(SUM(current_amount), 0) FROM goals WHERE type = 'emergency' AND is_active = 1",
      const [],
    );
    return EmergencyStatus(
      balance: balance,
      avgEssentialMonthly: await averageEssentialMonthly(now, settings.emergencyLookbackMonths),
      targetMonths: settings.targetEmergencyMonths,
      lookbackMonths: settings.emergencyLookbackMonths,
    );
  }

  /// FR-BUD-002 budgets overlapping the month of [month] with actuals.
  Future<List<BudgetUsageItem>> budgetUsages(DateTime month) async {
    final start = sqlDate(monthStart(month));
    final end = sqlDate(monthEnd(month));
    final rows = await (db.select(db.budgets).join([
      innerJoin(db.categories, db.categories.id.equalsExp(db.budgets.categoryId)),
    ])..where(
            db.budgets.isActive.equals(true) &
                db.budgets.periodStart.isSmallerOrEqualValue(end) &
                db.budgets.periodEnd.isBiggerOrEqualValue(start),
          ))
        .get();
    final out = <BudgetUsageItem>[];
    for (final r in rows) {
      final b = r.readTable(db.budgets);
      out.add(
        BudgetUsageItem(
          budget: b,
          category: r.readTable(db.categories),
          actual: await budgetActual(b),
        ),
      );
    }
    out.sort((a, b) => b.usage.compareTo(a.usage));
    return out;
  }

  /// Actual expense for a budget's category within its inclusive date range.
  Future<int> budgetActual(Budget b) => _scalar(
    '''
    SELECT COALESCE(SUM(amount), 0) FROM transactions
    WHERE type = 'expense' AND $_confirmed AND category_id = ?
      AND transaction_at >= ? AND transaction_at < ?
    ''',
    [
      b.categoryId,
      sqlDateTime(b.periodStart),
      sqlDateTime(b.periodEnd.add(const Duration(days: 1))),
    ],
  );

  Future<FinancialMetrics> metrics(DateTime now, {Period? period}) async {
    final p = period ?? Period.month(now);
    final budgets = await budgetUsages(p.start);
    return FinancialMetrics(
      summary: await summary(p),
      netSaved: await netSaved(p),
      essentialExpense: await essentialExpense(p),
      familySupport: await familySupportExpense(p),
      developmentAllocation: await developmentAllocation(p),
      recurringExpense: await recurringExpense(p),
      budgetUsed: budgets.fold(0, (s, b) => s + b.actual),
      budgetTotal: budgets.fold(0, (s, b) => s + b.budget.amount),
      emergency: await emergencyStatus(now),
      available: await availableToSpendBreakdown(now),
    );
  }
}
