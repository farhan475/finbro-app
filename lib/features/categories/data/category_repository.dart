import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/ids.dart';

final categoryRepositoryProvider = Provider<CategoryRepository>(
  (ref) => CategoryRepository(ref.watch(databaseProvider)),
);

/// Number of rows (transactions, budgets, recurring rules) using a category.
final categoryUsageProvider = FutureProvider.autoDispose.family<int, String>((ref, id) {
  ref.watch(dbChangesProvider);
  return ref.watch(categoryRepositoryProvider).usageCount(id);
});

class CategoryException implements Exception {
  const CategoryException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Editable category fields. [planningBucket] and [expenseNature] only
/// apply to expense categories and are dropped for income.
class CategoryInput {
  const CategoryInput({
    required this.name,
    required this.type,
    this.icon,
    this.planningBucket,
    this.expenseNature,
  });

  final String name;
  final CategoryType type;
  final String? icon;
  final PlanningBucket? planningBucket;
  final ExpenseNature? expenseNature;
}

class CategoryRepository {
  CategoryRepository(this.db);

  final AppDatabase db;

  static const maxNameLength = 40;

  Future<String> create(CategoryInput input) async {
    final id = newId();
    await db.transaction(() async {
      final name = await _validName(input.name, input.type);
      final expense = input.type == CategoryType.expense;
      final now = DateTime.now();
      await db.into(db.categories).insert(
        CategoriesCompanion.insert(
          id: id,
          name: name,
          type: input.type,
          icon: Value(input.icon),
          planningBucket: Value(expense ? input.planningBucket : null),
          expenseNature: Value(expense ? input.expenseNature : null),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
    return id;
  }

  /// Updates name/icon/bucket/nature. The type never changes: existing
  /// transactions must keep a category matching their income/expense type.
  Future<void> update(String id, CategoryInput input) async {
    await db.transaction(() async {
      final current = await _get(id);
      if (current.type != input.type) {
        throw const CategoryException('Jenis kategori tidak bisa diubah.');
      }
      final name = await _validName(input.name, current.type, exceptId: id);
      final expense = current.type == CategoryType.expense;
      await (db.update(db.categories)..where((c) => c.id.equals(id))).write(
        CategoriesCompanion(
          name: Value(name),
          icon: Value(input.icon),
          planningBucket: Value(expense ? input.planningBucket : null),
          expenseNature: Value(expense ? input.expenseNature : null),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  /// Inactive categories disappear from pickers but keep their history.
  Future<void> setActive(String id, bool active) async {
    await _get(id);
    await (db.update(db.categories)..where((c) => c.id.equals(id))).write(
      CategoriesCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())),
    );
  }

  Future<int> usageCount(String id) async {
    Future<int> count(TableInfo table, Expression<bool> where) async {
      final c = countAll();
      return (db.selectOnly(table)
            ..addColumns([c])
            ..where(where))
          .map((r) => r.read(c) ?? 0)
          .getSingle();
    }

    return await count(db.transactions, db.transactions.categoryId.equals(id)) +
        await count(db.budgets, db.budgets.categoryId.equals(id)) +
        await count(db.recurringRules, db.recurringRules.categoryId.equals(id));
  }

  /// System categories are never deleted; custom ones only while unused.
  Future<void> delete(String id) async {
    await db.transaction(() async {
      final c = await _get(id);
      if (c.isSystem) {
        throw const CategoryException('Kategori bawaan tidak bisa dihapus. Nonaktifkan saja.');
      }
      if (await usageCount(id) > 0) {
        throw const CategoryException('Kategori sudah dipakai dan tidak bisa dihapus. Nonaktifkan saja.');
      }
      await (db.delete(db.categories)..where((x) => x.id.equals(id))).go();
    });
  }

  Future<Category> _get(String id) async {
    final c = await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingleOrNull();
    if (c == null) throw const CategoryException('Kategori tidak ditemukan.');
    return c;
  }

  Future<String> _validName(String name, CategoryType type, {String? exceptId}) async {
    final clean = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) throw const CategoryException('Nama kategori wajib diisi.');
    if (clean.length > maxNameLength) {
      throw const CategoryException('Nama kategori maksimal $maxNameLength karakter.');
    }
    final q = db.select(db.categories)
      ..where((c) => c.type.equalsValue(type) & c.name.lower().equals(clean.toLowerCase()));
    if (exceptId != null) q.where((c) => c.id.equals(exceptId).not());
    if ((await q.get()).isNotEmpty) {
      throw CategoryException('Kategori "$clean" sudah ada.');
    }
    return clean;
  }
}
