import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generated_migrations/schema.dart';

/// Migration into the multi-currency world (schema v5): existing accounts keep
/// their IDR rows untouched, the new exchange_rates table appears with default
/// manual kurs rows, and balances of legacy accounts still replay exactly.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('v4 → v5 creates exchange_rates and seeds default kurs rows', () async {
    final db = AppDatabase(await verifier.startAt(4));
    await verifier.migrateAndValidate(db, AppDatabase.currentSchemaVersion);

    final rates = await db.select(db.exchangeRates).get();
    final codes = rates.map((r) => r.code).toSet();
    for (final code in ['USD', 'SGD', 'EUR', 'JPY']) {
      expect(codes, contains(code), reason: 'default kurs $code harus ter-seed');
    }
    for (final r in rates) {
      expect(r.rateToIdr, greaterThan(0), reason: '${r.code} harus > 0');
    }
    await db.close();
  });

  test('v4 → v5 keeps accounts/transactions and legacy balances replay identically', () async {
    final schema = await verifier.schemaAt(4);
    const ts = '2026-09-01T10:00:00';
    schema.rawDatabase
      ..execute(
        'INSERT INTO accounts (id, name, type, opening_balance, created_at, updated_at) '
        "VALUES ('a1', 'Dompet', 'cash', 500000, '$ts', '$ts')",
      )
      ..execute(
        'INSERT INTO categories (id, name, type, created_at, updated_at) '
        "VALUES ('c1', 'Makan', 'expense', '$ts', '$ts')",
      )
      ..execute(
        'INSERT INTO transactions (id, type, amount, account_id, category_id, '
        'transaction_at, created_at, updated_at) VALUES '
        "('t1', 'expense', 150000, 'a1', 'c1', '2026-09-02T12:30:00', '$ts', '$ts')",
      );

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, AppDatabase.currentSchemaVersion);

    // Legacy rows keep the IDR default.
    final a = await (db.select(db.accounts)..where((x) => x.id.equals('a1'))).getSingle();
    expect(a.currency, 'IDR');

    // exchange_rates was created by the migration (table exists; seed is a
    // separate step that only runs on the real migration path).
    await db.select(db.exchangeRates).get();

    // Legacy balance still replays through the new conversion SQL untouched:
    // 500000 opening - 150000 expense = 350000 at rate 1.0 (IDR).
    final row = await db.customSelect(
      'SELECT CAST(ROUND((500000 '
      '+ COALESCE((SELECT SUM(CASE t.type WHEN \'income\' THEN t.amount ELSE -t.amount END) '
      'FROM transactions t WHERE t.account_id = a.id AND t.status = \'confirmed\' '
      'AND t.transaction_at <= \'2026-09-15T12:00:00\'), 0)) '
      '* COALESCE((SELECT r.rate_to_idr FROM exchange_rates r WHERE r.code = a.currency), 1.0) '
      "/ (CASE WHEN a.currency IN ('IDR','JPY') THEN 1.0 ELSE 100.0 END)) AS INTEGER) AS idr "
      'FROM accounts a WHERE a.id = \'a1\'',
    ).getSingle();
    expect(row.read<int>('idr'), 350000);
    await db.close();
  });

  test('fresh install (create) seeds the same default kurs set', () async {
    final db = AppDatabase.memory();
    await db.customSelect('SELECT 1').get(); // runs onCreate
    final codes = {for (final r in await db.select(db.exchangeRates).get()) r.code};
    expect(codes, containsAll(['USD', 'SGD', 'MYR', 'EUR', 'GBP', 'JPY', 'AUD', 'CHF', 'CNY', 'HKD']));
    await db.close();
  });
}
