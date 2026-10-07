import 'package:intl/intl.dart';

import '../database/enums.dart';

final _grouped = NumberFormat.decimalPattern('id_ID');
final _percent1 = NumberFormat('#,##0.0', 'id_ID');
final _percent0 = NumberFormat('#,##0', 'id_ID');

/// `Rp 4.820.000` / `-Rp 35.000`. Amounts are whole rupiah (IDR minor unit).
String formatRupiah(int amount, {bool signed = false}) {
  final body = 'Rp ${_grouped.format(amount.abs())}';
  if (amount < 0) return '-$body';
  if (signed && amount > 0) return '+$body';
  return body;
}

/// Compact axis label: `4,8 jt`, `750 rb`, `1,2 M`.
String formatRupiahCompact(num amount) {
  final a = amount.abs();
  final sign = amount < 0 ? '-' : '';
  String fmt(double v, String unit) {
    final s = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$sign${s.replaceAll('.', ',').replaceAll(RegExp(r',0$'), '')} $unit';
  }

  if (a >= 1e9) return fmt(a / 1e9, 'M');
  if (a >= 1e6) return fmt(a / 1e6, 'jt');
  if (a >= 1e3) return fmt(a / 1e3, 'rb');
  return '$sign${a.toStringAsFixed(0)}';
}

/// Percentage for display; `null` renders `N/A` (e.g. zero denominator).
String formatPercent(double? value, {int decimals = 0}) {
  if (value == null || value.isNaN || value.isInfinite) return 'N/A';
  return '${(decimals == 0 ? _percent0 : _percent1).format(value)}%';
}

/// Parses user text such as `1.250.000`, `Rp 35.000`, `35000` into rupiah.
/// Returns null when no digits are present.
int? parseRupiah(String input) {
  final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// The same nominal value [minor] (minor units of [from]) in minor units of
/// [to]: `1250` USD → `1250` EUR, `12` IDR → `1200` USD. Null when [to] has
/// fewer decimals and that would drop a non-zero fraction (`1250` USD → IDR).
/// Used when an entry form switches account currency, so a typed amount is
/// kept or cleared but never silently rounded.
int? rescaleMinor(int minor, Currency from, Currency to) {
  if (to.decimals >= from.decimals) return minor * _pow10(to.decimals - from.decimals);
  final div = _pow10(from.decimals - to.decimals);
  return minor % div == 0 ? minor ~/ div : null;
}

/// Parses user text into minor units of [c]. For currencies with a minor
/// unit the LAST separator is the decimal mark and earlier ones are thousand
/// separators: `10.24`, `10,24`, `1.234,56` → 1024 / 123456. Tokens without
/// any separator are whole units and multiply by the divisor: `10` → 1000.
/// Zero-decimal currencies (IDR, JPY) behave exactly like [parseRupiah].
/// Returns null when no digits are present or the fractional part overflows.
int? parseMoney(String input, Currency c) {
  final t = input.trim();
  if (c.decimals == 0) return parseRupiah(t);
  final m = RegExp(r'^[^\d]*([\d.,]+)[^\d]*$').firstMatch(t);
  if (m == null) return null;
  final raw = m.group(1)!;
  final lastDot = raw.lastIndexOf('.');
  final lastComma = raw.lastIndexOf(',');
  final decSep = lastDot > lastComma ? '.' : (lastComma > -1 ? ',' : null);
  if (decSep == null) {
    final whole = int.tryParse(raw.replaceAll(RegExp(r'[.,]'), ''));
    return whole == null ? null : whole * _pow10(c.decimals);
  }
  final parts = raw.split(decSep);
  if (parts.length > 2) return null;
  final wholeDigits = parts[0].replaceAll(RegExp(r'\D'), '');
  // Ambiguous mixed separators inside the whole part ('1.2.3,4' after
  // splitting on ',') are rejected; a clean group ('1,234.56') passes.
  // Leading group may be 1–3 digits; every later group must be exactly 3.
  final otherSep = decSep == '.' ? ',' : '.';
  final wholeGroups = parts[0].split(otherSep);
  if (parts[0].contains(decSep) ||
      (wholeGroups.length > 1 && wholeGroups.skip(1).any((g) => g.length != 3))) {
    return null;
  }
  final frac = parts.length == 2 ? parts[1] : '';
  if (frac.length > c.decimals) return null;
  final whole = wholeDigits.isEmpty ? 0 : int.tryParse(wholeDigits);
  if (whole == null) return null;
  final fracPadded = frac.padRight(c.decimals, '0');
  final fracValue = fracPadded.isEmpty ? 0 : int.tryParse(fracPadded) ?? 0;
  return whole * _pow10(c.decimals) + fracValue;
}

// id_ID-style grouped number ('.' thousands, ',' decimals) built from a
// custom pattern so output is deterministic without locale-data caveats.
final _grouped2 = NumberFormat('#,##0.00', 'id_ID');

/// `1 USD = Rp 16.250` style label; [rate] is rupiah per 1 unit of [c].
String formatRate(double rate, Currency c) => '1 ${c.code} = ${formatRupiah(rate.round())}';

/// Null-safe lookup by [Currency.code]; case-insensitive, null for
/// null/unknown codes.
Currency? currencyFromCode(String? code) {
  if (code == null) return null;
  final needle = code.toUpperCase();
  for (final c in Currency.values) {
    if (c.code.toUpperCase() == needle) return c;
  }
  return null;
}

/// Main display formatter: IDR keeps the `Rp` whole-rupiah look of
/// [formatRupiah]; other currencies render symbol + 2 decimals when the
/// currency has a minor unit (e.g. `$1.234,56`), or symbol + whole number
/// for zero-decimal currencies like JPY (`¥1.234`).
String formatMoney(int amount, Currency c, {bool signed = false}) {
  if (c == Currency.idr) return formatRupiah(amount, signed: signed);
  final body = '${c.symbol}${_body(amount.abs(), c)}';
  if (amount < 0) return '-$body';
  if (signed && amount > 0) return '+$body';
  return body;
}

String _body(int absAmount, Currency c) {
  if (c.decimals > 0) return _grouped2.format(absAmount / _pow10(c.decimals));
  return _grouped.format(absAmount);
}

/// Compact axis label with currency symbol: `$4,8 jt`, `S$750 rb`.
String formatMoneyCompact(num amount, Currency c) {
  if (c == Currency.idr) return formatRupiahCompact(amount);
  final a = amount.abs();
  final sign = amount < 0 ? '-' : '';
  String fmt(double v, String unit) {
    final s = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${s.replaceAll('.', ',').replaceAll(RegExp(r',0$'), '')} $unit';
  }

  if (a >= 1e9) return '$sign${c.symbol}${fmt(a / 1e9, 'M')}';
  if (a >= 1e6) return '$sign${c.symbol}${fmt(a / 1e6, 'jt')}';
  if (a >= 1e3) return '$sign${c.symbol}${fmt(a / 1e3, 'rb')}';
  return '$sign${c.symbol}${a.toStringAsFixed(0)}';
}
