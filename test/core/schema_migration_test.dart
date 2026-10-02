import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generated_migrations/schema.dart';

/// Guards the frozen schemas in `drift_schemas/` (see CHANGELOG release
/// policy). A table change without a schema bump + dump fails here.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('a database created by the current code matches the frozen latest schema', () async {
    final db = AppDatabase.memory();
    await db.customSelect('SELECT 1').get(); // runs onCreate
    await verifier.migrateAndValidate(db, AppDatabase.currentSchemaVersion);
    await db.close();
  });

  for (var from = 1; from < AppDatabase.currentSchemaVersion; from++) {
    test('upgrade v$from → v${AppDatabase.currentSchemaVersion} yields the frozen schema', () async {
      final db = AppDatabase(await verifier.startAt(from));
      await verifier.migrateAndValidate(db, AppDatabase.currentSchemaVersion);
      await db.close();
    });
  }

  test('v1 → v2 keeps ledger data and adds the query indexes', () async {
    final schema = await verifier.schemaAt(1);
    const ts = '2026-09-01T10:00:00';
    schema.rawDatabase
      ..execute(
        'INSERT INTO accounts (id, name, type, opening_balance, created_at, updated_at) '
        "VALUES ('a1', 'Dompet', 'cash', 100000, '$ts', '$ts'), "
        "('a2', 'Bank', 'bank', 0, '$ts', '$ts')",
      )
      ..execute(
        'INSERT INTO categories (id, name, type, created_at, updated_at) '
        "VALUES ('c1', 'Makan', 'expense', '$ts', '$ts')",
      )
      ..execute(
        'INSERT INTO transactions (id, type, amount, account_id, category_id, '
        'transfer_to_account_id, transaction_at, created_at, updated_at) VALUES '
        "('t1', 'expense', 25000, 'a1', 'c1', NULL, '2026-09-02T12:30:00', '$ts', '$ts'), "
        "('t2', 'transfer', 40000, 'a1', NULL, 'a2', '2026-09-03T08:00:00', '$ts', '$ts')",
      )
      ..execute(
        'INSERT INTO attachments (id, transaction_id, local_path, mime_type, source_kind, created_at) '
        "VALUES ('f1', 't1', 'attachments/f1.jpg', 'image/jpeg', 'receipt', '$ts')",
      );

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);

    final txs = await (db.select(db.transactions)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    expect(txs.map((t) => (t.id, t.type, t.amount, t.accountId, t.transferToAccountId)), [
      ('t1', TransactionType.expense, 25000, 'a1', null),
      ('t2', TransactionType.transfer, 40000, 'a1', 'a2'),
    ]);
    expect(txs.first.transactionAt, DateTime(2026, 9, 2, 12, 30));
    final atts = await db.select(db.attachments).get();
    expect(atts.single.transactionId, 't1');

    final indexes = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'")
        .map((r) => r.read<String>('name'))
        .get();
    expect(
      indexes,
      unorderedEquals([
        'transactions_transaction_at',
        'transactions_account_id',
        'transactions_transfer_to_account_id',
        'transactions_category_id_transaction_at',
        'transactions_recurring_instance_id',
        'attachments_transaction_id',
        'attachments_image_hash',
        'goal_movements_goal_id',
        'goal_movements_transaction_id',
        'recurring_instances_due_date_status',
        'recurring_instances_transaction_id',
      ]),
    );

    // Period aggregates and balances now resolve through the indexes.
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT SUM(amount) FROM transactions '
          "WHERE status = 'confirmed' AND transaction_at >= ? AND transaction_at < ?",
          variables: [Variable('2026-09-01T00:00:00'), Variable('2026-10-01T00:00:00')],
        )
        .map((r) => r.read<String>('detail'))
        .get();
    expect(plan.join('\n'), contains('USING INDEX transactions_transaction_at'));
    await db.close();
  });
}
