import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/dates.dart';

/// Transactions of one calendar day with that day's totals.
class DayGroup {
  DayGroup(this.day);

  final DateTime day;
  final List<LedgerTransaction> items = [];

  /// Confirmed income/expense of the day in rupiah (rows on non-IDR accounts
  /// converted at their account's manual kurs).
  int income = 0;
  int expense = 0;

  /// Income minus expense; transfers and non-confirmed rows excluded.
  int get net => income - expense;
}

/// Converter from a row's native minor-unit amount to rupiah using its
/// account's currency ([accounts], by id) and manual kurs ([rates], by code).
/// Unknown accounts count as IDR.
int Function(LedgerTransaction) idrConverter(Map<String, Account> accounts, Map<String, double> rates) {
  return (t) {
    final code = accounts[t.accountId]?.currency ?? 'IDR';
    return toIdr(t.amount, Currency.fromCode(code), rates[code.toUpperCase()]);
  };
}

/// Groups rows (already sorted newest first) by local day, keeping order.
/// Only confirmed income/expense count toward the day totals, summed in
/// rupiah via [idrOf] (defaults to the raw amount, i.e. all-IDR rows).
List<DayGroup> groupByDay(Iterable<LedgerTransaction> rows, {int Function(LedgerTransaction)? idrOf}) {
  final groups = <DayGroup>[];
  for (final t in rows) {
    final day = dateOnly(t.transactionAt);
    if (groups.isEmpty || groups.last.day != day) groups.add(DayGroup(day));
    final g = groups.last..items.add(t);
    if (t.status != TransactionStatus.confirmed) continue;
    final amount = idrOf == null ? t.amount : idrOf(t);
    switch (t.type) {
      case TransactionType.income:
        g.income += amount;
      case TransactionType.expense:
        g.expense += amount;
      case TransactionType.transfer:
        break;
    }
  }
  return groups;
}
