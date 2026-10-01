import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';

/// Transactions of one calendar day with that day's totals.
class DayGroup {
  DayGroup(this.day);

  final DateTime day;
  final List<LedgerTransaction> items = [];
  int income = 0;
  int expense = 0;

  /// Income minus expense; transfers and non-confirmed rows excluded.
  int get net => income - expense;
}

/// Groups rows (already sorted newest first) by local day, keeping order.
/// Only confirmed income/expense count toward the day totals.
List<DayGroup> groupByDay(Iterable<LedgerTransaction> rows) {
  final groups = <DayGroup>[];
  for (final t in rows) {
    final day = dateOnly(t.transactionAt);
    if (groups.isEmpty || groups.last.day != day) groups.add(DayGroup(day));
    final g = groups.last..items.add(t);
    if (t.status != TransactionStatus.confirmed) continue;
    switch (t.type) {
      case TransactionType.income:
        g.income += t.amount;
      case TransactionType.expense:
        g.expense += t.amount;
      case TransactionType.transfer:
        break;
    }
  }
  return groups;
}
