import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../reports/domain/report_shaping.dart';

class HomeOverview {
  const HomeOverview({
    required this.available,
    required this.balances,
    required this.month,
    required this.previous,
    required this.previousPeriod,
    required this.partial,
  });

  final AvailableToSpend available;
  final List<AccountBalance> balances;

  /// Confirmed income/expense of the current month.
  final PeriodSummary month;

  /// Same figures for the comparable span of the previous month.
  final PeriodSummary previous;
  final Period previousPeriod;
  final bool partial;

  int get totalBalance => available.totalBalance;
}

final homeOverviewProvider = FutureProvider<HomeOverview>((ref) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  final finance = ref.watch(financeServiceProvider);
  final month = Period.month(now);
  final previousPeriod = previousComparable(month, ReportScope.monthly, now);
  final balances = await finance.accountBalances();
  final summary = await finance.summary(month);
  return HomeOverview(
    available: await finance.availableToSpendBreakdown(
      now,
      totalBalance: balances.fold<int>(0, (s, b) => s + b.idrBalance),
      monthIncome: summary.income,
    ),
    balances: balances,
    month: summary,
    previous: await finance.summary(previousPeriod),
    previousPeriod: previousPeriod,
    partial: month.contains(now),
  );
});

/// Total Balance path of the current month (Home sparkline), shared with
/// the home-screen widget via [FinanceService.monthBalancePath].
final homeBalancePathProvider = FutureProvider<List<int>>((ref) async {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).monthBalancePath(ref.watch(clockProvider)());
});

/// Current-month spending composition (≤ 4 slices + Other).
final homeSpendingProvider = FutureProvider<List<DonutSlice>>((ref) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  return groupSpending(await ref.watch(financeServiceProvider).spendingByCategory(Period.month(now)));
});

/// Budgets of the current month, highest usage first.
final homeBudgetsProvider = FutureProvider<List<BudgetUsageItem>>((ref) {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  return ref.watch(financeServiceProvider).budgetUsages(now);
});

/// Home "Upcoming" list: see [FinanceService.upcomingRecurring].
final upcomingRecurringProvider = FutureProvider<List<UpcomingRecurring>>((ref) async {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).upcomingRecurring(ref.watch(clockProvider)());
});

/// Top active goals by priority (higher first), then oldest, with progress.
final homeGoalsProvider = FutureProvider<List<GoalProgress>>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).goalProgresses(activeOnly: true, limit: 2);
});
