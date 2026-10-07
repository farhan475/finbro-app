import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
// Background-isolate DB errors arrive wrapped in this type; unwrapped so a
// cipher failure keeps its own type.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'busy_wait.dart';
import 'converters.dart';
import 'database_cipher.dart';
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
    ExchangeRates,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens a plaintext database file as-is. App code opens the live database
  /// through [openDeviceDatabase]; this is for tests and backup tooling.
  factory AppDatabase.open(File file) =>
      AppDatabase(NativeDatabase.createInBackground(file, setup: waitWhenBusy));

  /// Opens (or creates) a SQLCipher database encrypted with [key]; see
  /// [unlockDatabase] for the per-connection setup (including the busy
  /// handler, [waitWhenBusy]).
  factory AppDatabase.encrypted(File file, DatabaseKey key) =>
      AppDatabase(NativeDatabase.createInBackground(file, setup: (raw) => unlockDatabase(raw, key)));

  /// In-memory database for tests and fixtures.
  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());

  /// Bump together with a new `if (from < N)` step in [migration], then dump
  /// the schema into `drift_schemas/` (see CHANGELOG release policy).
  static const int currentSchemaVersion = 5;

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
      if (from < 5) {
        await m.createTable(exchangeRates);
        await seedExchangeRates(this);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // No `PRAGMA busy_timeout` here: it would replace the busy handler the
      // file-backed factories install in their setup ([waitWhenBusy]).
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

/// The live database file and the device key it is encrypted with.
typedef DeviceDatabase = ({File file, DatabaseKey key});

/// The live database, ready to open or replace: the device key is created on
/// first use and a plaintext database from an older app version is
/// encrypted first ([prepareEncryptedDatabase]).
Future<DeviceDatabase> deviceDatabase() async {
  final file = await databaseFile();
  return (file: file, key: await prepareEncryptedDatabase(file, const SecureDatabaseKeyStore()));
}

/// Opens the live on-device database. The single entry point for every
/// isolate (app, notification actions, widget, background work). Opens
/// eagerly, so a key or cipher failure surfaces here as a
/// [DatabaseCipherException] instead of on some later query.
Future<AppDatabase> openDeviceDatabase() async {
  final live = await deviceDatabase();
  final db = AppDatabase.encrypted(live.file, live.key);
  try {
    await db.customSelect('SELECT 1').get();
  } catch (e, s) {
    await db.close();
    if (e case DriftRemoteException(remoteCause: final DatabaseCipherException cause)) {
      Error.throwWithStackTrace(cause, s);
    }
    rethrow;
  }
  return db;
}

/// Moves an unreadable live database aside (kept as `.unreadable-<time>`,
/// never deleted) so the next [openDeviceDatabase] starts a new one.
Future<File> setAsideDeviceDatabase() async => moveDatabaseAside(await databaseFile());

/// Converter shortcuts used in custom SQL range filters.
String sqlDate(DateTime d) => isoDate(d);
String sqlDateTime(DateTime d) => isoLocal(d);
