import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../domain/transaction_filter.dart';

final transactionQueryRepositoryProvider = Provider<TransactionQueryRepository>(
  (ref) => TransactionQueryRepository(ref.watch(databaseProvider)),
);

/// One page of filtered rows; [hasMore] tells the list to offer "load more".
class TransactionPage {
  const TransactionPage(this.items, {required this.hasMore});
  final List<LedgerTransaction> items;
  final bool hasMore;
}

/// Page size of lazily loaded transaction lists.
const transactionPageSize = 200;

/// Filtered transactions, newest first, limited to `limit` rows.
final transactionPageProvider = FutureProvider.autoDispose
    .family<TransactionPage, ({TransactionFilter filter, int limit})>((ref, q) {
      ref.watch(dbChangesProvider);
      return ref.watch(transactionQueryRepositoryProvider).page(q.filter, limit: q.limit);
    });

/// Category ids of [CategoryType] ordered by use in the last 30 days.
final recentCategoryIdsProvider = FutureProvider.autoDispose.family<List<String>, CategoryType>((ref, type) {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  return ref.watch(transactionQueryRepositoryProvider).recentCategoryIds(type, now);
});

final transactionByIdProvider = StreamProvider.autoDispose.family<LedgerTransaction?, String>((ref, id) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.transactions)..where((t) => t.id.equals(id))).watchSingleOrNull();
});

final transactionAttachmentsProvider = StreamProvider.autoDispose.family<List<Attachment>, String>((ref, txId) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.attachments)
        ..where((a) => a.transactionId.equals(txId))
        ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
      .watch();
});

/// Read-side transaction queries (lists, search, input defaults).
class TransactionQueryRepository {
  TransactionQueryRepository(this.db);

  final AppDatabase db;

  /// Rows matching [f], newest first. Includes drafts (callers label them);
  /// totals must only use confirmed rows.
  Future<List<LedgerTransaction>> search(TransactionFilter f, {int? limit, int offset = 0}) async {
    final t = db.transactions;
    final cat = db.categories;
    final src = db.accounts;
    final dest = db.alias(db.accounts, 'dest');

    final keyword = f.trimmedKeyword;
    final query = db.select(t).join([
      if (keyword.isNotEmpty) ...[
        leftOuterJoin(cat, cat.id.equalsExp(t.categoryId)),
        innerJoin(src, src.id.equalsExp(t.accountId)),
        leftOuterJoin(dest, dest.id.equalsExp(t.transferToAccountId)),
      ],
    ]);

    final conditions = <Expression<bool>>[
      if (f.type != null) t.type.equalsValue(f.type),
      if (f.startAt != null) t.transactionAt.isBiggerOrEqualValue(sqlDateTime(f.startAt!)),
      if (f.endBefore != null) t.transactionAt.isSmallerThanValue(sqlDateTime(f.endBefore!)),
      if (f.categoryIds.isNotEmpty) t.categoryId.isIn(f.categoryIds),
      if (f.accountIds.isNotEmpty) t.accountId.isIn(f.accountIds) | t.transferToAccountId.isIn(f.accountIds),
      if (f.minAmount != null) t.amount.isBiggerOrEqualValue(f.minAmount!),
      if (f.maxAmount != null) t.amount.isSmallerOrEqualValue(f.maxAmount!),
      if (keyword.isNotEmpty) _keywordMatch(keyword, [t.note, cat.name, src.name, dest.name]),
    ];
    if (conditions.isNotEmpty) query.where(Expression.and(conditions));

    // rowid breaks ties: timestamps have second resolution.
    query.orderBy([OrderingTerm.desc(t.transactionAt), OrderingTerm.desc(t.createdAt), OrderingTerm.desc(t.rowId)]);
    if (limit != null) query.limit(limit, offset: offset);
    final rows = await query.get();
    return [for (final r in rows) r.readTable(t)];
  }

  /// First [limit] matches plus whether more exist.
  Future<TransactionPage> page(TransactionFilter f, {int limit = transactionPageSize}) async {
    final rows = await search(f, limit: limit + 1);
    final hasMore = rows.length > limit;
    return TransactionPage(hasMore ? rows.sublist(0, limit) : rows, hasMore: hasMore);
  }

  /// Categories of [type] used by confirmed transactions in the [days]
  /// before [now], most used first (ties: most recently used first).
  Future<List<String>> recentCategoryIds(CategoryType type, DateTime now, {int days = 30}) async {
    final t = db.transactions;
    final uses = t.id.count();
    final last = t.transactionAt.max();
    final since = now.subtract(Duration(days: days));
    final txType = type == CategoryType.income ? TransactionType.income : TransactionType.expense;
    final rows = await (db.selectOnly(t)
          ..addColumns([t.categoryId, uses, last])
          ..where(
            t.type.equalsValue(txType) &
                t.status.equalsValue(TransactionStatus.confirmed) &
                t.categoryId.isNotNull() &
                t.transactionAt.isBiggerOrEqualValue(sqlDateTime(since)) &
                t.transactionAt.isSmallerOrEqualValue(sqlDateTime(now)),
          )
          ..groupBy([t.categoryId])
          ..orderBy([OrderingTerm.desc(uses), OrderingTerm.desc(last)]))
        .get();
    return [for (final r in rows) r.read(t.categoryId)!];
  }

  /// Account of the most recently entered transaction (fast input default).
  Future<String?> lastUsedAccountId() async {
    final row = await (db.select(db.transactions)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.rowId)])
          ..limit(1))
        .getSingleOrNull();
    return row?.accountId;
  }

  static Expression<bool> _keywordMatch(String keyword, List<Expression<String>> columns) {
    final escaped = keyword.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');
    final pattern = '%$escaped%';
    return Expression.or([
      for (final c in columns) c.like(pattern, escapeChar: '\\'),
    ]);
  }
}
