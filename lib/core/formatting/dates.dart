import 'package:intl/intl.dart';

/// Call once at startup (main) before using Indonesian date formats.
const appLocale = 'id_ID';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime monthStart(DateTime d) => DateTime(d.year, d.month);

/// Last calendar day of the month of [d].
DateTime monthEnd(DateTime d) => DateTime(d.year, d.month + 1, 0);

/// Exclusive upper bound: first moment of the next month.
DateTime nextMonthStart(DateTime d) => DateTime(d.year, d.month + 1);

DateTime addMonths(DateTime d, int months) {
  final target = DateTime(d.year, d.month + months);
  final lastDay = monthEnd(target).day;
  return DateTime(target.year, target.month, d.day > lastDay ? lastDay : d.day);
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Inclusive-exclusive local period.
class Period {
  const Period(this.start, this.end);

  factory Period.month(DateTime anyDay) =>
      Period(monthStart(anyDay), nextMonthStart(anyDay));

  factory Period.year(int year) => Period(DateTime(year), DateTime(year + 1));

  /// [count] completed months ending before the month of [reference].
  factory Period.completedMonths(DateTime reference, int count) =>
      Period(DateTime(reference.year, reference.month - count), monthStart(reference));

  final DateTime start;
  final DateTime end;

  Period previousMonth() => Period.month(DateTime(start.year, start.month - 1));

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  @override
  bool operator ==(Object other) =>
      other is Period && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

final _day = DateFormat('d MMM yyyy', appLocale);
final _dayShort = DateFormat('d MMM', appLocale);
final _month = DateFormat('MMMM yyyy', appLocale);
final _monthShort = DateFormat('MMM', appLocale);
final _time = DateFormat('HH:mm', appLocale);
final _weekday = DateFormat('EEEE, d MMM', appLocale);

String formatDay(DateTime d) => _day.format(d);
String formatDayShort(DateTime d) => _dayShort.format(d);
String formatMonth(DateTime d) => _month.format(d);
String formatMonthShort(DateTime d) => _monthShort.format(d);
String formatTime(DateTime d) => _time.format(d);
String formatWeekday(DateTime d) => _weekday.format(d);

/// `Terlambat 2 hari`, `Hari ini`, `Besok`, `H-5`.
String dueLabel(DateTime due, DateTime today) {
  final days = dateOnly(due).difference(dateOnly(today)).inDays;
  if (days < 0) return 'Terlambat ${-days} hari';
  if (days == 0) return 'Hari ini';
  if (days == 1) return 'Besok';
  return 'H-$days';
}
