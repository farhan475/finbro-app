import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../domain/report_shaping.dart';

/// Selected report scope + any day inside the selected period.
typedef ReportQuery = ({ReportScope scope, DateTime anchor});

class ReportOverview {
  const ReportOverview({
    required this.period,
    required this.previousPeriod,
    required this.partial,
    required this.current,
    required this.previous,
    required this.netSaved,
    required this.previousNetSaved,
    required this.categories,
    required this.slices,
    required this.topTransactions,
  });

  final Period period;

  /// Comparable previous period (same elapsed span when [partial]).
  final Period previousPeriod;

  /// True when [period] is still in progress.
  final bool partial;
  final PeriodSummary current;
  final PeriodSummary previous;
  final int netSaved;
  final int previousNetSaved;

  /// Spending by category, largest first (ranking).
  final List<CategoryAmount> categories;

  /// Donut composition (top slices + Other).
  final List<DonutSlice> slices;
  final List<LedgerTransaction> topTransactions;

  double? get savingsRate => ratioPercent(netSaved, current.income);
  double? get previousSavingsRate => ratioPercent(previousNetSaved, previous.income);
}

final reportOverviewProvider = FutureProvider.autoDispose.family<ReportOverview, ReportQuery>((
  ref,
  q,
) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  final finance = ref.watch(financeServiceProvider);
  final period = q.scope.periodFor(q.anchor);
  final previousPeriod = previousComparable(period, q.scope, now);
  final categories = await finance.spendingByCategory(period);
  return ReportOverview(
    period: period,
    previousPeriod: previousPeriod,
    partial: period.contains(now),
    current: await finance.summary(period),
    previous: await finance.summary(previousPeriod),
    netSaved: await finance.netSaved(period),
    previousNetSaved: await finance.netSaved(previousPeriod),
    categories: categories,
    slices: groupSpending(categories),
    topTransactions: await finance.topExpenses(period, limit: 5),
  );
});

/// Monthly income/expense trend: 6 months ending with the selected month, or
/// the 12 months of the selected year.
final reportTrendProvider = FutureProvider.autoDispose.family<List<MonthPoint>, ReportQuery>((
  ref,
  q,
) {
  ref.watch(dbChangesProvider);
  final finance = ref.watch(financeServiceProvider);
  return switch (q.scope) {
    ReportScope.monthly => finance.monthlyTrend(q.anchor, months: 6),
    ReportScope.yearly => finance.monthlyTrend(DateTime(q.anchor.year, 12), months: 12),
  };
});

/// Budget vs actual for budgets overlapping [month].
final reportBudgetProvider = FutureProvider.autoDispose.family<List<BudgetUsageItem>, DateTime>((
  ref,
  month,
) {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).budgetUsages(monthStart(month));
});

class HealthData {
  const HealthData(this.metrics, this.plan);
  final FinancialMetrics metrics;
  final PlanningSetting plan;
}

/// Financial Health metrics for the month of [month]; emergency coverage and
/// available to spend are evaluated at the current clock time.
final healthDataProvider = FutureProvider.autoDispose.family<HealthData, DateTime>((ref, month) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  final finance = ref.watch(financeServiceProvider);
  return HealthData(
    await finance.metrics(now, period: Period.month(month)),
    await finance.planningSettings(),
  );
});
