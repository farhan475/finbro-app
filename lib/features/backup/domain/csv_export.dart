import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// `finbro-transaksi-YYYY-MM-DD-HHmm.csv`.
String transactionsCsvFileName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'finbro-transaksi-${isoDate(t)}-${two(t.hour)}${two(t.minute)}.csv';
}

const transactionsCsvHeader = [
  'date',
  'type',
  'amount',
  'category',
  'account',
  'to_account',
  'note',
  'source',
  'status',
];

/// All transactions (every status, oldest first) as RFC 4180 CSV with a UTF-8
/// BOM so spreadsheet apps read Indonesian text correctly.
Future<String> buildTransactionsCsv(AppDatabase db) async {
  final accounts = {for (final a in await db.select(db.accounts).get()) a.id: a.name};
  final categories = {for (final c in await db.select(db.categories).get()) c.id: c.name};
  final rows = await (db.select(db.transactions)
        ..orderBy([(t) => OrderingTerm.asc(t.transactionAt), (t) => OrderingTerm.asc(t.createdAt)]))
      .get();

  final buf = StringBuffer('\uFEFF')..write(transactionsCsvHeader.join(','))..write('\r\n');
  for (final t in rows) {
    final fields = [
      isoLocal(t.transactionAt),
      t.type.db,
      '${t.amount}',
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
/// free text (leading `=`, `+`, `-`, `@`).
String csvField(String v) {
  var s = v;
  if (s.isNotEmpty && '=+-@'.contains(s[0])) s = "'$s";
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
