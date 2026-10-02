import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/seed.dart';
import '../formatting/dates.dart';
import '../providers.dart';
import 'finance_math.dart';

final financeServiceProvider = Provider<FinanceService>(
  (ref) => FinanceService(ref.watch(databaseProvider), clock: ref.watch(clockProvider)),
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

/// Saved amount of one goal (owner rule, schema v3). A goal linked to a
/// Savings account follows that account's calculated balance (§2: confirmed
/// rows dated up to now, opening balance included); an unlinked goal follows
/// its movements (`goals.current_amount`). Read every goal figure from here.
class GoalProgress {
  const GoalProgress({required this.goal, required this.saved, this.linkedAccount});
  final Goal goal;
  final int saved;

  /// Linked account (active or archived); null for a movements-based goal.
  final Account? linkedAccount;

  bool get isLinked => linkedAccount != null;
  double get percent => goalProgress(saved, goal.targetAmount);
  bool get reached => saved >= goal.targetAmount;
  int get remaining => reached ? 0 : goal.targetAmount - saved;
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
  FinanceService(this.db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final AppDatabase db;
  final DateTime Function() _clock;

  static const _confirmed = "status = 'confirmed'";

  Future<int> _scalar(String sql, List<Object?> args) async {
    final row = await db
        .customSelect(sql, variables: [for (final a in args) Variable(a)])
        .getSingle();
    return (row.data.values.first as int?) ?? 0;
  }

  /// §2 Calculated Balance of account [acc] whose opening balance is
  /// [opening], as of the `?1` variable. Rows dated after it (scheduled
  /// ahead) do not count until their date.
  static String _balanceSql(String acc, String opening) => '''
    $opening
    + COALESCE((SELECT SUM(CASE t.type WHEN 'income' THEN t.amount ELSE -t.amount END)
        FROM transactions t WHERE t.account_id = $acc AND t.$_confirmed
          AND t.transaction_at <= ?1), 0)
    + COALESCE((SELECT SUM(t.amount) FROM transactions t
        WHERE t.transfer_to_account_id = $acc AND t.type = 'transfer' AND t.$_confirmed
          AND t.transaction_at <= ?1), 0)''';

  /// Goals `g` with their linked account `la` (null when unlinked).
  static const _goalsJoin = 'goals g LEFT JOIN accounts la ON la.id = g.linked_account_id';

  /// The one goal progress rule ([GoalProgress]) over [_goalsJoin], as of `?1`.
  static final _goalSavedSql =
      'CASE WHEN la.id IS NULL THEN g.current_amount '
      "ELSE ${_balanceSql('la.id', 'la.opening_balance')} END";

  /// §2 Calculated Balance per account (replayed from transactions).
  Future<List<AccountBalance>> accountBalances({bool includeArchived = false}) async {
    final rows = await db.customSelect(
      'SELECT a.id AS id, ${_balanceSql('a.id', 'a.opening_balance')} AS balance FROM accounts a',
      variables: [Variable(sqlDateTime(_clock()))],
      readsFrom: {db.accounts, db.transactions},
    ).get();
    final balances = {for (final r in rows) r.read<String>('id'): r.read<int>('balance')};
    final q = db.select(db.accounts)
      ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]);
    if (!includeArchived) q.where((a) => a.isActive.equals(true));
    final accounts = await q.get();
    return [for (final a in accounts) AccountBalance(a, balances[a.id] ?? a.openingBalance)];
  }

  /// Goals with their progress ([GoalProgress]), priority DESC then oldest
  /// first. [goalId] selects one goal; [activeOnly] skips archived goals.
  Future<List<GoalProgress>> goalProgresses({String? goalId, bool activeOnly = false, int? limit}) async {
    final q = db.select(db.goals)
      ..orderBy([(g) => OrderingTerm.desc(g.priority), (g) => OrderingTerm.asc(g.createdAt)]);
    if (goalId != null) q.where((g) => g.id.equals(goalId));
    if (activeOnly) q.where((g) => g.isActive.equals(true));
    if (limit != null) q.limit(limit);
    final goals = await q.get();
    if (goals.isEmpty) return const [];
    final rows = await db.customSelect(
      'SELECT g.id AS id, $_goalSavedSql AS saved FROM $_goalsJoin',
      variables: [Variable(sqlDateTime(_clock()))],
      readsFrom: {db.goals, db.accounts, db.transactions},
    ).get();
    final saved = {for (final r in rows) r.read<String>('id'): r.read<int>('saved')};
    final linkedIds = {for (final g in goals) ?g.linkedAccountId};
    final accounts = linkedIds.isEmpty
        ? const <String, Account>{}
        : {
            for (final a in await (db.select(db.accounts)..where((a) => a.id.isIn(linkedIds))).get())
              a.id: a,
          };
    return [
      for (final g in goals)
        GoalProgress(
          goal: g,
          saved: saved[g.id] ?? g.currentAmount,
          linkedAccount: accounts[g.linkedAccountId],
        ),
    ];
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
    final first = DateTime(now.year, now.month - (months - 1));
    final rows = await db.customSelect(
      '''
      SELECT substr(transaction_at, 1, 7) AS month,
        COALESCE(SUM(CASE WHEN type = 'income' THEN amount END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN amount END), 0) AS expense
      FROM transactions
      WHERE $_confirmed AND transaction_at >= ? AND transaction_at < ?
      GROUP BY month
      ''',
      variables: [Variable(sqlDateTime(first)), Variable(sqlDateTime(nextMonthStart(now)))],
      readsFrom: {db.transactions},
    ).get();
    final byMonth = {for (final r in rows) r.read<String>('month'): r};
    final out = <MonthPoint>[];
    for (var i = 0; i < months; i++) {
      final m = DateTime(first.year, first.month + i);
      final r = byMonth[sqlDate(m).substring(0, 7)];
      out.add(MonthPoint(m, r?.read<int>('income') ?? 0, r?.read<int>('expense') ?? 0));
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

  /// §11 development-bucket expense + net contributions to development goals
  /// (manual adjustments are corrections, not allocations). A goal linked to
  /// a Savings account contributes the net transfers into that account; its
  /// movements do not count while linked (same rule as [GoalProgress]).
  Future<int> developmentAllocation(Period p) async {
    final range = [sqlDateTime(p.start), sqlDateTime(p.end)];
    final spent = await _expenseWhere(p, "c.planning_bucket = 'development'");
    final contributed = await _scalar(
      '''
      SELECT COALESCE(SUM(m.amount), 0) FROM goal_movements m
      JOIN goals g ON g.id = m.goal_id
      WHERE g.type = 'development' AND g.linked_account_id IS NULL
        AND m.movement_type <> 'adjustment'
        AND m.movement_at >= ? AND m.movement_at < ?
      ''',
      range,
    );
    final transferred = await _scalar(
      '''
      SELECT COALESCE(SUM(CASE WHEN t.transfer_to_account_id = g.linked_account_id
          THEN t.amount ELSE -t.amount END), 0)
      FROM transactions t
      JOIN goals g ON g.linked_account_id IN (t.account_id, t.transfer_to_account_id)
      WHERE g.type = 'development' AND t.type = 'transfer' AND t.$_confirmed
        AND t.transaction_at >= ? AND t.transaction_at < ?
      ''',
      range,
    );
    return spent + contributed + transferred;
  }

  /// §14 average essential expense per completed month in the lookback
  /// window. Months before the first confirmed transaction are not counted,
  /// so a new user's average is not diluted by empty months.
  Future<double> averageEssentialMonthly(DateTime now, int lookbackMonths) async {
    if (lookbackMonths <= 0) return 0;
    final window = Period.completedMonths(now, lookbackMonths);
    final first = await db.customSelect(
      'SELECT MIN(transaction_at) AS first FROM transactions WHERE $_confirmed',
      readsFrom: {db.transactions},
    ).getSingle();
    final firstAt = first.readNullable<String>('first');
    if (firstAt == null) return 0;
    final start = monthStart(DateTime.parse(firstAt));
    final from = start.isAfter(window.start) ? start : window.start;
    final months = (window.end.year - from.year) * 12 + window.end.month - from.month;
    if (months <= 0) return 0;
    final total = await essentialExpense(Period(from, window.end));
    return total / months;
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

  /// §8 Net Amount Saved: net transfers into savings-type accounts from
  /// non-savings accounts (money that actually moved). Goal contributions are
  /// earmarks tracked as goal progress and are not counted here, so the same
  /// money is never counted twice.
  Future<int> netSaved(Period p) => _scalar(
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
    [sqlDateTime(p.start), sqlDateTime(p.end)],
  );

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

  /// §4 with approved reserve rule #10. [totalBalance] and [monthIncome] may
  /// be passed when the caller already computed them for the same moment.
  /// Goal reserve = progress of active goals ([GoalProgress]); a goal linked
  /// to an archived account reserves nothing because that balance is already
  /// outside Total Balance.
  Future<AvailableToSpend> availableToSpendBreakdown(
    DateTime now, {
    int? totalBalance,
    int? monthIncome,
  }) async {
    final settings = await planningSettings();
    final month = Period.month(now);
    final goalReserve = await _scalar(
      'SELECT COALESCE(SUM(MAX($_goalSavedSql, 0)), 0) FROM $_goalsJoin '
      'WHERE g.is_active = 1 AND (la.id IS NULL OR la.is_active = 1)',
      [sqlDateTime(now)],
    );
    final income = monthIncome ?? (await summary(month)).income;
    final familySpent = await familySupportExpense(month);
    final familyPlanned = income * settings.familyPercent ~/ 100;
    final familyReserve = familyPlanned > familySpent ? familyPlanned - familySpent : 0;
    return AvailableToSpend(
      totalBalance: totalBalance ?? await this.totalBalance(),
      goalReserve: goalReserve,
      familyReserve: familyReserve,
      userReserve: settings.userReserve,
      upcomingObligations: await upcomingObligations(now),
      minimumCashBuffer: settings.minimumCashBuffer,
    );
  }

  /// Emergency Fund Balance = progress ([GoalProgress]) of active emergency
  /// goals (rule #9).
  Future<EmergencyStatus> emergencyStatus(DateTime now) async {
    final settings = await planningSettings();
    final balance = await _scalar(
      'SELECT COALESCE(SUM(MAX($_goalSavedSql, 0)), 0) FROM $_goalsJoin '
      "WHERE g.type = 'emergency' AND g.is_active = 1",
      [sqlDateTime(now)],
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
    final rows = await db.customSelect(
      '''
      SELECT b.id AS id, ${_budgetActualSql('b.category_id', 'b.period_start', 'b.period_end')} AS actual
      FROM budgets b
      WHERE b.is_active = 1 AND b.period_start <= ? AND b.period_end >= ?
      ''',
      variables: [Variable(sqlDate(monthEnd(month))), Variable(sqlDate(monthStart(month)))],
      readsFrom: {db.budgets, db.transactions},
    ).get();
    if (rows.isEmpty) return const [];
    final actuals = {for (final r in rows) r.read<String>('id'): r.read<int>('actual')};
    final joined = await (db.select(db.budgets).join([
      innerJoin(db.categories, db.categories.id.equalsExp(db.budgets.categoryId)),
    ])..where(db.budgets.id.isIn(actuals.keys)))
        .get();
    final out = [
      for (final r in joined)
        BudgetUsageItem(
          budget: r.readTable(db.budgets),
          category: r.readTable(db.categories),
          actual: actuals[r.readTable(db.budgets).id]!,
        ),
    ];
    out.sort((a, b) => b.usage.compareTo(a.usage));
    return out;
  }

  /// Confirmed expense of a category from [start] through the whole [end]
  /// day (date-only columns/params; SQLite `date()` is calendar-correct).
  static String _budgetActualSql(String category, String start, String end) => '''
    COALESCE((SELECT SUM(t.amount) FROM transactions t
      WHERE t.type = 'expense' AND t.$_confirmed AND t.category_id = $category
        AND t.transaction_at >= $start AND t.transaction_at < date($end, '+1 day')), 0)''';

  /// Actual expense for a budget's category within its inclusive date range.
  Future<int> budgetActual(Budget b) => _scalar(
    'SELECT ${_budgetActualSql('?1', '?2', '?3')}',
    [b.categoryId, sqlDate(b.periodStart), sqlDate(b.periodEnd)],
  );

  Future<FinancialMetrics> metrics(DateTime now, {Period? period}) async {
    final p = period ?? Period.month(now);
    final summaryFuture = summary(p);
    final totalBalanceFuture = totalBalance();
    final budgets = await budgetUsages(p.start);
    final summaryResult = await summaryFuture;
    final available = await availableToSpendBreakdown(
      now,
      totalBalance: await totalBalanceFuture,
      monthIncome: summaryResult.income,
    );
    return FinancialMetrics(
      summary: summaryResult,
      netSaved: await netSaved(p),
      essentialExpense: await essentialExpense(p),
      familySupport: await familySupportExpense(p),
      developmentAllocation: await developmentAllocation(p),
      recurringExpense: await recurringExpense(p),
      budgetUsed: budgets.fold(0, (s, b) => s + b.actual),
      budgetTotal: budgets.fold(0, (s, b) => s + b.budget.amount),
      emergency: await emergencyStatus(now),
      available: available,
    );
  }
}
