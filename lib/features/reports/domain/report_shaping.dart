// Pure data shaping for dashboard/report charts. No I/O, no widgets.

import 'dart:math' as math;

import '../../../core/database/seed.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';

/// One donut slice. [categoryId] is null for the grouped `Other` slice.
class DonutSlice {
  const DonutSlice({
    required this.label,
    required this.amount,
    required this.share,
    this.categoryId,
    this.icon,
  });

  final String label;
  final int amount;

  /// Percent of the total (0–100).
  final double share;
  final String? categoryId;
  final String? icon;

  bool get isOther => categoryId == null;
}

/// Groups spending into at most [maxSlices] named slices plus one `Other`
/// slice (06-ux §8: keep slices limited, group tiny categories into Other).
///
/// A category is shown by name only if it is among the [maxSlices] largest
/// and its share is at least [minShare] percent. The system "Other" expense
/// category ([otherCategoryId]) is always folded into the grouped slice so
/// the donut never shows two "Other" entries. Shares are recomputed from the
/// integer amounts; non-positive amounts are ignored.
List<DonutSlice> groupSpending(
  List<CategoryAmount> items, {
  int maxSlices = 4,
  double minShare = 3,
  String otherLabel = 'Other',
  String? otherCategoryId = SystemCategories.otherExpense,
}) {
  final positive = [for (final i in items) if (i.amount > 0) i]
    ..sort((a, b) => b.amount.compareTo(a.amount));
  final total = positive.fold<int>(0, (s, i) => s + i.amount);
  if (total == 0) return const [];

  double shareOf(int amount) => ratioPercent(amount, total)!;

  final out = <DonutSlice>[];
  var rest = 0;
  for (final i in positive) {
    final named = i.categoryId != otherCategoryId &&
        out.length < maxSlices &&
        shareOf(i.amount) >= minShare;
    if (named) {
      out.add(DonutSlice(
        label: i.name,
        amount: i.amount,
        share: shareOf(i.amount),
        categoryId: i.categoryId,
        icon: i.icon,
      ));
    } else {
      rest += i.amount;
    }
  }
  if (rest > 0) {
    out.add(DonutSlice(label: otherLabel, amount: rest, share: shareOf(rest)));
  }
  return out;
}

/// Running totals for one day of a cash-flow line chart.
class CashFlowPoint {
  const CashFlowPoint(this.day, this.income, this.expense);
  final DateTime day;

  /// Cumulative confirmed income from the period start through [day].
  final int income;

  /// Cumulative confirmed expense from the period start through [day].
  final int expense;

  int get net => income - expense;
}

/// Cumulative income/expense per day of [period], from its first day through
/// [until] (inclusive, clamped to the period). Days without transactions
/// repeat the previous running total so the lines stay continuous.
/// Returns an empty list when [until] is before the period start.
List<CashFlowPoint> cumulativeDaily(
  Map<DateTime, PeriodSummary> daily,
  Period period, {
  DateTime? until,
}) {
  final byDay = {for (final e in daily.entries) dateOnly(e.key): e.value};
  final last = until == null ? null : dateOnly(until);
  final out = <CashFlowPoint>[];
  var income = 0;
  var expense = 0;
  for (var d = dateOnly(period.start);
      d.isBefore(period.end) && (last == null || !d.isAfter(last));
      d = DateTime(d.year, d.month, d.day + 1)) {
    final s = byDay[d];
    if (s != null) {
      income += s.income;
      expense += s.expense;
    }
    out.add(CashFlowPoint(d, income, expense));
  }
  return out;
}

/// Report granularity: Bulanan / Tahunan.
enum ReportScope {
  monthly('Bulanan'),
  yearly('Tahunan');

  const ReportScope(this.label);
  final String label;

  /// Calendar month or year containing [anchor].
  Period periodFor(DateTime anchor) => switch (this) {
    ReportScope.monthly => Period.month(anchor),
    ReportScope.yearly => Period.year(anchor.year),
  };

  /// Anchor of the neighbouring period ([step] = -1 previous, +1 next).
  DateTime shift(DateTime anchor, int step) => switch (this) {
    ReportScope.monthly => DateTime(anchor.year, anchor.month + step),
    ReportScope.yearly => DateTime(anchor.year + step),
  };
}

/// The period a report compares [current] against (03 §17 "previous
/// comparable period").
///
/// A finished period (or a future one) is compared with the whole previous
/// month/year. A period still in progress at [now] is compared with the same
/// elapsed span of the previous month/year (e.g. 1–15 Sep vs 1–15 Aug), with
/// the day clamped to the length of the previous month.
Period previousComparable(Period current, ReportScope scope, DateTime now) {
  final prevStart = scope.shift(current.start, -1);
  if (!current.contains(now)) return Period(prevStart, current.start);
  final month = scope == ReportScope.monthly ? prevStart.month : now.month;
  final lastDay = monthEnd(DateTime(prevStart.year, month)).day;
  final end = DateTime(prevStart.year, month, math.min(now.day, lastDay) + 1);
  return Period(prevStart, end);
}

/// Signed percent change label: `+12%`, `-5%`, `0%`, or `N/A` when there is
/// no previous value (03 §17: never show a fake percentage).
String formatChange(double? percent) {
  if (percent == null || percent.isNaN || percent.isInfinite) return 'N/A';
  final rounded = percent.round();
  if (rounded == 0) return '0%';
  return '${rounded > 0 ? '+' : ''}${formatPercent(percent)}';
}

/// Difference of two percentages in percentage points (`+3,5 pp`), or `N/A`
/// if either side is unavailable.
String formatPointChange(double? current, double? previous) {
  if (current == null || previous == null) return 'N/A';
  final diff = current - previous;
  if (diff.abs() < 0.05) return '0 pp';
  final text = formatPercent(diff.abs(), decimals: 1).replaceAll('%', ' pp');
  return '${diff > 0 ? '+' : '-'}$text';
}

/// `3,5 bulan`; one decimal, Indonesian separator.
String formatMonths(double months) {
  final text = months.toStringAsFixed(1).replaceAll('.', ',').replaceAll(RegExp(r',0$'), '');
  return '$text bulan';
}

/// A "nice" chart axis maximum ≥ [maxValue] (1, 2, 2.5, 5 × 10^n), so grid
/// lines land on round rupiah values. Returns 1 for non-positive input so a
/// chart with only zero values still has a valid range.
double niceAxisMax(num maxValue) {
  if (maxValue <= 0) return 1;
  final exponent = (math.log(maxValue) / math.ln10).floor();
  final magnitude = math.pow(10, exponent).toDouble();
  for (final step in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (step * magnitude >= maxValue) return step * magnitude;
  }
  return 10 * magnitude;
}
