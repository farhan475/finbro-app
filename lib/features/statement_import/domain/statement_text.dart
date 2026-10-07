/// Number, date and CR/DB marker parsing for Indonesian bank statements.
library;

import '../../scanner/domain/date_time_parser.dart' show monthFromName;
import 'statement_models.dart';

/// A money value read from a statement cell or token.
class ParsedAmount {
  const ParsedAmount(this.value, {this.negative = false, this.marker});

  /// Absolute value in integer rupiah (sen rounded half up).
  final int value;

  /// Written with `-`, trailing `-` or parentheses.
  final bool negative;

  /// CR/DB-style marker written next to the number.
  final StatementDirection? marker;

  /// Direction from the marker, else from the sign; null when unsigned.
  StatementDirection? get direction =>
      marker ?? (negative ? StatementDirection.debit : null);
}

final _markerSuffix = RegExp(
  r'(?:^|(?<=[\d\s).]))(CR|KR|DB|DR|D|K|C|DEBET|DEBIT|KREDIT|CREDIT)\.?$',
  caseSensitive: false,
);
final _markerPrefix = RegExp(r'^(CR|DB|DR|KR)\.?\s+', caseSensitive: false);

/// Direction for a standalone marker cell or token ("CR", "Db.", "K",
/// "Kredit", "debet", "+", "-"); null when it is not a marker.
StatementDirection? parseDirectionMarker(String raw) {
  final t = raw.trim().toUpperCase().replaceAll('.', '');
  switch (t) {
    case 'CR' || 'KR' || 'K' || 'C' || 'KREDIT' || 'CREDIT' || '+' || 'MASUK' || 'UANG MASUK' || 'IN':
      return StatementDirection.credit;
    case 'DB' || 'DR' || 'D' || 'DEBET' || 'DEBIT' || '-' || 'KELUAR' || 'UANG KELUAR' || 'OUT':
      return StatementDirection.debit;
  }
  return null;
}

/// Parses `1.234.567,00`, `1,234,567.00`, `50.000`, `-50,000.00`,
/// `(50.000)`, `Rp 50.000`, `50,000.00 DB`, `1.000.000,00 CR`, `25000`.
/// Returns null for anything else (text, reference numbers with slashes).
///
/// With only one kind of separator, a single separator followed by exactly
/// three digits is a thousands separator (rupiah rarely carry sen), one or
/// two digits are decimals. With both kinds, the last one is the decimal
/// separator.
ParsedAmount? parseStatementAmount(String raw) {
  var s = raw.trim().replaceAll('\u00A0', ' ');
  if (s.isEmpty) return null;
  StatementDirection? marker;
  final suffix = _markerSuffix.firstMatch(s);
  if (suffix != null) {
    marker = parseDirectionMarker(suffix.group(1)!);
    s = s.substring(0, suffix.start).trim();
  } else {
    final prefix = _markerPrefix.firstMatch(s);
    if (prefix != null) {
      marker = parseDirectionMarker(prefix.group(1)!);
      s = s.substring(prefix.end).trim();
    }
  }
  s = s.replaceAll(RegExp(r'^(?:RP|IDR)\.?\s*', caseSensitive: false), '');
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1).trim();
  }
  s = s.replaceAll(RegExp(r'^(?:RP|IDR)\.?\s*', caseSensitive: false), '');
  if (s.startsWith('-')) {
    negative = true;
    s = s.substring(1).trim();
  } else if (s.startsWith('+')) {
    s = s.substring(1).trim();
  } else if (s.endsWith('-')) {
    negative = true;
    s = s.substring(0, s.length - 1).trim();
  }
  s = s.replaceAll(RegExp(r'^(?:RP|IDR)\.?\s*', caseSensitive: false), '').replaceAll(' ', '');
  if (!RegExp(r'^\d[\d.,]*$').hasMatch(s) || RegExp(r'[.,]$').hasMatch(s)) return null;

  final hasDot = s.contains('.');
  final hasComma = s.contains(',');
  String intPart;
  var frac = '';
  if (!hasDot && !hasComma) {
    intPart = s;
  } else if (hasDot && hasComma) {
    final decSep = s.lastIndexOf('.') > s.lastIndexOf(',') ? '.' : ',';
    final thouSep = decSep == '.' ? ',' : '.';
    final at = s.lastIndexOf(decSep);
    frac = s.substring(at + 1);
    intPart = s.substring(0, at);
    if (frac.length > 2 || intPart.contains(decSep) || !_validGroups(intPart, thouSep)) return null;
    intPart = intPart.replaceAll(thouSep, '');
  } else {
    final sep = hasDot ? '.' : ',';
    final count = sep.allMatches(s).length;
    final after = s.length - s.lastIndexOf(sep) - 1;
    if (count == 1 && after <= 2) {
      final at = s.lastIndexOf(sep);
      intPart = s.substring(0, at);
      frac = s.substring(at + 1);
    } else {
      if (!_validGroups(s, sep)) return null;
      intPart = s.replaceAll(sep, '');
    }
  }
  if (intPart.isEmpty || intPart.length > 15) return null;
  var value = int.parse(intPart);
  if (frac.isNotEmpty && int.parse(frac.padRight(2, '0')) >= 50) value += 1;
  return ParsedAmount(value, negative: negative, marker: marker);
}

bool _validGroups(String s, String sep) {
  final parts = s.split(sep);
  if (parts.first.isEmpty || parts.first.length > 3) return false;
  return parts.skip(1).every((p) => p.length == 3);
}

/// A date read from a statement.
class ParsedDate {
  const ParsedDate(this.date, {required this.length, this.hasTime = false});

  /// Local date; includes the time when [hasTime].
  final DateTime date;

  /// Characters consumed from the start of the input.
  final int length;
  final bool hasTime;
}

/// Day/month order of numeric dates. Indonesian banks write day first;
/// generic CSV columns are checked for month-first values.
enum DateOrder { dayFirst, monthFirst }

final _iso = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})');
final _numeric = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?![\d])');
final _numericNoYear = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})(?![\d/\-.,])');
final _named = RegExp(r'^(\d{1,2})[\s\-/]*([A-Za-z]{3,9})\.?[\s\-/,]*(\d{4}|\d{2})(?![\d.,:])');
final _namedNoYear = RegExp(r'^(\d{1,2})[\s\-/]*([A-Za-z]{3,9})\.?(?![A-Za-z])');
// OCR often reads "08:02" as "08: 02"; a space is accepted after ':' only.
final _time = RegExp(r'^(?:\s*,?\s*|T)(\d{1,2})(?::\s?|\.)(\d{2})(?:[:.](\d{2}))?(?![\d])');

/// Reads a date at the start of [raw] (after optional whitespace and the
/// leading apostrophe spreadsheet exports put before `'01/09`):
/// `dd/mm/yyyy`, `dd-mm-yy`, `dd.mm.yyyy`, `yyyy-mm-dd`, `dd MMM yyyy`,
/// `dd-MMM-yy` (Indonesian and English month names), and year-less
/// `dd/mm` / `dd MMM` (year from [yearFor]). An optional `HH:mm[:ss]`
/// right after the date is included.
ParsedDate? parseLeadingDate(
  String raw, {
  DateOrder order = DateOrder.dayFirst,
  int Function(int month, int day)? yearFor,
}) {
  final lead = RegExp(r"^[\s']*").firstMatch(raw)!.end;
  final s = raw.substring(lead);
  int? y, m, d;
  var len = 0;
  RegExpMatch? match;
  if ((match = _iso.firstMatch(s)) != null) {
    y = int.parse(match!.group(1)!);
    m = int.parse(match.group(2)!);
    d = int.parse(match.group(3)!);
  } else if ((match = _numeric.firstMatch(s)) != null) {
    final a = int.parse(match!.group(1)!);
    final b = int.parse(match.group(2)!);
    (d, m) = order == DateOrder.dayFirst ? (a, b) : (b, a);
    y = _fullYear(match.group(3)!);
  } else if ((match = _named.firstMatch(s)) != null && monthFromName(match!.group(2)!) != null) {
    d = int.parse(match.group(1)!);
    m = monthFromName(match.group(2)!);
    y = _fullYear(match.group(3)!);
  } else if (yearFor != null && (match = _numericNoYear.firstMatch(s)) != null) {
    final a = int.parse(match!.group(1)!);
    final b = int.parse(match.group(2)!);
    (d, m) = order == DateOrder.dayFirst ? (a, b) : (b, a);
  } else if (yearFor != null &&
      (match = _namedNoYear.firstMatch(s)) != null &&
      monthFromName(match!.group(2)!) != null) {
    d = int.parse(match.group(1)!);
    m = monthFromName(match.group(2)!);
  } else {
    return null;
  }
  len = match.end;
  if (m == null || m < 1 || m > 12 || d < 1 || d > 31) return null;
  y ??= yearFor!(m, d);
  final date = DateTime(y, m, d);
  if (date.month != m || date.day != d) return null;

  final t = _time.firstMatch(s.substring(len));
  if (t != null) {
    final h = int.parse(t.group(1)!);
    final min = int.parse(t.group(2)!);
    final sec = int.tryParse(t.group(3) ?? '') ?? 0;
    if (h < 24 && min < 60 && sec < 60) {
      return ParsedDate(DateTime(y, m, d, h, min, sec), length: lead + len + t.end, hasTime: true);
    }
  }
  return ParsedDate(date, length: lead + len);
}

int _fullYear(String y) => y.length == 2 ? 2000 + int.parse(y) : int.parse(y);

/// Year for a year-less `dd/mm` date: the year of [periodEnd] (statement
/// period) or of [now], minus one when that would put the date more than a
/// day after the reference (December rows in a January statement).
int Function(int month, int day) inferYear({DateTime? periodEnd, required DateTime now}) {
  final ref = periodEnd ?? now;
  return (month, day) {
    final candidate = DateTime(ref.year, month, day);
    return candidate.isAfter(ref.add(const Duration(days: 1))) ? ref.year - 1 : ref.year;
  };
}

/// `PEND` / `PENDING` in a BCA date column: the bank has not booked the row.
bool isPendingDate(String raw) {
  final t = raw.trim().replaceAll("'", '').toUpperCase();
  return t == 'PEND' || t == 'PENDING';
}

final _periodRange = RegExp(
  r'(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\.?\s+\d{4})\s*(?:-|s\.?\s*d\.?|sampai|to|hingga|–)\s*(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\.?\s+\d{4})',
  caseSensitive: false,
);
final _periodMonth = RegExp(r'(?:periode|period)\s*:?\s*([A-Za-z]{3,9})\s+(\d{4})', caseSensitive: false);

/// End of the statement period printed in a header ("Periode : 01/09/2026 -
/// 30/09/2026", "PERIODE : SEPTEMBER 2026"), or null.
DateTime? findPeriodEnd(Iterable<String> lines) {
  for (final line in lines) {
    final r = _periodRange.firstMatch(line);
    if (r != null) {
      final end = parseLeadingDate(r.group(2)!);
      if (end != null) return end.date;
    }
    final m = _periodMonth.firstMatch(line);
    if (m != null) {
      final month = monthFromName(m.group(1)!);
      if (month != null) return DateTime(int.parse(m.group(2)!), month + 1, 0);
    }
  }
  return null;
}

/// Lower-cased, punctuation-free text for keyword checks.
String foldText(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9/&]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Statement lines that are not transactions.
enum SummaryKind { opening, closing, other }

const _openingWords = [
  'saldo awal', 'opening balance', 'beginning balance', 'saldo sebelumnya', 'previous balance', 'saldo pembukaan',
];
const _closingWords = ['saldo akhir', 'closing balance', 'ending balance', 'saldo penutupan'];
const _otherPrefixes = [
  'total', 'subtotal', 'sub total', 'mutasi debet', 'mutasi debit', 'mutasi kredit', 'mutasi credit',
  'jumlah debet', 'jumlah debit', 'jumlah kredit', 'jumlah credit', 'saldo rata', 'average balance',
  'debet', 'debit', 'kredit', 'credit', 'grand total',
];

/// Opening/closing balance or other summary ("Total", "Mutasi Debet")
/// label in [text], or null for an ordinary line. Other summaries must start
/// the text, so descriptions like "BAYAR TOTALINDO" are kept.
SummaryKind? summaryKind(String text) {
  final f = foldText(text);
  if (f.isEmpty) return null;
  if (_openingWords.any(f.startsWith) || _openingWords.any((w) => f.contains(' $w'))) {
    return SummaryKind.opening;
  }
  if (_closingWords.any(f.startsWith) || _closingWords.any((w) => f.contains(' $w'))) {
    return SummaryKind.closing;
  }
  for (final p in _otherPrefixes) {
    if (f == p || f.startsWith('$p ')) {
      // Only summary words and numbers may follow the label, so "TOTAL
      // ENERGIES SPBU" or "DEBIT CARD INDOMARET" stay transactions.
      final rest = f.substring(p.length).trim().split(' ');
      if (rest.every((w) => w.isEmpty || _summaryTail.contains(w) || RegExp(r'^[\d/]+$').hasMatch(w))) {
        return SummaryKind.other;
      }
    }
  }
  return null;
}

const _summaryTail = {
  'mutasi', 'debet', 'debit', 'kredit', 'credit', 'transaksi', 'transaction', 'transactions', 'saldo', 'balance',
  'periode', 'period', 'ini', 'bulan', 'idr', 'rp', 'cr', 'db', 'dr', 'amount', 'jumlah', 'nominal', 'harian',
};

/// Rows may be oldest-first (balance after = previous + signed amount) or
/// newest-first (next row's balance + signed amount = this balance).
StatementDirection? directionFromBalances({required int amount, required int balance, int? before, int? after}) {
  if (before != null) {
    if (before + amount == balance) return StatementDirection.credit;
    if (before - amount == balance) return StatementDirection.debit;
  }
  if (after != null) {
    if (after + amount == balance) return StatementDirection.credit;
    if (after - amount == balance) return StatementDirection.debit;
  }
  return null;
}
