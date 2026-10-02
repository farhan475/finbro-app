import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database/app_database.dart';

/// Overridden in `main()` (real file) and tests (in-memory).
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

/// Bursts of commits within this window produce a single tick.
const dbChangesCoalesce = Duration(milliseconds: 32);

/// Tables every ledger-derived number is computed from. `daily_activity`,
/// `app_settings`, `merchant_mappings` and `backups` are deliberately absent:
/// writes there (lifecycle markers, PIN attempts, hide-balance toggle, scan
/// mappings) must not recompute the dashboard.
List<TableInfo> _ledgerTables(AppDatabase db) => [
  db.accounts,
  db.categories,
  db.transactions,
  db.attachments,
  db.budgets,
  db.goals,
  db.goalMovements,
  db.recurringRules,
  db.recurringInstances,
  db.planningSettings,
];

/// Emits 0, then one increasing tick per burst of commits touching [tables].
Stream<int> _changeTicks(Ref ref, AppDatabase db, List<TableInfo> tables) {
  final controller = StreamController<int>();
  var tick = 0;
  Timer? pending;
  final sub = db.tableUpdates(TableUpdateQuery.onAllTables(tables)).listen((_) {
    pending ??= Timer(dbChangesCoalesce, () {
      pending = null;
      controller.add(++tick);
    });
  });
  ref.onDispose(() {
    pending?.cancel();
    sub.cancel();
    controller.close();
  });
  controller.add(tick);
  return controller.stream;
}

/// Ticks after commits to ledger tables. Read-side providers `ref.watch` this
/// so every derived number is recomputed from source rows after each commit.
final dbChangesProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return _changeTicks(ref, db, _ledgerTables(db));
});

/// Like [dbChangesProvider] but also ticks on `daily_activity` writes; for
/// providers that read day states (calendar).
final activityChangesProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return _changeTicks(ref, db, [..._ledgerTables(db), db.dailyActivity]);
});

/// Injectable clock so time-dependent providers are testable.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
