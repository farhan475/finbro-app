import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/ids.dart';

final budgetRepositoryProvider = Provider<BudgetRepository>(
  (ref) => BudgetRepository(ref.watch(databaseProvider)),
);

/// Budgets overlapping the month of the key (use `monthStart`) with actuals,
/// highest usage first. Recomputed after every commit.
final budgetUsagesProvider = FutureProvider.autoDispose
    .family<List<BudgetUsageItem>, DateTime>((ref, month) {
      ref.watch(dbChangesProvider);
      return ref.watch(financeServiceProvider).budgetUsages(month);
    });

final budgetProvider = FutureProvider.autoDispose.family<Budget?, String>((ref, id) {
  ref.watch(dbChangesProvider);
  return ref.watch(budgetRepositoryProvider).get(id);
});

/// Default thresholds (03 §12), in percentage points.
const defaultAttentionThreshold = 70;
const defaultWarningThreshold = 85;
const defaultOverThreshold = 100;

/// Monthly category budgets (FR-BUD-001). Period is always one calendar
/// month; a category has at most one budget per month.
class BudgetRepository {
  BudgetRepository(this.db);
  final AppDatabase db;

  Future<Budget?> get(String id) =>
      (db.select(db.budgets)..where((b) => b.id.equals(id))).getSingleOrNull();

  /// Budgets whose period starts in the month of [month].
  Future<List<Budget>> forMonth(DateTime month) =>
      (db.select(db.budgets)
            ..where((b) => b.periodStart.equalsValue(monthStart(month))))
          .get();

  Future<String> create({
    required String categoryId,
    required DateTime month,
    required int amount,
    int attention = defaultAttentionThreshold,
    int warning = defaultWarningThreshold,
    int over = defaultOverThreshold,
  }) async {
    _validate(amount, attention, warning, over);
    final id = newId();
    await db.transaction(() async {
      final cat = await (db.select(db.categories)..where((c) => c.id.equals(categoryId)))
          .getSingleOrNull();
      if (cat == null || cat.type != CategoryType.expense) {
        throw const LedgerValidationException('Pilih kategori expense.');
      }
      final start = monthStart(month);
      final existing = await (db.select(db.budgets)
            ..where((b) => b.categoryId.equals(categoryId) & b.periodStart.equalsValue(start)))
          .getSingleOrNull();
      if (existing != null) {
        throw LedgerValidationException(
          'Budget ${cat.name} untuk ${formatMonth(start)} sudah ada.',
        );
      }
      final now = DateTime.now();
      await db.into(db.budgets).insert(
        BudgetsCompanion.insert(
          id: id,
          categoryId: categoryId,
          periodStart: start,
          periodEnd: monthEnd(start),
          amount: amount,
          attentionThreshold: Value(attention),
          warningThreshold: Value(warning),
          overThreshold: Value(over),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
    return id;
  }

  /// Changing the amount or any threshold resets `last_notified_threshold`
  /// so alerts are evaluated again against the new limits.
  Future<void> update(
    String id, {
    required int amount,
    required int attention,
    required int warning,
    required int over,
  }) async {
    _validate(amount, attention, warning, over);
    await db.transaction(() async {
      final b = await get(id);
      if (b == null) throw const LedgerValidationException('Budget tidak ditemukan.');
      final limitsChanged = b.amount != amount ||
          b.attentionThreshold != attention ||
          b.warningThreshold != warning ||
          b.overThreshold != over;
      if (!limitsChanged) return;
      await (db.update(db.budgets)..where((x) => x.id.equals(id))).write(
        BudgetsCompanion(
          amount: Value(amount),
          attentionThreshold: Value(attention),
          warningThreshold: Value(warning),
          overThreshold: Value(over),
          lastNotifiedThreshold: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  Future<void> delete(String id) =>
      (db.delete(db.budgets)..where((b) => b.id.equals(id))).go();

  /// "Salin budget bulan lalu": copies the previous month's budgets (amount and
  /// thresholds) into the month of [month], skipping categories that already
  /// have a budget there and categories that are no longer active.
  /// Returns the number of budgets created.
  Future<int> copyFromPreviousMonth(DateTime month) {
    final target = monthStart(month);
    final source = DateTime(target.year, target.month - 1);
    return db.transaction(() async {
      final previous = await forMonth(source);
      if (previous.isEmpty) return 0;
      final taken = {for (final b in await forMonth(target)) b.categoryId};
      final activeCategories = await (db.selectOnly(db.categories)
            ..addColumns([db.categories.id])
            ..where(db.categories.isActive.equals(true)))
          .map((r) => r.read(db.categories.id)!)
          .get();
      final active = activeCategories.toSet();
      final now = DateTime.now();
      var created = 0;
      for (final b in previous) {
        if (taken.contains(b.categoryId) || !active.contains(b.categoryId)) continue;
        await db.into(db.budgets).insert(
          BudgetsCompanion.insert(
            id: newId(),
            categoryId: b.categoryId,
            periodStart: target,
            periodEnd: monthEnd(target),
            amount: b.amount,
            attentionThreshold: Value(b.attentionThreshold),
            warningThreshold: Value(b.warningThreshold),
            overThreshold: Value(b.overThreshold),
            isActive: Value(b.isActive),
            createdAt: now,
            updatedAt: now,
          ),
        );
        created++;
      }
      return created;
    });
  }

  static void _validate(int amount, int attention, int warning, int over) {
    if (amount <= 0) {
      throw const LedgerValidationException('Nominal budget harus lebih dari 0.');
    }
    if (attention <= 0 || over > 1000) {
      throw const LedgerValidationException('Ambang harus di antara 1% dan 1000%.');
    }
    if (!(attention < warning && warning < over)) {
      throw const LedgerValidationException(
        'Ambang harus berurutan: attention < warning < over.',
      );
    }
  }
}
