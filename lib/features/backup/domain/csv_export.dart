import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// `finbro-transaksi-YYYY-MM-DD-HHmm.csv`.
String transactionsCsvFileName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'finbro-transaksi-${isoDate(t)}-${two(t.hour)}${two(t.minute)}.csv';
}

/// `amount` is in whole units of `currency` (the account's ISO code) with a
/// `.` decimal mark: `25000` IDR, `12.50` USD.
const transactionsCsvHeader = [
  'date',
  'type',
  'amount',
  'currency',
  'category',
  'account',
  'to_account',
  'note',
  'source',
  'status',
];

/// [minor] units of [c] as a plain decimal (`1250` USD → `12.50`).
String _plainAmount(int minor, Currency c) {
  if (c.decimals == 0) return '$minor';
  final digits = minor.abs().toString().padLeft(c.decimals + 1, '0');
  final cut = digits.length - c.decimals;
  return '${minor < 0 ? '-' : ''}${digits.substring(0, cut)}.${digits.substring(cut)}';
}

/// All transactions (every status, oldest first) as RFC 4180 CSV with a UTF-8
/// BOM so spreadsheet apps read Indonesian text correctly.
Future<String> buildTransactionsCsv(AppDatabase db) async {
  final accountRows = await db.select(db.accounts).get();
  final accounts = {for (final a in accountRows) a.id: a.name};
  final currencies = {for (final a in accountRows) a.id: Currency.fromCode(a.currency)};
  final categories = {for (final c in await db.select(db.categories).get()) c.id: c.name};
  final rows = await (db.select(db.transactions)
        ..orderBy([(t) => OrderingTerm.asc(t.transactionAt), (t) => OrderingTerm.asc(t.createdAt)]))
      .get();

  final buf = StringBuffer('\uFEFF')..write(transactionsCsvHeader.join(','))..write('\r\n');
  for (final t in rows) {
    final currency = currencies[t.accountId] ?? Currency.idr;
    final fields = [
      isoLocal(t.transactionAt),
      t.type.db,
      _plainAmount(t.amount, currency),
      currency.code,
      categories[t.categoryId] ?? '',
      accounts[t.accountId] ?? '',
      accounts[t.transferToAccountId] ?? '',
      t.note ?? '',
      t.sourceType.db,
      t.status.db,
    ];
    buf
      ..write(fields.map(csvField).join(','))
      ..write('\r\n');
  }
  return buf.toString();
}

/// Quotes a CSV field when needed and neutralises spreadsheet formulas in
/// free text (leading `=`, `+`, `-`, `@`, tab or carriage return).
String csvField(String v) {
  var s = v;
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
