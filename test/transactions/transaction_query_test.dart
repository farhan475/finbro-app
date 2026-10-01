import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/transactions/data/transaction_query_repository.dart';
import 'package:finbro_app/features/transactions/domain/day_groups.dart';
import 'package:finbro_app/features/transactions/domain/transaction_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late TransactionQueryRepository repo;
  final created = DateTime(2026, 9, 1);

  Future<String> account(String id, String name, {bool active = true}) async {
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(
        id: id,
        name: name,
        type: AccountType.bank,
        isActive: Value(active),
        createdAt: created,
        updatedAt: created,
      ),
    );
    return id;
  }

  Future<String> expense(int amount, DateTime at, {String account = 'bca', String? note, String category = SystemCategories.food}) =>
      ledger.create(TransactionDraft(
        type: TransactionType.expense,
        amount: amount,
        accountId: account,
        categoryId: category,
        transactionAt: at,
        note: note,
      ));

  Future<String> income(int amount, DateTime at, {String account = 'bca', String? note}) => ledger.create(TransactionDraft(
    type: TransactionType.income,
    amount: amount,
    accountId: account,
    categoryId: SystemCategories.salary,
    transactionAt: at,
    note: note,
  ));

  Future<String> transfer(int amount, DateTime at, {String from = 'bca', String to = 'gopay'}) => ledger.create(TransactionDraft(
    type: TransactionType.transfer,
    amount: amount,
    accountId: from,
    transferToAccountId: to,
    transactionAt: at,
  ));

  Future<List<String>> ids(TransactionFilter f) async => [for (final t in await repo.search(f)) t.id];

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    repo = TransactionQueryRepository(db);
    await account('bca', 'BCA');
    await account('gopay', 'GoPay');
  });
  tearDown(() => db.close());

  group('search filter', () {
    late String salary, food, taxi, move;

    setUp(() async {
      salary = await income(5000000, DateTime(2026, 9, 25, 8), note: 'Gaji September');
      food = await expense(35000, DateTime(2026, 9, 24, 12, 30), note: 'Nasi padang');
      taxi = await expense(25000, DateTime(2026, 9, 24, 23, 59, 59), category: SystemCategories.otherExpense, account: 'gopay');
      move = await transfer(200000, DateTime(2026, 9, 22, 9));
    });

    test('no filter returns everything newest first', () async {
      expect(await ids(const TransactionFilter()), [salary, taxi, food, move]);
    });

    test('type', () async {
      expect(await ids(const TransactionFilter(type: TransactionType.expense)), [taxi, food]);
      expect(await ids(const TransactionFilter(type: TransactionType.income)), [salary]);
      expect(await ids(const TransactionFilter(type: TransactionType.transfer)), [move]);
    });

    test('date range is inclusive of both whole days', () async {
      final day = DateTime(2026, 9, 24);
      expect(await ids(TransactionFilter(from: day, to: day)), [taxi, food]);
      expect(await ids(TransactionFilter(from: DateTime(2026, 9, 25))), [salary]);
      expect(await ids(TransactionFilter(to: DateTime(2026, 9, 23))), [move]);
      // Time components of the bounds are ignored.
      expect(await ids(TransactionFilter(from: DateTime(2026, 9, 24, 18), to: DateTime(2026, 9, 24, 1))), [taxi, food]);
    });

    test('category', () async {
      expect(await ids(const TransactionFilter(categoryIds: {SystemCategories.food})), [food]);
      expect(
        await ids(const TransactionFilter(categoryIds: {SystemCategories.food, SystemCategories.salary})),
        [salary, food],
      );
    });

    test('account matches source and transfer destination', () async {
      expect(await ids(const TransactionFilter(accountIds: {'gopay'})), [taxi, move]);
      expect(await ids(const TransactionFilter(accountIds: {'bca'})), [salary, food, move]);
    });

    test('amount range is inclusive', () async {
      expect(await ids(const TransactionFilter(minAmount: 35000)), [salary, food, move]);
      expect(await ids(const TransactionFilter(maxAmount: 35000)), [taxi, food]);
      expect(await ids(const TransactionFilter(minAmount: 25000, maxAmount: 200000)), [taxi, food, move]);
      expect(await ids(const TransactionFilter(minAmount: 300000, maxAmount: 400000)), isEmpty);
    });

    test('keyword matches note, category and account names, case-insensitive', () async {
      expect(await ids(const TransactionFilter(keyword: 'PADANG')), [food]);
      expect(await ids(const TransactionFilter(keyword: 'salary')), [salary]);
      // Account name: source (taxi on GoPay) and transfer destination (move).
      expect(await ids(const TransactionFilter(keyword: 'gopay')), [taxi, move]);
      expect(await ids(const TransactionFilter(keyword: '  nasi ')), [food]);
      expect(await ids(const TransactionFilter(keyword: 'zzz')), isEmpty);
    });

    test('keyword wildcards are literal', () async {
      final pct = await expense(10000, DateTime(2026, 9, 20), note: 'Diskon 50% kopi');
      expect(await ids(const TransactionFilter(keyword: '%')), [pct]);
      expect(await ids(const TransactionFilter(keyword: '_')), isEmpty);
    });

    test('filters combine with AND', () async {
      expect(
        await ids(TransactionFilter(
          type: TransactionType.expense,
          from: DateTime(2026, 9, 24),
          to: DateTime(2026, 9, 24),
          accountIds: const {'bca'},
          maxAmount: 50000,
          keyword: 'nasi',
        )),
        [food],
      );
      expect(
        await ids(const TransactionFilter(type: TransactionType.income, accountIds: {'gopay'})),
        isEmpty,
      );
    });

    test('page reports whether more rows exist', () async {
      final first = await repo.page(const TransactionFilter(), limit: 3);
      expect(first.items.map((t) => t.id), [salary, taxi, food]);
      expect(first.hasMore, isTrue);
      final all = await repo.page(const TransactionFilter(), limit: 4);
      expect(all.items, hasLength(4));
      expect(all.hasMore, isFalse);
    });
  });

  test('filter equality ignores set order and keyword padding', () {
    expect(
      const TransactionFilter(categoryIds: {'a', 'b'}, keyword: 'kopi '),
      const TransactionFilter(categoryIds: {'b', 'a'}, keyword: 'kopi'),
    );
    expect(const TransactionFilter(minAmount: 1) == const TransactionFilter(minAmount: 2), isFalse);
    final f = const TransactionFilter(type: TransactionType.expense, minAmount: 5, keyword: 'x')
        .copyWith(minAmount: null, from: DateTime(2026, 9, 1));
    expect(f.minAmount, isNull);
    expect(f.type, TransactionType.expense);
    expect(f.sheetFilterCount, 1);
    expect(f.clearSheet(), const TransactionFilter(type: TransactionType.expense, keyword: 'x'));
  });

  test('recent categories: last 30 days, confirmed only, most used first', () async {
    final now = DateTime(2026, 9, 30, 12);
    await expense(1, DateTime(2026, 9, 29), category: SystemCategories.otherExpense);
    await expense(1, DateTime(2026, 9, 28), category: SystemCategories.food);
    await expense(1, DateTime(2026, 9, 27), category: SystemCategories.food);
    // Older than 30 days: ignored even though most used overall.
    for (var i = 0; i < 3; i++) {
      await expense(1, DateTime(2026, 8, 1), category: SystemCategories.family);
    }
    // Drafts do not count.
    await ledger.create(
      TransactionDraft(
        type: TransactionType.expense,
        amount: 1,
        accountId: 'bca',
        categoryId: 'sys-expense-bills',
        transactionAt: DateTime(2026, 9, 29),
      ),
      status: TransactionStatus.draft,
    );
    await income(1, DateTime(2026, 9, 29));

    expect(await repo.recentCategoryIds(CategoryType.expense, now), [SystemCategories.food, SystemCategories.otherExpense]);
    expect(await repo.recentCategoryIds(CategoryType.income, now), [SystemCategories.salary]);
  });

  test('last used account is the most recently entered transaction', () async {
    expect(await repo.lastUsedAccountId(), isNull);
    await expense(1000, DateTime(2026, 9, 29), account: 'bca');
    // Entered later, dated earlier: still the last used.
    await expense(1000, DateTime(2026, 1, 1), account: 'gopay');
    expect(await repo.lastUsedAccountId(), 'gopay');
  });

  test('day groups keep order and total only confirmed income/expense', () async {
    await income(100000, DateTime(2026, 9, 25, 8));
    await expense(30000, DateTime(2026, 9, 25, 7));
    await transfer(50000, DateTime(2026, 9, 25, 6));
    await ledger.create(
      TransactionDraft(
        type: TransactionType.expense,
        amount: 999,
        accountId: 'bca',
        categoryId: SystemCategories.food,
        transactionAt: DateTime(2026, 9, 25, 5),
      ),
      status: TransactionStatus.draft,
    );
    await expense(20000, DateTime(2026, 9, 24, 23));

    final groups = groupByDay(await repo.search(const TransactionFilter()));
    expect(groups.map((g) => g.day), [DateTime(2026, 9, 25), DateTime(2026, 9, 24)]);
    expect(groups[0].items, hasLength(4));
    expect(groups[0].income, 100000);
    expect(groups[0].expense, 30000);
    expect(groups[0].net, 70000);
    expect(groups[1].expense, 20000);
  });
}
