import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/providers.dart';

/// All categories (active and inactive), ordered by type then name.
final allCategoriesProvider = StreamProvider<List<Category>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.categories)
        ..orderBy([(c) => OrderingTerm.asc(c.type), (c) => OrderingTerm.asc(c.name)]))
      .watch();
});

final categoryMapProvider = Provider<Map<String, Category>>(
  (ref) => {for (final c in ref.watch(allCategoriesProvider).value ?? const <Category>[]) c.id: c},
);

/// Active categories of one type, for pickers.
final activeCategoriesProvider = Provider.family<List<Category>, CategoryType>(
  (ref, type) => [
    for (final c in ref.watch(allCategoriesProvider).value ?? const <Category>[])
      if (c.isActive && c.type == type) c,
  ],
);

/// All accounts (active and archived), oldest first.
final allAccountsProvider = StreamProvider<List<Account>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.accounts)..orderBy([(a) => OrderingTerm.asc(a.createdAt)])).watch();
});

final accountMapProvider = Provider<Map<String, Account>>(
  (ref) => {for (final a in ref.watch(allAccountsProvider).value ?? const <Account>[]) a.id: a},
);

final activeAccountsProvider = Provider<List<Account>>(
  (ref) => [
    for (final a in ref.watch(allAccountsProvider).value ?? const <Account>[])
      if (a.isActive) a,
  ],
);

/// Most recent confirmed transactions (dashboard "Recent transactions").
final recentTransactionsProvider = StreamProvider.family<List<LedgerTransaction>, int>((ref, limit) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.transactions)
        ..where((t) => t.status.equalsValue(TransactionStatus.confirmed))
        ..orderBy([(t) => OrderingTerm.desc(t.transactionAt), (t) => OrderingTerm.desc(t.createdAt)])
        ..limit(limit))
      .watch();
});
