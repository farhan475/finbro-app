import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/budgets/data/budget_repository.dart';
import 'package:finbro_app/features/goals/data/goal_repository.dart';
import 'package:finbro_app/features/goals/domain/goal_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  late AppDatabase db;
  const transport = 'sys-expense-transport';
  const shopping = 'sys-expense-shopping';

  setUpAll(() => initializeDateFormatting('id_ID'));
  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  group('budgets', () {
    late BudgetRepository repo;
    setUp(() => repo = BudgetRepository(db));

    test('copy from last month skips existing and archived categories', () async {
      final aug = DateTime(2026, 8, 20);
      final sep = DateTime(2026, 9, 1);
      await repo.create(
        categoryId: SystemCategories.food,
        month: aug,
        amount: 1000000,
        attention: 60,
        warning: 80,
        over: 100,
      );
      await repo.create(categoryId: transport, month: aug, amount: 500000);
      await repo.create(categoryId: shopping, month: aug, amount: 300000);
      await repo.create(categoryId: SystemCategories.food, month: sep, amount: 900000);
      await (db.update(db.categories)..where((c) => c.id.equals(shopping)))
          .write(const CategoriesCompanion(isActive: Value(false)));

      expect(await repo.copyFromPreviousMonth(sep), 1);
      final copied = {for (final b in await repo.forMonth(sep)) b.categoryId: b};
      expect(copied.keys, unorderedEquals([SystemCategories.food, transport]));
      expect(copied[SystemCategories.food]!.amount, 900000, reason: 'existing kept');
      final t = copied[transport]!;
      expect(t.amount, 500000);
      expect(t.periodStart, DateTime(2026, 9, 1));
      expect(t.periodEnd, DateTime(2026, 9, 30));
      expect(t.lastNotifiedThreshold, isNull);

      expect(await repo.copyFromPreviousMonth(sep), 0, reason: 'idempotent');
      expect(await repo.copyFromPreviousMonth(DateTime(2026, 12, 1)), 0);
    });

    test('copy keeps thresholds and crosses the year boundary', () async {
      await repo.create(
        categoryId: SystemCategories.food,
        month: DateTime(2026, 12, 5),
        amount: 1000000,
        attention: 60,
        warning: 80,
        over: 110,
      );
      expect(await repo.copyFromPreviousMonth(DateTime(2027, 1, 1)), 1);
      final b = (await repo.forMonth(DateTime(2027, 1, 1))).single;
      expect([b.attentionThreshold, b.warningThreshold, b.overThreshold], [60, 80, 110]);
      expect(b.periodEnd, DateTime(2027, 1, 31));
    });

    test('rejects duplicates, income categories and unordered thresholds', () async {
      final sep = DateTime(2026, 9, 1);
      await repo.create(categoryId: SystemCategories.food, month: sep, amount: 1);
      await expectLater(
        repo.create(categoryId: SystemCategories.food, month: DateTime(2026, 9, 30), amount: 5),
        throwsA(isA<LedgerValidationException>()),
      );
      await expectLater(
        repo.create(categoryId: SystemCategories.salary, month: sep, amount: 5),
        throwsA(isA<LedgerValidationException>()),
      );
      await expectLater(
        repo.create(categoryId: transport, month: sep, amount: 5, attention: 90, warning: 85),
        throwsA(isA<LedgerValidationException>()),
      );
    });
  });

  group('goals', () {
    late GoalRepository repo;
    setUp(() => repo = GoalRepository(db));

    Future<int> current(String id) async => (await repo.get(id))!.currentAmount;

    test('movements are stored signed and rebuild current_amount', () async {
      final id = await repo.create(name: 'Laptop', type: GoalType.custom, targetAmount: 15000000);
      await repo.addMovement(goalId: id, type: MovementType.contribution, amount: 1000000);
      final w = await repo.addMovement(goalId: id, type: MovementType.withdrawal, amount: 300000);
      await repo.addMovement(
        goalId: id,
        type: MovementType.adjustment,
        amount: 100000,
        decrease: true,
      );
      expect(await current(id), 600000);
      expect(
        (await repo.movements(id)).map((m) => m.amount),
        unorderedEquals([1000000, -300000, -100000]),
      );

      await repo.deleteMovement(w);
      expect(await current(id), 900000);

      await expectLater(
        repo.addMovement(goalId: id, type: MovementType.withdrawal, amount: 900001),
        throwsA(isA<LedgerValidationException>()),
      );
      expect(await current(id), 900000);
    });

    test('deleting a movement that would leave a negative balance is rejected', () async {
      final id = await repo.create(name: 'Dana darurat', type: GoalType.emergency, targetAmount: 1000);
      final c = await repo.addMovement(goalId: id, type: MovementType.contribution, amount: 500);
      await repo.addMovement(goalId: id, type: MovementType.withdrawal, amount: 400);
      await expectLater(repo.deleteMovement(c), throwsA(isA<LedgerValidationException>()));
      expect(await current(id), 100);
    });

    test('archived goals reject movements; delete removes history', () async {
      final id = await repo.create(name: 'Kursus', type: GoalType.development, targetAmount: 2000000);
      await repo.addMovement(goalId: id, type: MovementType.contribution, amount: 500000);
      await repo.setActive(id, false);
      await expectLater(
        repo.addMovement(goalId: id, type: MovementType.contribution, amount: 1),
        throwsA(isA<LedgerValidationException>()),
      );
      await repo.delete(id);
      expect(await repo.get(id), isNull);
      expect(await db.select(db.goalMovements).get(), isEmpty);
    });

    test('required monthly contribution counts the current through target month', () {
      final now = DateTime(2026, 9, 15);
      expect(
        requiredMonthlyContribution(
          current: 1000000,
          target: 5000000,
          targetDate: DateTime(2026, 12, 31),
          now: now,
        ),
        1000000,
      );
      expect(
        requiredMonthlyContribution(current: 0, target: 1000, targetDate: DateTime(2026, 11, 1), now: now),
        334,
      );
      expect(
        requiredMonthlyContribution(current: 0, target: 1000, targetDate: DateTime(2026, 9, 1), now: now),
        isNull,
      );
      expect(
        requiredMonthlyContribution(current: 1000, target: 1000, targetDate: DateTime(2026, 9, 1), now: now),
        0,
      );
    });
  });
}
