import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
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
  return HomeOverview(
    available: await finance.availableToSpendBreakdown(now),
    balances: await finance.accountBalances(),
    month: await finance.summary(month),
    previous: await finance.summary(previousPeriod),
    previousPeriod: previousPeriod,
    partial: month.contains(now),
  );
});

/// Cumulative daily income/expense of the current month up to today.
final homeCashFlowProvider = FutureProvider<List<CashFlowPoint>>((ref) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  final month = Period.month(now);
  final daily = await ref.watch(financeServiceProvider).dailyTotals(month);
  return cumulativeDaily(daily, month, until: now);
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

class UpcomingItem {
  const UpcomingItem(this.instance, this.rule);
  final RecurringInstance instance;
  final RecurringRule rule;
}

/// Horizon of the dashboard "Upcoming" list.
const upcomingWindowDays = 14;

/// Open (scheduled/pending) recurring instances due within the next
/// [upcomingWindowDays] days, including overdue ones, soonest first.
final upcomingRecurringProvider = FutureProvider<List<UpcomingItem>>((ref) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  final db = ref.watch(databaseProvider);
  final horizon = dateOnly(now).add(const Duration(days: upcomingWindowDays));
  final i = db.recurringInstances;
  final r = db.recurringRules;
  final rows = await (db.select(i).join([innerJoin(r, r.id.equalsExp(i.recurringRuleId))])
        ..where(
          i.status.isInValues(const [RecurringStatus.scheduled, RecurringStatus.pending]) &
              i.dueDate.isSmallerOrEqualValue(sqlDate(horizon)),
        )
        ..orderBy([OrderingTerm.asc(i.dueDate), OrderingTerm.asc(r.name)])
        ..limit(5))
      .get();
  return [for (final row in rows) UpcomingItem(row.readTable(i), row.readTable(r))];
});

/// Top active goals by priority (higher first), then oldest.
final homeGoalsProvider = FutureProvider<List<Goal>>((ref) {
  ref.watch(dbChangesProvider);
  final db = ref.watch(databaseProvider);
  return (db.select(db.goals)
        ..where((g) => g.isActive.equals(true))
        ..orderBy([(g) => OrderingTerm.desc(g.priority), (g) => OrderingTerm.asc(g.createdAt)])
        ..limit(2))
      .get();
});
