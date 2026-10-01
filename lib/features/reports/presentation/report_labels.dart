import '../../../core/formatting/dates.dart';
import '../domain/report_shaping.dart';

/// Title of a report period: `September 2026` or `2026`.
String periodTitle(ReportScope scope, DateTime anchor) =>
    scope == ReportScope.monthly ? formatMonth(anchor) : '${anchor.year}';

/// Caption naming the comparison period, e.g. `vs Agustus 2026`,
/// `vs 2025`, or `vs 1 Agu–15 Agu 2026` when the current period is partial.
String comparisonCaption(Period previous, ReportScope scope, {required bool partial}) {
  if (partial) {
    final last = DateTime(previous.end.year, previous.end.month, previous.end.day - 1);
    return 'vs ${formatDayShort(previous.start)}–${formatDay(last)}';
  }
  return 'vs ${periodTitle(scope, previous.start)}';
}
