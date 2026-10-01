import 'package:intl/intl.dart';

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
