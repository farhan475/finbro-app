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

/// All goals (active and archived) with progress: priority DESC, created_at ASC.
final goalsProvider = FutureProvider<List<GoalProgress>>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).goalProgresses();
});

final goalProvider = FutureProvider.autoDispose.family<GoalProgress?, String>((ref, id) async {
  ref.watch(dbChangesProvider);
  return (await ref.watch(financeServiceProvider).goalProgresses(goalId: id)).firstOrNull;
});

/// Savings accounts a goal may link to: active, not linked to another goal,
/// plus the goal's current link (even when archived). Argument: goal id
/// (null for a new goal).
final linkableAccountsProvider = FutureProvider.autoDispose.family<List<Account>, String?>((ref, goalId) {
  ref.watch(dbChangesProvider);
  return ref.watch(goalRepositoryProvider).linkableAccounts(goalId: goalId);
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
/// A goal linked to a Savings account follows that account's balance instead
/// ([GoalProgress]); it takes no new movements, its history is kept for when
/// it is unlinked.
class GoalRepository {
  GoalRepository(this.db);
  final AppDatabase db;

  Future<Goal?> get(String id) =>
      (db.select(db.goals)..where((g) => g.id.equals(id))).getSingleOrNull();

  Future<List<GoalMovement>> movements(String goalId) => (db.select(db.goalMovements)
        ..where((m) => m.goalId.equals(goalId))
        ..orderBy([(m) => OrderingTerm.desc(m.movementAt)]))
      .get();

  /// See [linkableAccountsProvider].
  Future<List<Account>> linkableAccounts({String? goalId}) async {
    final current = goalId == null ? null : (await get(goalId))?.linkedAccountId;
    final taken = {
      for (final g in await (db.select(db.goals)..where((g) => g.linkedAccountId.isNotNull())).get())
        if (g.id != goalId) g.linkedAccountId!,
    };
    final savings = await (db.select(db.accounts)
          ..where((a) => a.type.equalsValue(AccountType.savings))
          ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
        .get();
    return [
      for (final a in savings)
        if (a.id == current || (a.isActive && !taken.contains(a.id))) a,
    ];
  }

  Future<String> create({
    required String name,
    required GoalType type,
    required int targetAmount,
    DateTime? targetDate,
    int? monthlyTarget,
    int priority = 0,
    String? linkedAccountId,
  }) async {
    final cleanName = _validate(name, targetAmount, monthlyTarget, priority);
    final id = newId();
    final now = DateTime.now();
    await db.transaction(() async {
      await _checkLink(goalId: null, accountId: linkedAccountId, previous: null);
      await db.into(db.goals).insert(
        GoalsCompanion.insert(
          id: id,
          name: cleanName,
          type: type,
          targetAmount: targetAmount,
          targetDate: Value(targetDate),
          monthlyTarget: Value(monthlyTarget),
          priority: Value(priority),
          linkedAccountId: Value(linkedAccountId),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
    return id;
  }

  /// [linkedAccountId] null unlinks: progress returns to the movements.
  Future<void> update(
    String id, {
    required String name,
    required GoalType type,
    required int targetAmount,
    DateTime? targetDate,
    int? monthlyTarget,
    int priority = 0,
    String? linkedAccountId,
  }) async {
    final cleanName = _validate(name, targetAmount, monthlyTarget, priority);
    await db.transaction(() async {
      final goal = await get(id);
      if (goal == null) throw const LedgerValidationException('Tujuan tidak ditemukan.');
      await _checkLink(goalId: id, accountId: linkedAccountId, previous: goal.linkedAccountId);
      await (db.update(db.goals)..where((g) => g.id.equals(id))).write(
        GoalsCompanion(
          name: Value(cleanName),
          type: Value(type),
          targetAmount: Value(targetAmount),
          targetDate: Value(targetDate),
          monthlyTarget: Value(monthlyTarget),
          priority: Value(priority),
          linkedAccountId: Value(linkedAccountId),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  /// Stops following the linked account; progress returns to the movements
  /// (their history is kept).
  Future<void> unlink(String id) =>
      (db.update(db.goals)..where((g) => g.id.equals(id))).write(
        GoalsCompanion(linkedAccountId: const Value(null), updatedAt: Value(DateTime.now())),
      );

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
      if (goal.linkedAccountId != null) {
        throw const LedgerValidationException(
          'Tujuan ini mengikuti saldo account Savings-nya. Tambah atau tarik dana dengan transfer.',
        );
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

  /// A link must name an existing Savings account that no other goal uses.
  /// A new link also needs an active account; keeping the current link of an
  /// archived account is allowed. The unique index is the final guard.
  Future<void> _checkLink({
    required String? goalId,
    required String? accountId,
    required String? previous,
  }) async {
    if (accountId == null) return;
    final account = await (db.select(db.accounts)..where((a) => a.id.equals(accountId)))
        .getSingleOrNull();
    if (account == null) throw const LedgerValidationException('Account tidak ditemukan.');
    if (account.type != AccountType.savings) {
      throw const LedgerValidationException('Hanya account Savings yang bisa dihubungkan ke tujuan.');
    }
    if (accountId != previous && !account.isActive) {
      throw const LedgerValidationException('Account yang diarsipkan tidak bisa dihubungkan ke tujuan.');
    }
    final other = await (db.select(db.goals)
          ..where((g) => g.linkedAccountId.equals(accountId))
          ..limit(1))
        .getSingleOrNull();
    if (other != null && other.id != goalId) {
      throw LedgerValidationException(
        'Account "${account.name}" sudah terhubung ke tujuan "${other.name}". '
        'Satu account Savings hanya bisa untuk satu tujuan.',
      );
    }
  }

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
