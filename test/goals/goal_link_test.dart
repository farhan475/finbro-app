import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/finance/finance_service.dart';
import 'package:finbro_app/core/formatting/dates.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/accounts/data/account_repository.dart';
import 'package:finbro_app/features/goals/data/goal_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late FinanceService finance;
  late GoalRepository goals;
  final now = DateTime(2026, 9, 15, 12);

  Future<String> account(String name, int opening, {AccountType type = AccountType.bank}) async {
    final id = 'acc-$name';
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: id, name: name, type: type, openingBalance: Value(opening),
      createdAt: now, updatedAt: now,
    ));
    return id;
  }

  Future<void> transfer(String from, String to, int amount, DateTime at) => ledger.create(TransactionDraft(
    type: TransactionType.transfer, amount: amount, accountId: from,
    transferToAccountId: to, transactionAt: at,
  ));

  Future<String> goal(String name, {GoalType type = GoalType.savings, String? linked}) =>
      goals.create(name: name, type: type, targetAmount: 10000000, linkedAccountId: linked);

  Future<GoalProgress> progress(String id) async => (await finance.goalProgresses(goalId: id)).single;

  setUp(() {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    finance = FinanceService(db, clock: () => now);
    goals = GoalRepository(db);
  });
  tearDown(() => db.close());

  test('linked progress = account balance: opening, transfers in/out, income; future rows ignored', () async {
    final bca = await account('BCA', 20000000);
    final tabungan = await account('Tabungan', 500000, type: AccountType.savings);
    final id = await goal('Liburan', linked: tabungan);

    await transfer(bca, tabungan, 3000000, now.subtract(const Duration(days: 3)));
    await transfer(tabungan, bca, 1000000, now.subtract(const Duration(days: 1)));
    await ledger.create(TransactionDraft(
      type: TransactionType.income, amount: 25000, accountId: tabungan,
      categoryId: SystemCategories.salary, transactionAt: now,
    ));
    await transfer(bca, tabungan, 4000000, now.add(const Duration(days: 2))); // scheduled ahead

    final p = await progress(id);
    final balance = (await finance.accountBalances()).firstWhere((b) => b.account.id == tabungan).balance;
    expect(p.saved, 500000 + 3000000 - 1000000 + 25000);
    expect(p.saved, balance);
    expect(p.isLinked, isTrue);
    expect(p.linkedAccount!.name, 'Tabungan');
    expect(p.percent, closeTo(25.25, 1e-9));
    expect(p.reached, isFalse);
  });

  test('goal reserve and Emergency Fund balance follow the linked balance', () async {
    final bca = await account('BCA', 20000000);
    final darurat = await account('Darurat', 0, type: AccountType.savings);
    final ef = await goal('Emergency Fund', type: GoalType.emergency, linked: darurat);
    final laptop = await goal('Laptop', type: GoalType.custom);
    await goals.addMovement(goalId: laptop, type: MovementType.contribution, amount: 700000);
    await transfer(bca, darurat, 6000000, now);

    expect((await progress(ef)).saved, 6000000);
    final a = await finance.availableToSpendBreakdown(now);
    expect(a.goalReserve, 6000000 + 700000);
    expect((await finance.emergencyStatus(now)).balance, 6000000);

    // Archived goals count for neither.
    await goals.setActive(ef, false);
    expect((await finance.availableToSpendBreakdown(now)).goalReserve, 700000);
    expect((await finance.emergencyStatus(now)).balance, 0);
  });

  test('archived linked account: progress keeps its balance, reserve skips it, no new link', () async {
    final bca = await account('BCA', 10000000);
    final tabungan = await account('Tabungan', 0, type: AccountType.savings);
    final old = await account('Lama', 0, type: AccountType.savings);
    final id = await goal('Rumah', linked: tabungan);
    await transfer(bca, tabungan, 2000000, now);
    await AccountRepository(db).archive(tabungan);
    await AccountRepository(db).archive(old);

    expect((await progress(id)).saved, 2000000);
    final a = await finance.availableToSpendBreakdown(now);
    expect(a.totalBalance, 8000000); // archived balance already outside Total Balance
    expect(a.goalReserve, 0);

    // Keeping the existing link while editing is allowed; linking anew is not.
    await goals.update(id, name: 'Rumah baru', type: GoalType.savings, targetAmount: 10000000, linkedAccountId: tabungan);
    expect((await goals.get(id))!.linkedAccountId, tabungan);
    await expectLater(
      goal('Mobil', linked: old),
      throwsA(isA<LedgerValidationException>().having((e) => e.message, 'message', contains('diarsipkan'))),
    );
    expect([for (final a in await goals.linkableAccounts()) a.id], isEmpty);
    expect([for (final a in await goals.linkableAccounts(goalId: id)) a.id], [tabungan]);
  });

  test('one account backs at most one goal; only Savings accounts can be linked', () async {
    final bca = await account('BCA', 0);
    final tabungan = await account('Tabungan', 0, type: AccountType.savings);
    final free = await account('Bebas', 0, type: AccountType.savings);
    final first = await goal('Liburan', linked: tabungan);
    final second = await goal('Gadget');

    await expectLater(
      goal('Mobil', linked: tabungan),
      throwsA(isA<LedgerValidationException>().having(
        (e) => e.message, 'message',
        'Account "Tabungan" sudah terhubung ke tujuan "Liburan". Satu account Savings hanya bisa untuk satu tujuan.',
      )),
    );
    await expectLater(
      goals.update(second, name: 'Gadget', type: GoalType.savings, targetAmount: 1, linkedAccountId: tabungan),
      throwsA(isA<LedgerValidationException>().having((e) => e.message, 'message', contains('sudah terhubung'))),
    );
    await expectLater(
      goal('Bank', linked: bca),
      throwsA(isA<LedgerValidationException>().having((e) => e.message, 'message', contains('Hanya account Savings'))),
    );
    // The unique index guards writes that bypass the repository.
    await expectLater(
      (db.update(db.goals)..where((g) => g.id.equals(second))).write(GoalsCompanion(linkedAccountId: Value(tabungan))),
      throwsA(anything),
    );

    expect([for (final a in await goals.linkableAccounts()) a.id], [free]);
    expect([for (final a in await goals.linkableAccounts(goalId: first)) a.id], [tabungan, free]);
  });

  test('unlink returns to movements; movements are kept and blocked while linked', () async {
    final bca = await account('BCA', 10000000);
    final tabungan = await account('Tabungan', 0, type: AccountType.savings);
    final id = await goal('Liburan');
    await goals.addMovement(goalId: id, type: MovementType.contribution, amount: 400000);

    await goals.update(id, name: 'Liburan', type: GoalType.savings, targetAmount: 10000000, linkedAccountId: tabungan);
    await transfer(bca, tabungan, 3000000, now);
    expect((await progress(id)).saved, 3000000);
    await expectLater(
      goals.addMovement(goalId: id, type: MovementType.contribution, amount: 1),
      throwsA(isA<LedgerValidationException>().having((e) => e.message, 'message', contains('transfer'))),
    );

    await goals.unlink(id);
    final p = await progress(id);
    expect(p.isLinked, isFalse);
    expect(p.saved, 400000);
    expect((await goals.movements(id)).length, 1);
    expect((await finance.availableToSpendBreakdown(now)).goalReserve, 400000);
  });

  test('deleting the linked account clears the link and the goal falls back', () async {
    final tabungan = await account('Tabungan', 900000, type: AccountType.savings);
    final id = await goal('Liburan');
    await goals.addMovement(goalId: id, type: MovementType.contribution, amount: 250000);
    await goals.update(id, name: 'Liburan', type: GoalType.savings, targetAmount: 10000000, linkedAccountId: tabungan);
    expect((await progress(id)).saved, 900000);

    await AccountRepository(db).delete(tabungan); // no history, so deletable
    expect((await goals.get(id))!.linkedAccountId, isNull);
    expect((await progress(id)).saved, 250000);
  });

  test('development allocation counts net transfers into a linked development goal', () async {
    final bca = await account('BCA', 10000000);
    final kursus = await account('Kursus', 0, type: AccountType.savings);
    await goal('Sertifikasi', type: GoalType.development, linked: kursus);
    await transfer(bca, kursus, 800000, now);
    await transfer(kursus, bca, 300000, now);
    expect(await finance.developmentAllocation(Period.month(now)), 500000);
  });
}
