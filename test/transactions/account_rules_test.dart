import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/finance/finance_service.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/accounts/data/account_repository.dart';
import 'package:finbro_app/features/accounts/domain/reconciliation.dart';
import 'package:finbro_app/features/categories/data/category_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late AccountRepository accounts;
  late CategoryRepository categories;
  late FinanceService finance;
  final at = DateTime(2026, 9, 15, 12);

  setUp(() {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    accounts = AccountRepository(db);
    categories = CategoryRepository(db);
    finance = FinanceService(db);
  });
  tearDown(() => db.close());

  Future<Account> row(String id) => (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingle();

  Future<int> balanceOf(String id) async =>
      (await finance.accountBalances(includeArchived: true)).firstWhere((b) => b.account.id == id).balance;

  Future<String> spend(String accountId, int amount) => ledger.create(TransactionDraft(
    type: TransactionType.expense,
    amount: amount,
    accountId: accountId,
    categoryId: SystemCategories.food,
    transactionAt: at,
  ));

  group('accounts', () {
    test('create trims name, stores fields and rejects duplicates/empty', () async {
      final id = await accounts.create(name: '  BCA   Utama ', type: AccountType.bank, openingBalance: 1500000, icon: 'bank');
      final a = await row(id);
      expect(a.name, 'BCA Utama');
      expect(a.openingBalance, 1500000);
      expect(a.icon, 'bank');
      expect(a.isActive, isTrue);
      expect(await balanceOf(id), 1500000);

      expect(
        () => accounts.create(name: 'bca utama', type: AccountType.cash, openingBalance: 0),
        throwsA(isA<AccountException>()),
      );
      expect(() => accounts.create(name: '   ', type: AccountType.cash, openingBalance: 0), throwsA(isA<AccountException>()));
    });

    test('update may keep its own name; opening balance change replays balance', () async {
      final id = await accounts.create(name: 'Cash', type: AccountType.cash, openingBalance: 100000);
      await spend(id, 30000);
      await accounts.update(id, name: 'Cash', type: AccountType.cash, openingBalance: 200000, icon: null);
      expect(await balanceOf(id), 170000);
      final other = await accounts.create(name: 'GoPay', type: AccountType.ewallet, openingBalance: 0);
      expect(
        () => accounts.update(other, name: 'CASH', type: AccountType.ewallet, openingBalance: 0),
        throwsA(isA<AccountException>()),
      );
    });

    test('account without history can be deleted', () async {
      final id = await accounts.create(name: 'Jago', type: AccountType.bank, openingBalance: 0);
      expect((await accounts.usage(id)).canDelete, isTrue);
      await accounts.delete(id);
      expect(await (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingleOrNull(), isNull);
    });

    test('account with transactions is never hard-deleted (FR-ACC-003)', () async {
      final id = await accounts.create(name: 'BCA', type: AccountType.bank, openingBalance: 100000);
      await spend(id, 10000);
      final usage = await accounts.usage(id);
      expect(usage.transactions, 1);
      expect(usage.canDelete, isFalse);
      await expectLater(accounts.delete(id), throwsA(isA<AccountException>()));
      expect((await row(id)).name, 'BCA');
    });

    test('transfer destination and drafts also count as history', () async {
      final a = await accounts.create(name: 'A', type: AccountType.bank, openingBalance: 100000);
      final b = await accounts.create(name: 'B', type: AccountType.bank, openingBalance: 0);
      final c = await accounts.create(name: 'C', type: AccountType.bank, openingBalance: 0);
      await ledger.create(TransactionDraft(
        type: TransactionType.transfer,
        amount: 5000,
        accountId: a,
        transferToAccountId: b,
        transactionAt: at,
      ));
      await ledger.create(
        TransactionDraft(
          type: TransactionType.expense,
          amount: 5000,
          accountId: c,
          categoryId: SystemCategories.food,
          transactionAt: at,
        ),
        status: TransactionStatus.draft,
      );
      await expectLater(accounts.delete(b), throwsA(isA<AccountException>()));
      await expectLater(accounts.delete(c), throwsA(isA<AccountException>()));
    });

    test('account used by a recurring rule cannot be deleted', () async {
      final id = await accounts.create(name: 'BCA', type: AccountType.bank, openingBalance: 0);
      await db.into(db.recurringRules).insert(
        RecurringRulesCompanion.insert(
          id: 'r1',
          type: TransactionType.expense,
          name: 'Internet',
          amount: 300000,
          accountId: id,
          categoryId: SystemCategories.otherExpense,
          frequency: RecurringFrequency.monthly,
          startDate: at,
          createdAt: at,
          updatedAt: at,
        ),
      );
      final usage = await accounts.usage(id);
      expect(usage.transactions, 0);
      expect(usage.recurringRules, 1);
      await expectLater(accounts.delete(id), throwsA(isA<AccountException>()));
    });

    test('archive keeps history, leaves total balance, blocks new postings; unarchive restores', () async {
      final bca = await accounts.create(name: 'BCA', type: AccountType.bank, openingBalance: 100000);
      final cash = await accounts.create(name: 'Cash', type: AccountType.cash, openingBalance: 50000);
      final tx = await spend(bca, 20000);

      await accounts.archive(bca);
      expect((await row(bca)).isActive, isFalse);
      expect(await finance.totalBalance(), 50000);
      expect(await balanceOf(bca), 80000);
      expect(await (db.select(db.transactions)..where((t) => t.id.equals(tx))).getSingleOrNull(), isNotNull);
      await expectLater(spend(bca, 1000), throwsA(isA<LedgerValidationException>()));

      await accounts.unarchive(bca);
      expect(await finance.totalBalance(), 130000);
      await spend(bca, 1000);
      expect(await balanceOf(bca), 79000);
      expect(await balanceOf(cash), 50000);
    });
  });

  group('reconciliation', () {
    test('variance sign and matching', () {
      expect(const Reconciliation(calculated: 100000, actual: 120000).variance, 20000);
      expect(const Reconciliation(calculated: 100000, actual: 90000).variance, -10000);
      expect(const Reconciliation(calculated: 5, actual: 5).matches, isTrue);
      expect(const Reconciliation(calculated: 5, actual: 5).adjustment('x', at), isNull);
    });

    test('adjustment posting makes calculated equal actual', () async {
      final id = await accounts.create(name: 'BCA', type: AccountType.bank, openingBalance: 100000);

      final up = const Reconciliation(calculated: 100000, actual: 125000).adjustment(id, at)!;
      expect(up.type, TransactionType.income);
      expect(up.categoryId, SystemCategories.otherIncome);
      expect(up.amount, 25000);
      expect(up.note, reconciliationNote);
      await ledger.create(up);
      expect(await balanceOf(id), 125000);

      final down = Reconciliation(calculated: await balanceOf(id), actual: 100000).adjustment(id, at)!;
      expect(down.type, TransactionType.expense);
      expect(down.categoryId, SystemCategories.otherExpense);
      expect(down.amount, 25000);
      await ledger.create(down);
      expect(await balanceOf(id), 100000);
    });
  });

  group('categories', () {
    const custom = CategoryInput(
      name: 'Kopi',
      type: CategoryType.expense,
      icon: 'coffee',
      planningBucket: PlanningBucket.personal,
      expenseNature: ExpenseNature.discretionary,
    );

    test('system categories can be edited and deactivated but not deleted', () async {
      await categories.update(
        SystemCategories.food,
        const CategoryInput(name: 'Makan', type: CategoryType.expense, icon: 'food', planningBucket: PlanningBucket.essential, expenseNature: ExpenseNature.essential),
      );
      await categories.setActive(SystemCategories.food, false);
      final c = await (db.select(db.categories)..where((c) => c.id.equals(SystemCategories.food))).getSingle();
      expect(c.name, 'Makan');
      expect(c.isActive, isFalse);
      await expectLater(categories.delete(SystemCategories.food), throwsA(isA<CategoryException>()));
    });

    test('custom category deletable only while unused', () async {
      final unused = await categories.create(custom);
      await categories.delete(unused);
      expect(await (db.select(db.categories)..where((c) => c.id.equals(unused))).getSingleOrNull(), isNull);

      final used = await categories.create(custom);
      final acc = await accounts.create(name: 'Cash', type: AccountType.cash, openingBalance: 100000);
      await ledger.create(TransactionDraft(
        type: TransactionType.expense,
        amount: 20000,
        accountId: acc,
        categoryId: used,
        transactionAt: at,
      ));
      expect(await categories.usageCount(used), 1);
      await expectLater(categories.delete(used), throwsA(isA<CategoryException>()));
    });

    test('income categories drop bucket/nature; type is immutable; names unique per type', () async {
      final id = await categories.create(const CategoryInput(
        name: 'Bonus',
        type: CategoryType.income,
        planningBucket: PlanningBucket.savings,
        expenseNature: ExpenseNature.essential,
      ));
      final c = await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingle();
      expect(c.planningBucket, isNull);
      expect(c.expenseNature, isNull);
      expect(c.isSystem, isFalse);

      await expectLater(
        categories.update(id, const CategoryInput(name: 'Bonus', type: CategoryType.expense)),
        throwsA(isA<CategoryException>()),
      );
      await expectLater(
        categories.create(const CategoryInput(name: 'salary', type: CategoryType.income)),
        throwsA(isA<CategoryException>()),
      );
      // Same name under the other type is fine.
      await categories.create(const CategoryInput(name: 'Salary', type: CategoryType.expense));
    });
  });
}
