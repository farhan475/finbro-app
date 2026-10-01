import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/ids.dart';

final goalRepositoryProvider = Provider<GoalRepository>(
  (ref) => GoalRepository(ref.watch(databaseProvider)),
);

/// All goals (active and archived): priority DESC, created_at ASC.
final goalsProvider = FutureProvider<List<Goal>>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(goalRepositoryProvider).all();
});

final goalProvider = FutureProvider.autoDispose.family<Goal?, String>((ref, id) {
  ref.watch(dbChangesProvider);
  return ref.watch(goalRepositoryProvider).get(id);
});

/// Movements of one goal, newest first.
final goalMovementsProvider = FutureProvider.autoDispose.family<List<GoalMovement>, String>((
  ref,
  goalId,
) {
  ref.watch(dbChangesProvider);
  return ref.watch(goalRepositoryProvider).movements(goalId);
});

/// §14 Emergency Fund status for today.
final emergencyStatusProvider = FutureProvider.autoDispose<EmergencyStatus>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).emergencyStatus(ref.watch(clockProvider)());
});

/// Priority levels (higher = more important).
const goalPriorityLabels = {0: 'Tanpa prioritas', 1: 'Rendah', 2: 'Sedang', 3: 'Tinggi'};

extension MovementTypeLabel on MovementType {
  String get label => switch (this) {
    MovementType.contribution => 'Tambah dana',
    MovementType.withdrawal => 'Tarik dana',
    MovementType.adjustment => 'Penyesuaian',
  };
}

/// Goals and their movements (FR-GOA-001..003). Money stays in accounts;
/// `goals.current_amount` is a cache of SUM(goal_movements.amount) rebuilt by
/// [recomputeGoalAmount] inside the same DB transaction as every movement write.
class GoalRepository {
  GoalRepository(this.db);
  final AppDatabase db;

  Future<List<Goal>> all() => (db.select(db.goals)
        ..orderBy([
          (g) => OrderingTerm.desc(g.priority),
          (g) => OrderingTerm.asc(g.createdAt),
        ]))
      .get();

  Future<Goal?> get(String id) =>
      (db.select(db.goals)..where((g) => g.id.equals(id))).getSingleOrNull();

  Future<List<GoalMovement>> movements(String goalId) => (db.select(db.goalMovements)
        ..where((m) => m.goalId.equals(goalId))
        ..orderBy([(m) => OrderingTerm.desc(m.movementAt)]))
      .get();

  Future<String> create({
    required String name,
    required GoalType type,
    required int targetAmount,
    DateTime? targetDate,
    int? monthlyTarget,
    int priority = 0,
  }) async {
    final cleanName = _validate(name, targetAmount, monthlyTarget, priority);
    final id = newId();
    final now = DateTime.now();
    await db.into(db.goals).insert(
      GoalsCompanion.insert(
        id: id,
        name: cleanName,
        type: type,
        targetAmount: targetAmount,
        targetDate: Value(targetDate),
        monthlyTarget: Value(monthlyTarget),
        priority: Value(priority),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<void> update(
    String id, {
    required String name,
    required GoalType type,
    required int targetAmount,
    DateTime? targetDate,
    int? monthlyTarget,
    int priority = 0,
  }) async {
    final cleanName = _validate(name, targetAmount, monthlyTarget, priority);
    await (db.update(db.goals)..where((g) => g.id.equals(id))).write(
      GoalsCompanion(
        name: Value(cleanName),
        type: Value(type),
        targetAmount: Value(targetAmount),
        targetDate: Value(targetDate),
        monthlyTarget: Value(monthlyTarget),
        priority: Value(priority),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Archive (`false`) or restore (`true`). Archived goals keep history but
  /// no longer count as reserved money / Emergency Fund balance.
  Future<void> setActive(String id, bool active) =>
      (db.update(db.goals)..where((g) => g.id.equals(id))).write(
        GoalsCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())),
      );

  /// Deletes the goal together with its movements.
  Future<void> delete(String id) => db.transaction(() async {
    await (db.delete(db.goalMovements)..where((m) => m.goalId.equals(id))).go();
    await (db.delete(db.goals)..where((g) => g.id.equals(id))).go();
  });

  /// Records a movement. [amount] is always positive (as typed in the UI);
  /// it is stored signed: contribution +, withdrawal −, adjustment − when
  /// [decrease] is true. Rejects movements that would make the balance
  /// negative.
  Future<String> addMovement({
    required String goalId,
    required MovementType type,
    required int amount,
    bool decrease = false,
    DateTime? at,
    String? note,
  }) async {
    if (amount <= 0) {
      throw const LedgerValidationException('Nominal harus lebih dari 0.');
    }
    final signed = switch (type) {
      MovementType.contribution => amount,
      MovementType.withdrawal => -amount,
      MovementType.adjustment => decrease ? -amount : amount,
    };
    final id = newId();
    await db.transaction(() async {
      final goal = await get(goalId);
      if (goal == null) throw const LedgerValidationException('Tujuan tidak ditemukan.');
      if (!goal.isActive) {
        throw const LedgerValidationException('Tujuan sudah diarsipkan.');
      }
      if (goal.currentAmount + signed < 0) {
        throw const LedgerValidationException('Dana tujuan tidak mencukupi.');
      }
      final trimmed = note?.trim();
      await db.into(db.goalMovements).insert(
        GoalMovementsCompanion.insert(
          id: id,
          goalId: goalId,
          amount: signed,
          movementType: type,
          movementAt: at ?? DateTime.now(),
          note: Value(trimmed == null || trimmed.isEmpty ? null : trimmed),
        ),
      );
      await recomputeGoalAmount(db, goalId);
    });
    return id;
  }

  /// Deletes a movement and rebuilds the goal balance. Rejected when the
  /// remaining history would leave the balance negative.
  Future<void> deleteMovement(String movementId) => db.transaction(() async {
    final m = await (db.select(db.goalMovements)..where((x) => x.id.equals(movementId)))
        .getSingleOrNull();
    if (m == null) return;
    final goal = await get(m.goalId);
    if (goal != null && goal.currentAmount - m.amount < 0) {
      throw const LedgerValidationException(
        'Tidak bisa dihapus: saldo tujuan akan menjadi negatif.',
      );
    }
    await (db.delete(db.goalMovements)..where((x) => x.id.equals(movementId))).go();
    await recomputeGoalAmount(db, m.goalId);
  });

  static String _validate(String name, int targetAmount, int? monthlyTarget, int priority) {
    final n = name.trim();
    if (n.isEmpty) throw const LedgerValidationException('Nama tujuan wajib diisi.');
    if (n.length > 60) throw const LedgerValidationException('Nama maksimal 60 karakter.');
    if (targetAmount <= 0) {
      throw const LedgerValidationException('Target dana harus lebih dari 0.');
    }
    if (monthlyTarget != null && monthlyTarget <= 0) {
      throw const LedgerValidationException('Target bulanan harus lebih dari 0.');
    }
    if (!goalPriorityLabels.containsKey(priority)) {
      throw const LedgerValidationException('Prioritas tidak valid.');
    }
    return n;
  }
}
