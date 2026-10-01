import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../recurring/data/recurring_repository.dart';
import '../domain/daily_check_service.dart';

/// One calendar day: activity state (08 §6) plus the scheduled overlay.
class CalendarDay {
  const CalendarDay(this.date, this.status, this.transactionCount, this.instances);
  final DateTime date;
  final ActivityStatus status;
  final int transactionCount;

  /// All recurring instances due that day (any status).
  final List<InstanceView> instances;

  Iterable<InstanceView> get open => instances.where((v) => v.instance.status.isOpen);
  bool get hasScheduledIncome => open.any((v) => v.rule.type == TransactionType.income);
  bool get hasScheduledExpense => open.any((v) => v.rule.type == TransactionType.expense);
}

class CalendarMonth {
  const CalendarMonth(this.month, this.days);
  final DateTime month;
  final Map<DateTime, CalendarDay> days;

  CalendarDay day(DateTime d) => days[dateOnly(d)] ?? CalendarDay(dateOnly(d), ActivityStatus.unknown, 0, const []);
}

/// ACTIVE = confirmed transactions (or a stored ACTIVE marker), NO_ACTIVITY =
/// explicit user answer, otherwise UNKNOWN.
ActivityStatus deriveActivity(int confirmedCount, ActivityStatus? stored) {
  if (confirmedCount > 0 || stored == ActivityStatus.active) return ActivityStatus.active;
  return stored ?? ActivityStatus.unknown;
}

final calendarMonthProvider = FutureProvider.autoDispose.family<CalendarMonth, DateTime>((ref, month) async {
  ref.watch(dbChangesProvider);
  final db = ref.watch(databaseProvider);
  final start = monthStart(month);
  final end = nextMonthStart(month);
  final counts = await confirmedTransactionCounts(db, start, end);
  final rows = await (db.select(db.dailyActivity)
        ..where((d) => d.date.isBiggerOrEqualValue(sqlDate(start)) & d.date.isSmallerThanValue(sqlDate(end))))
      .get();
  final stored = {for (final r in rows) r.date: r.status};
  final instances = await ref.watch(recurringRepositoryProvider).instancesBetween(start, monthEnd(month));
  final byDay = <DateTime, List<InstanceView>>{};
  for (final v in instances) {
    byDay.putIfAbsent(v.instance.dueDate, () => []).add(v);
  }
  final days = <DateTime, CalendarDay>{};
  for (var d = start; d.isBefore(end); d = DateTime(d.year, d.month, d.day + 1)) {
    final count = counts[d] ?? 0;
    days[d] = CalendarDay(d, deriveActivity(count, stored[d]), count, byDay[d] ?? const []);
  }
  return CalendarMonth(start, days);
});

/// Confirmed transactions of one local day, oldest first.
final dayTransactionsProvider = FutureProvider.autoDispose.family<List<LedgerTransaction>, DateTime>((ref, day) {
  ref.watch(dbChangesProvider);
  final db = ref.watch(databaseProvider);
  final d = dateOnly(day);
  final next = DateTime(d.year, d.month, d.day + 1);
  return (db.select(db.transactions)
        ..where(
          (t) =>
              t.status.equalsValue(TransactionStatus.confirmed) &
              t.transactionAt.isBiggerOrEqualValue(sqlDateTime(d)) &
              t.transactionAt.isSmallerThanValue(sqlDateTime(next)),
        )
        ..orderBy([(t) => OrderingTerm.asc(t.transactionAt)]))
      .get();
});
