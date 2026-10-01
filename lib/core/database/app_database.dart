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

  /// Bump together with a new `from == N` step in [migration].
  static const int currentSchemaVersion = 1;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedDefaults(this);
    },
    onUpgrade: (m, from, to) async {
      // Stepwise migrations go here, e.g.
      // if (from < 2) await m.addColumn(accounts, accounts.someColumn);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
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
