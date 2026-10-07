import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/finance/finance_service.dart';
import 'package:finbro_app/core/formatting/dates.dart';
import 'package:finbro_app/core/formatting/money.dart';
import 'package:finbro_app/features/reports/domain/report_shaping.dart';
import 'package:flutter_test/flutter_test.dart';

CategoryAmount cat(String id, int amount, {String? name}) =>
    CategoryAmount(categoryId: id, name: name ?? id, icon: null, amount: amount, share: 0);

void main() {
  group('groupSpending', () {
    test('keeps the 4 largest and groups the rest into Other', () {
      final slices = groupSpending([
        cat('e', 50000),
        cat('a', 400000),
        cat('b', 300000),
        cat('c', 150000),
        cat('d', 100000),
      ]);
      expect(slices.map((s) => s.label), ['a', 'b', 'c', 'd', 'Other']);
      expect(slices.last.amount, 50000);
      expect(slices.last.isOther, isTrue);
      expect(slices.first.share, closeTo(40, 1e-9));
      expect(slices.fold<double>(0, (s, e) => s + e.share), closeTo(100, 1e-9));
    });

    test('categories below the minimum share join Other even with free slots', () {
      final slices = groupSpending([cat('a', 980000), cat('b', 10000), cat('c', 10000)]);
      expect(slices.map((s) => s.label), ['a', 'Other']);
      expect(slices.last.amount, 20000);
    });

    test('system Other category is folded into the grouped slice', () {
      final slices = groupSpending([
        cat('a', 500000),
        cat(SystemCategories.otherExpense, 300000, name: 'Other'),
        cat('b', 200000),
      ]);
      expect(slices.map((s) => s.label), ['a', 'b', 'Other']);
      expect(slices.last.amount, 300000);
      expect(slices.where((s) => s.label == 'Other'), hasLength(1));
    });

    test('no Other slice when everything fits; empty for zero spending', () {
      expect(groupSpending([cat('a', 1), cat('b', 1)]).map((s) => s.label), ['a', 'b']);
      expect(groupSpending([]), isEmpty);
      expect(groupSpending([cat('a', 0)]), isEmpty);
    });
  });

  group('cumulativeDaily', () {
    final sep = Period.month(DateTime(2026, 9, 10));

    test('running totals carry over days without transactions', () {
      final points = cumulativeDaily({
        DateTime(2026, 9, 1): const PeriodSummary(income: 5000000, expense: 0),
        DateTime(2026, 9, 3): const PeriodSummary(income: 0, expense: 200000),
        DateTime(2026, 9, 5): const PeriodSummary(income: 100000, expense: 50000),
      }, sep, until: DateTime(2026, 9, 5, 18));
      expect(points, hasLength(5));
      expect([for (final p in points) p.income], [5000000, 5000000, 5000000, 5000000, 5100000]);
      expect([for (final p in points) p.expense], [0, 0, 200000, 200000, 250000]);
      expect(points.last.net, 4850000);
      expect(points.last.day, DateTime(2026, 9, 5));
    });

    test('without until covers the whole month; until before start is empty', () {
      expect(cumulativeDaily(const {}, sep), hasLength(30));
      expect(cumulativeDaily(const {}, sep, until: DateTime(2026, 8, 31)), isEmpty);
      expect(cumulativeDaily(const {}, sep, until: DateTime(2026, 12, 1)), hasLength(30));
    });
  });

  group('previousComparable', () {
    test('month in progress compares with the same elapsed days of last month', () {
      final p = previousComparable(Period.month(DateTime(2026, 9)), ReportScope.monthly, DateTime(2026, 9, 15, 20));
      expect(p, Period(DateTime(2026, 8, 1), DateTime(2026, 8, 16)));
    });

    test('elapsed day is clamped to the shorter previous month', () {
      final p = previousComparable(Period.month(DateTime(2026, 3)), ReportScope.monthly, DateTime(2026, 3, 31));
      expect(p, Period(DateTime(2026, 2, 1), DateTime(2026, 3, 1)));
    });

    test('finished month compares with the whole previous month (across years)', () {
      final p = previousComparable(Period.month(DateTime(2026, 1)), ReportScope.monthly, DateTime(2026, 9, 30));
      expect(p, Period(DateTime(2025, 12, 1), DateTime(2026, 1, 1)));
    });

    test('year in progress compares year-to-date; past year compares full year', () {
      final ytd = previousComparable(Period.year(2026), ReportScope.yearly, DateTime(2026, 9, 30));
      expect(ytd, Period(DateTime(2025, 1, 1), DateTime(2025, 10, 1)));
      // 29 Feb has no counterpart in 2023: clamp to 28 Feb.
      final leap = previousComparable(Period.year(2024), ReportScope.yearly, DateTime(2024, 2, 29));
      expect(leap, Period(DateTime(2023, 1, 1), DateTime(2023, 3, 1)));
      final full = previousComparable(Period.year(2025), ReportScope.yearly, DateTime(2026, 9, 30));
      expect(full, Period(DateTime(2024), DateTime(2025)));
    });
  });

  test('scope periods and shifting', () {
    expect(ReportScope.monthly.periodFor(DateTime(2026, 9, 30)), Period.month(DateTime(2026, 9)));
    expect(ReportScope.yearly.periodFor(DateTime(2026, 9, 30)), Period.year(2026));
    expect(ReportScope.monthly.shift(DateTime(2026, 1), -1), DateTime(2025, 12));
    expect(ReportScope.yearly.shift(DateTime(2026), 1), DateTime(2027));
  });

  group('change labels', () {
    test('percent change shows sign and N/A for missing previous', () {
      expect(formatChange(null), 'N/A');
      expect(formatChange(12.4), '+12%');
      expect(formatChange(-5.2), '-5%');
      expect(formatChange(-0.3), '0%');
    });

    test('savings rate change in percentage points', () {
      expect(formatPointChange(20, null), 'N/A');
      expect(formatPointChange(null, 10), 'N/A');
      expect(formatPointChange(23.5, 20), '+3,5 pp');
      expect(formatPointChange(15, 20), '-5,0 pp');
      expect(formatPointChange(20.01, 20), '0 pp');
    });

    test('coverage months use Indonesian decimals', () {
      expect(formatMonths(3.5), '3,5 bulan');
      expect(formatMonths(3), '3 bulan');
      expect(formatMonths(0.04), '0 bulan');
    });
  });

  test('niceAxisMax rounds up to a readable axis bound', () {
    expect(niceAxisMax(0), 1);
    expect(niceAxisMax(-5), 1);
    expect(niceAxisMax(4820000), 5000000);
    expect(niceAxisMax(2100000), 2500000);
    expect(niceAxisMax(1000000), 1000000);
    expect(niceAxisMax(7), 10);
  });
}
