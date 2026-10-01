import '../../../core/formatting/dates.dart';

/// Monthly contributions left before [targetDate], counting the month of
/// [now] through the target month (15 Sep → 31 Dec = 4). Null when the
/// target date has already passed.
int? contributionMonthsLeft(DateTime now, DateTime targetDate) {
  if (dateOnly(targetDate).isBefore(dateOnly(now))) return null;
  return (targetDate.year - now.year) * 12 + targetDate.month - now.month + 1;
}

/// Monthly amount needed to reach [target] by [targetDate], rounded up to
/// whole rupiah. 0 when already reached; null without a target date or when
/// the target date has passed.
int? requiredMonthlyContribution({
  required int current,
  required int target,
  required DateTime? targetDate,
  required DateTime now,
}) {
  if (targetDate == null) return null;
  final remaining = target - current;
  if (remaining <= 0) return 0;
  final months = contributionMonthsLeft(now, targetDate);
  if (months == null) return null;
  return (remaining + months - 1) ~/ months;
}
