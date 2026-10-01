import '../../../core/database/app_database.dart';

/// Indonesian day/month names (kept local so pure code needs no intl init).
const weekdayNames = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
const weekdayShort = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
const monthNames = [
  'Januari',
  'Februari',
  'Maret',
  'April',
  'Mei',
  'Juni',
  'Juli',
  'Agustus',
  'September',
  'Oktober',
  'November',
  'Desember',
];

/// Date `y-m-d` with [day] clamped to the month's last day
/// (31 → 30 Sep, 29 Feb → 28 Feb in non-leap years).
DateTime clampedDate(int year, int month, int day) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > last ? last : day);
}

/// Whole calendar days from [a] to [b] (DST-safe).
int daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

DateTime _addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

DateTime _maxDate(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

DateTime _minDate(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

/// Schedule of a recurring rule. Missing fields fall back to the start date
/// (e.g. weekly without day_of_week repeats on the start date's weekday).
class RecurrenceSpec {
  RecurrenceSpec({
    required this.frequency,
    required DateTime startDate,
    DateTime? endDate,
    int? dayOfWeek,
    int? dayOfMonth,
    int? monthOfYear,
    int? intervalDays,
  }) : startDate = DateTime(startDate.year, startDate.month, startDate.day),
       endDate = endDate == null ? null : DateTime(endDate.year, endDate.month, endDate.day),
       dayOfWeek = (dayOfWeek ?? startDate.weekday).clamp(1, 7),
       dayOfMonth = (dayOfMonth ?? startDate.day).clamp(1, 31),
       monthOfYear = (monthOfYear ?? startDate.month).clamp(1, 12),
       intervalDays = intervalDays ?? 1;

  factory RecurrenceSpec.fromRule(RecurringRule r) => RecurrenceSpec(
    frequency: r.frequency,
    startDate: r.startDate,
    endDate: r.endDate,
    dayOfWeek: r.dayOfWeek,
    dayOfMonth: r.dayOfMonth,
    monthOfYear: r.monthOfYear,
    intervalDays: r.intervalDays,
  );

  final RecurringFrequency frequency;
  final DateTime startDate;
  final DateTime? endDate;

  /// 1 = Monday … 7 = Sunday.
  final int dayOfWeek;
  final int dayOfMonth;
  final int monthOfYear;
  final int intervalDays;

  /// Due dates within `[from, to]` (inclusive, date-only), bounded by the
  /// rule's start and end dates, in ascending order.
  List<DateTime> occurrences(DateTime from, DateTime to) {
    var lo = _maxDate(DateTime(from.year, from.month, from.day), startDate);
    var hi = DateTime(to.year, to.month, to.day);
    if (endDate != null) hi = _minDate(hi, endDate!);
    if (lo.isAfter(hi)) return const [];
    final out = <DateTime>[];
    switch (frequency) {
      case RecurringFrequency.weekly:
        var d = _addDays(lo, (dayOfWeek - lo.weekday + 7) % 7);
        while (!d.isAfter(hi)) {
          out.add(d);
          d = _addDays(d, 7);
        }
      case RecurringFrequency.monthly:
        var y = lo.year;
        var m = lo.month;
        while (true) {
          final d = clampedDate(y, m, dayOfMonth);
          if (d.isAfter(hi)) break;
          if (!d.isBefore(lo)) out.add(d);
          m++;
          if (m > 12) {
            m = 1;
            y++;
          }
        }
      case RecurringFrequency.yearly:
        for (var y = lo.year;; y++) {
          final d = clampedDate(y, monthOfYear, dayOfMonth);
          if (d.isAfter(hi)) break;
          if (!d.isBefore(lo)) out.add(d);
        }
      case RecurringFrequency.custom:
        if (intervalDays < 1) return const [];
        final offset = daysBetween(startDate, lo);
        var k = (offset + intervalDays - 1) ~/ intervalDays;
        while (true) {
          final d = _addDays(startDate, k * intervalDays);
          if (d.isAfter(hi)) break;
          out.add(d);
          k++;
        }
    }
    return out;
  }

  /// First due date on or after [day], or null when the rule has ended.
  DateTime? nextOnOrAfter(DateTime day) {
    // One full cycle of the longest frequency (yearly, incl. Feb 29 clamp)
    // always contains an occurrence unless the end date intervenes.
    final span = switch (frequency) {
      RecurringFrequency.weekly => 7,
      RecurringFrequency.monthly => 62,
      RecurringFrequency.yearly => 366 * 2,
      RecurringFrequency.custom => intervalDays + 1,
    };
    final lo = _maxDate(DateTime(day.year, day.month, day.day), startDate);
    final list = occurrences(lo, _addDays(lo, span));
    return list.isEmpty ? null : list.first;
  }

  /// Human description, e.g. "Setiap tanggal 25", "Setiap Senin".
  String describe() => switch (frequency) {
    RecurringFrequency.weekly => 'Setiap ${weekdayNames[dayOfWeek - 1]}',
    RecurringFrequency.monthly =>
      dayOfMonth >= 29 ? 'Setiap tanggal $dayOfMonth (atau akhir bulan)' : 'Setiap tanggal $dayOfMonth',
    RecurringFrequency.yearly => 'Setiap $dayOfMonth ${monthNames[monthOfYear - 1]}',
    RecurringFrequency.custom => intervalDays == 1 ? 'Setiap hari' : 'Setiap $intervalDays hari',
  };
}
