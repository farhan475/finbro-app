/// Date and clock-time extraction for Indonesian receipts and screenshots.
library;

import 'scan_models.dart';

/// A date found in a line.
class DateMatch {
  const DateMatch(this.date, this.start, this.end, this.confidence);

  /// Local midnight.
  final DateTime date;
  final int start;
  final int end;
  final FieldConfidence confidence;

  @override
  String toString() => 'DateMatch($date, ${confidence.name})';
}

class TimeMatch {
  const TimeMatch(this.time, this.start, this.end, {required this.colon});
  final ClockTime time;
  final int start;
  final int end;

  /// `14:32` (true) vs `14.32` (false, weaker evidence).
  final bool colon;
}

const _monthNames = {
  'januari': 1, 'january': 1, 'jan': 1,
  'februari': 2, 'pebruari': 2, 'february': 2, 'feb': 2, 'peb': 2,
  'maret': 3, 'march': 3, 'mar': 3,
  'april': 4, 'apr': 4,
  'mei': 5, 'may': 5,
  'juni': 6, 'june': 6, 'jun': 6,
  'juli': 7, 'july': 7, 'jul': 7,
  'agustus': 8, 'august': 8, 'agu': 8, 'agt': 8, 'ags': 8, 'agus': 8, 'aug': 8,
  'september': 9, 'sept': 9, 'sep': 9,
  'oktober': 10, 'october': 10, 'okt': 10, 'oct': 10,
  'november': 11, 'nopember': 11, 'nov': 11, 'nop': 11,
  'desember': 12, 'december': 12, 'des': 12, 'dec': 12,
};

/// Month number for an Indonesian/English month name or abbreviation.
int? monthFromName(String token) {
  final t = token.toLowerCase().replaceAll('.', '');
  final exact = _monthNames[t];
  if (exact != null) return exact;
  if (t.length < 3) return null;
  final hits = {
    for (final e in _monthNames.entries)
      if (e.key.length > 3 && e.key.startsWith(t)) e.value,
  };
  return hits.length == 1 ? hits.first : null;
}

final _isoDate = RegExp(r'(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)');
final _numericDate = RegExp(r'(?<![\d.,])(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?![\d])');
final _namedDate = RegExp(
  r'(?<![A-Za-z\d])(\d{1,2})[\s\-/.]*([A-Za-z]{3,10})\.?[\s\-/.,]*(\d{4}|\d{2})(?![\d.:])',
);
final _monthFirstDate = RegExp(
  r'(?<![A-Za-z])([A-Za-z]{3,10})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)',
);
final _dayMonthBeforeTime = RegExp(
  r'(?<![\d/.,-])(\d{1,2})/(\d{1,2})(?![\d/])(?=,?\s+\d{1,2}[:.]\d{2})',
);
final _colonTime = RegExp(r'(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?![\d:])');
final _dotTime = RegExp(r'(?<![\d.,])([01]?\d|2[0-3])\.([0-5]\d)(?:\.([0-5]\d))?(?![\d.,])');
final _timeHint = RegExp(r'\b(wib|wita|wit|jam|pukul|waktu|time)\b', caseSensitive: false);

/// All dates in [line], left to right. [now] anchors 2-digit / missing years
/// and the plausibility check (future or very old dates get low confidence).
List<DateMatch> findDates(String line, {required DateTime now}) {
  final out = <DateMatch>[];
  bool overlaps(int s, int e) => out.any((d) => s < d.end && e > d.start);
  void add(int s, int e, int y, int m, int d, FieldConfidence base) {
    if (overlaps(s, e)) return;
    final date = _validDate(y, m, d);
    if (date == null) return;
    out.add(DateMatch(date, s, e, _plausibility(date, now, base)));
  }

  for (final m in _isoDate.allMatches(line)) {
    add(m.start, m.end, int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), FieldConfidence.high);
  }
  for (final m in _numericDate.allMatches(line)) {
    var a = int.parse(m[1]!);
    var b = int.parse(m[2]!);
    final yRaw = m[3]!;
    var base = yRaw.length == 4 ? FieldConfidence.high : FieldConfidence.medium;
    // Indonesian order is day/month; only a month > 12 forces US order.
    if (b > 12 && a <= 12) {
      final t = a;
      a = b;
      b = t;
      base = FieldConfidence.medium;
    }
    add(m.start, m.end, _year(yRaw), b, a, base);
  }
  for (final m in _namedDate.allMatches(line)) {
    final month = monthFromName(m[2]!);
    if (month == null) continue;
    final yRaw = m[3]!;
    add(m.start, m.end, _year(yRaw), month, int.parse(m[1]!),
        yRaw.length == 4 ? FieldConfidence.high : FieldConfidence.medium);
  }
  for (final m in _monthFirstDate.allMatches(line)) {
    final month = monthFromName(m[1]!);
    if (month == null) continue;
    add(m.start, m.end, int.parse(m[3]!), month, int.parse(m[2]!), FieldConfidence.high);
  }
  for (final m in _dayMonthBeforeTime.allMatches(line)) {
    final d = int.parse(m[1]!);
    final mo = int.parse(m[2]!);
    // No year printed (e.g. m-BCA "25/09 14:32"): assume the most recent
    // occurrence that is not in the future.
    var y = now.year;
    final candidate = _validDate(y, mo, d);
    if (candidate != null && candidate.isAfter(now.add(const Duration(days: 1)))) y--;
    add(m.start, m.end, y, mo, d, FieldConfidence.medium);
  }
  final lower = line.toLowerCase();
  if (out.isEmpty) {
    final today = RegExp(r'\b(hari ini|today)\b').firstMatch(lower);
    final yesterday = RegExp(r'\b(kemarin|yesterday)\b').firstMatch(lower);
    final base = DateTime(now.year, now.month, now.day);
    if (today != null) {
      out.add(DateMatch(base, today.start, today.end, FieldConfidence.medium));
    } else if (yesterday != null) {
      out.add(DateMatch(
        DateTime(now.year, now.month, now.day - 1),
        yesterday.start,
        yesterday.end,
        FieldConfidence.medium,
      ));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Clock time in [line]. `HH.mm` is accepted only when [allowDot] or the line
/// carries a date / time hint (WIB, jam, pukul, waktu), because `14.30` can
/// otherwise be a number.
TimeMatch? findTime(String line, {bool allowDot = false, DateTime? now}) {
  final masked = _maskDatesOnly(line, now ?? DateTime(2000));
  final colon = _colonTime.firstMatch(masked);
  if (colon != null) {
    return TimeMatch(ClockTime(int.parse(colon[1]!), int.parse(colon[2]!)), colon.start, colon.end,
        colon: true);
  }
  final dotAllowed = allowDot || _timeHint.hasMatch(line) || masked != line;
  if (!dotAllowed) return null;
  for (final m in _dotTime.allMatches(masked)) {
    final before = masked.substring(0, m.start).trimRight();
    if (before.endsWith('Rp') || before.endsWith('IDR')) continue;
    return TimeMatch(ClockTime(int.parse(m[1]!), int.parse(m[2]!)), m.start, m.end, colon: false);
  }
  return null;
}

/// Replaces dates and clock times with spaces (same length) so amount
/// extraction never reads `25.09.2026` or `14:30` as money.
String maskDatesAndTimes(String line) {
  var s = _maskDatesOnly(line, DateTime(2000));
  s = s.replaceAllMapped(_colonTime, (m) => ' ' * m[0]!.length);
  if (_timeHint.hasMatch(line) || s != line) {
    s = s.replaceAllMapped(_dotTime, (m) {
      final before = s.substring(0, m.start).trimRight();
      if (before.endsWith('Rp') || before.endsWith('IDR')) return m[0]!;
      return ' ' * m[0]!.length;
    });
  }
  return s;
}

String _maskDatesOnly(String line, DateTime now) {
  final dates = findDates(line, now: now);
  if (dates.isEmpty) return line;
  final chars = line.split('');
  for (final d in dates) {
    for (var i = d.start; i < d.end; i++) {
      chars[i] = ' ';
    }
  }
  return chars.join();
}

int _year(String raw) => raw.length == 2 ? 2000 + int.parse(raw) : int.parse(raw);

DateTime? _validDate(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1990 || y > 2100) return null;
  final date = DateTime(y, m, d);
  if (date.month != m || date.day != d) return null;
  return date;
}

FieldConfidence _plausibility(DateTime date, DateTime now, FieldConfidence base) {
  final today = DateTime(now.year, now.month, now.day);
  if (date.isAfter(today.add(const Duration(days: 1)))) return FieldConfidence.low;
  if (date.isBefore(DateTime(today.year - 5, today.month, today.day))) return FieldConfidence.low;
  if (date.isBefore(DateTime(today.year - 1, today.month, today.day)) &&
      base == FieldConfidence.high) {
    return FieldConfidence.medium;
  }
  return base;
}

/// Range of transaction dates a scan may propose: the review's date picker
/// bounds. OCR misreads such as `12/05/98` → 2098 fall outside and are
/// dropped instead of becoming the transaction date.
final scanFirstDate = DateTime(2000);

DateTime scanLastDate(DateTime now) => DateTime(now.year, now.month, now.day + 365);

bool _inScanRange(DateTime date, DateTime now) =>
    !date.isBefore(scanFirstDate) && !date.isAfter(scanLastDate(now));

/// Picks the transaction date/time from normalized [lines]. Lines with a
/// date keyword win; expiry/due/birth dates are ignored.
({Extracted<DateTime> date, Extracted<ClockTime> time}) pickDateTime(
  List<String> lines, {
  required DateTime now,
}) {
  const ignore = ['exp', 'berlaku', 's/d', 'valid', 'jatuh tempo', 'lahir', 'kadaluarsa', 'expired'];
  final keyword = RegExp(r'\b(tanggal|tgl|date|waktu|time|dibuat|transaksi)\b', caseSensitive: false);
  DateMatch? best;
  int? bestLine;
  var bestHasKeyword = false;
  for (var i = 0; i < lines.length; i++) {
    final lower = lines[i].toLowerCase();
    if (ignore.any(lower.contains)) continue;
    final dates = [for (final d in findDates(lines[i], now: now)) if (_inScanRange(d.date, now)) d];
    if (dates.isEmpty) continue;
    final hasKeyword = keyword.hasMatch(lines[i]);
    if (best == null || (hasKeyword && !bestHasKeyword)) {
      best = dates.first;
      bestLine = i;
      bestHasKeyword = hasKeyword;
    }
  }

  TimeMatch? time;
  if (bestLine != null) {
    time = findTime(lines[bestLine], allowDot: true, now: now);
    // Date and time are often on adjacent lines ("Tanggal …" / "Waktu …").
    if (time == null && bestLine + 1 < lines.length) {
      final next = lines[bestLine + 1];
      if (findDates(next, now: now).isEmpty) time = findTime(next, now: now);
    }
  }
  if (time == null) {
    for (final l in lines) {
      if (_timeHint.hasMatch(l)) {
        time = findTime(l, now: now);
        if (time != null) break;
      }
    }
  }
  if (time == null) {
    for (final l in lines) {
      time = findTime(l, now: now);
      if (time != null && time.colon) break;
      time = null;
    }
  }
  return (
    date: best == null ? const Extracted.none() : Extracted(best.date, best.confidence),
    time: time == null
        ? const Extracted.none()
        : Extracted(time.time, time.colon ? FieldConfidence.high : FieldConfidence.medium),
  );
}
