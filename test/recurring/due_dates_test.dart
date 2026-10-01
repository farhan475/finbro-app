import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/features/recurring/domain/due_dates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monthly on the 31st clamps to the last day of shorter months', () {
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.monthly,
      startDate: DateTime(2026, 8, 1),
      dayOfMonth: 31,
    );
    expect(spec.occurrences(DateTime(2026, 8, 1), DateTime(2027, 3, 31)), [
      DateTime(2026, 8, 31),
      DateTime(2026, 9, 30),
      DateTime(2026, 10, 31),
      DateTime(2026, 11, 30),
      DateTime(2026, 12, 31),
      DateTime(2027, 1, 31),
      DateTime(2027, 2, 28),
      DateTime(2027, 3, 31),
    ]);
  });

  test('monthly does not emit dates before the start date', () {
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.monthly,
      startDate: DateTime(2026, 9, 26),
      dayOfMonth: 25,
    );
    expect(spec.occurrences(DateTime(2026, 9, 1), DateTime(2026, 11, 30)), [
      DateTime(2026, 10, 25),
      DateTime(2026, 11, 25),
    ]);
  });

  test('weekly repeats on the chosen weekday', () {
    // 30 Sep 2026 is a Wednesday; rule runs on Mondays.
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.weekly,
      startDate: DateTime(2026, 9, 30),
      dayOfWeek: DateTime.monday,
    );
    expect(spec.occurrences(DateTime(2026, 9, 1), DateTime(2026, 10, 26)), [
      DateTime(2026, 10, 5),
      DateTime(2026, 10, 12),
      DateTime(2026, 10, 19),
      DateTime(2026, 10, 26),
    ]);
  });

  test('yearly on 29 Feb falls back to 28 Feb in non-leap years', () {
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.yearly,
      startDate: DateTime(2028, 1, 1),
      monthOfYear: 2,
      dayOfMonth: 29,
    );
    expect(spec.occurrences(DateTime(2028, 1, 1), DateTime(2032, 12, 31)), [
      DateTime(2028, 2, 29),
      DateTime(2029, 2, 28),
      DateTime(2030, 2, 28),
      DateTime(2031, 2, 28),
      DateTime(2032, 2, 29),
    ]);
  });

  test('custom interval counts from the start date, also mid-range', () {
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.custom,
      startDate: DateTime(2026, 9, 1),
      intervalDays: 14,
    );
    expect(spec.occurrences(DateTime(2026, 9, 2), DateTime(2026, 10, 27)), [
      DateTime(2026, 9, 15),
      DateTime(2026, 9, 29),
      DateTime(2026, 10, 13),
      DateTime(2026, 10, 27),
    ]);
    expect(spec.nextOnOrAfter(DateTime(2026, 10, 14)), DateTime(2026, 10, 27));
  });

  test('end date is inclusive and stops generation', () {
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.monthly,
      startDate: DateTime(2026, 1, 10),
      endDate: DateTime(2026, 3, 10),
      dayOfMonth: 10,
    );
    expect(spec.occurrences(DateTime(2026, 1, 1), DateTime(2026, 12, 31)), [
      DateTime(2026, 1, 10),
      DateTime(2026, 2, 10),
      DateTime(2026, 3, 10),
    ]);
    expect(spec.nextOnOrAfter(DateTime(2026, 3, 11)), isNull);
  });

  test('next due on or after a date', () {
    final spec = RecurrenceSpec(
      frequency: RecurringFrequency.monthly,
      startDate: DateTime(2026, 1, 1),
      dayOfMonth: 31,
    );
    expect(spec.nextOnOrAfter(DateTime(2026, 9, 30)), DateTime(2026, 9, 30));
    expect(spec.nextOnOrAfter(DateTime(2026, 10, 1)), DateTime(2026, 10, 31));
    final yearly = RecurrenceSpec(
      frequency: RecurringFrequency.yearly,
      startDate: DateTime(2026, 1, 1),
      monthOfYear: 1,
      dayOfMonth: 15,
    );
    expect(yearly.nextOnOrAfter(DateTime(2026, 1, 16)), DateTime(2027, 1, 15));
  });
}
