import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'converters.dart';
import 'enums.dart';
import 'seed.dart';
import 'tables.dart';

export 'converters.dart';
export 'enums.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Accounts,
    Categories,
    Transactions,
    Attachments,
    Budgets,
    Goals,
    GoalMovements,
    RecurringRules,
    RecurringInstances,
    DailyActivity,
    PlanningSettings,
    MerchantMappings,
    AppSettings,
    Backups,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens the on-device database file.
  factory AppDatabase.open(File file) =>
      AppDatabase(NativeDatabase.createInBackground(file));

  /// In-memory database for tests and fixtures.
  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());

  /// Bump together with a new `if (from < N)` step in [migration], then dump
  /// the schema into `drift_schemas/` (see CHANGELOG release policy).
  static const int currentSchemaVersion = 4;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedDefaults(this);
    },
    onUpgrade: (m, from, to) async {
      // Each step lists its own entities so later versions cannot change
      // what an older step creates.
      if (from < 2) {
        for (final index in [
          transactionsTransactionAt,
          transactionsAccountId,
          transactionsTransferToAccountId,
          transactionsCategoryIdTransactionAt,
          transactionsRecurringInstanceId,
          attachmentsTransactionId,
          attachmentsImageHash,
          goalMovementsGoalId,
          goalMovementsTransactionId,
          recurringInstancesDueDateStatus,
          recurringInstancesTransactionId,
        ]) {
          await m.create(index);
        }
      }
      if (from < 3) {
        await m.addColumn(goals, goals.linkedAccountId);
        await m.create(goalsLinkedAccountId);
      }
      if (from < 4) {
        await m.addColumn(attachments, attachments.fileSha256);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // Wait for a competing connection (notification background isolate,
      // backup/restore) instead of failing immediately with SQLITE_BUSY.
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );

  /// Runs SQLite integrity + foreign key checks. Empty list means healthy.
  Future<List<String>> integrityProblems() async {
    final problems = <String>[];
    final integrity = await customSelect('PRAGMA integrity_check').get();
    for (final row in integrity) {
      final v = row.data.values.first.toString();
      if (v != 'ok') problems.add('integrity: $v');
    }
    final fk = await customSelect('PRAGMA foreign_key_check').get();
    for (final row in fk) {
      problems.add('foreign key: ${row.data}');
    }
    final badAmounts = await customSelect(
      'SELECT COUNT(*) AS c FROM transactions WHERE amount <= 0',
    ).getSingle();
    final c = badAmounts.read<int>('c');
    if (c > 0) problems.add('invalid amounts: $c transaksi');
    return problems;
  }
}

/// Location of the live database file inside app-private storage.
Future<File> databaseFile() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, 'finbro.sqlite'));
}

/// Converter shortcuts used in custom SQL range filters.
String sqlDate(DateTime d) => isoDate(d);
String sqlDateTime(DateTime d) => isoLocal(d);
