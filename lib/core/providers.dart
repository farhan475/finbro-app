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

/// Re-evaluates time boundaries on demand (called on app resume: Dart timers
/// do not advance while the device sleeps, so a boundary may have passed).
class TimeBoundaryCheck {
  final _listeners = <void Function()>[];
  void check() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

final timeBoundaryCheckProvider = Provider<TimeBoundaryCheck>((ref) => TimeBoundaryCheck());

/// Emits 0, then one increasing tick per burst of commits touching [tables],
/// and one tick whenever a time boundary passes: the next confirmed
/// transaction dated in the future (it starts counting in balances) or the
/// next local midnight (period/"today" figures roll over).
Stream<int> _changeTicks(Ref ref, AppDatabase db, List<TableInfo> tables) {
  final controller = StreamController<int>();
  final clock = ref.watch(clockProvider);
  final check = ref.watch(timeBoundaryCheckProvider);
  var tick = 0;
  var disposed = false;
  Timer? pending;
  Timer? boundaryTimer;
  DateTime? boundary;

  void emit() {
    if (!disposed) controller.add(++tick);
  }

  Future<void> arm() async {
    final now = clock();
    final QueryRow row;
    try {
      row = await db.customSelect(
        "SELECT MIN(transaction_at) AS next FROM transactions WHERE status = 'confirmed' AND transaction_at > ?",
        variables: [Variable(sqlDateTime(now))],
      ).getSingle();
    } catch (_) {
      return; // Database closed (restore swap / dispose); the next tick re-arms.
    }
    if (disposed) return;
    final next = row.readNullable<String>('next');
    final midnight = DateTime(now.year, now.month, now.day + 1);
    final nextTx = next == null ? null : DateTime.parse(next);
    final at = nextTx != null && nextTx.isBefore(midnight) ? nextTx : midnight;
    boundary = at;
    boundaryTimer?.cancel();
    // +1 s: transaction_at has second precision and the balance query is `<=`.
    boundaryTimer = Timer(at.difference(now) + const Duration(seconds: 1), () {
      emit();
      arm();
    });
  }

  void onResume() {
    final b = boundary;
    if (b != null && !clock().isBefore(b)) {
      emit();
      arm();
    }
  }

  final sub = db.tableUpdates(TableUpdateQuery.onAllTables(tables)).listen((_) {
    pending ??= Timer(dbChangesCoalesce, () {
      pending = null;
      emit();
      arm();
    });
  });
  check._listeners.add(onResume);
  ref.onDispose(() {
    disposed = true;
    pending?.cancel();
    boundaryTimer?.cancel();
    check._listeners.remove(onResume);
    sub.cancel();
    controller.close();
  });
  controller.add(tick);
  arm();
  return controller.stream;
}

/// Ticks after commits to ledger tables and at time boundaries (see
/// [_changeTicks]). Read-side providers `ref.watch` this so every derived
/// number is recomputed from source rows.
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
