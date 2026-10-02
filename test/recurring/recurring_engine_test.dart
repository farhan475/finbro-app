import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/calendar/domain/daily_check_service.dart';
import 'package:finbro_app/features/recurring/data/recurring_repository.dart';
import 'package:finbro_app/features/recurring/domain/recurring_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late RecurringEngine engine;
  late RecurringRepository repo;
  late DateTime now;
  const bca = 'acc-bca';

  setUp(() async {
    db = AppDatabase.memory();
    now = DateTime(2026, 9, 30, 10);
    final daily = DailyCheckService(db, AppSettingsRepository(db), clock: () => now);
    ledger = LedgerService(db, listeners: () => [daily.onLedgerChange]);
    engine = RecurringEngine(db, ledger, clock: () => now);
    repo = RecurringRepository(db, engine, clock: () => now);
    final t = DateTime(2026, 1, 1);
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(id: bca, name: 'BCA', type: AccountType.bank, createdAt: t, updatedAt: t),
    );
  });
  tearDown(() => db.close());

  RecurringRuleDraft salary({
    int amount = 5000000,
    int day = 25,
    bool autoConfirm = false,
    DateTime? start,
  }) => RecurringRuleDraft(
    type: TransactionType.income,
    name: 'Salary',
    amount: amount,
    accountId: bca,
    categoryId: SystemCategories.salary,
    frequency: RecurringFrequency.monthly,
    dayOfMonth: day,
    startDate: start ?? DateTime(2026, 9, 1),
    autoConfirm: autoConfirm,
  );

  Future<List<RecurringInstance>> instances() => (db.select(db.recurringInstances)
        ..orderBy([(i) => OrderingTerm.asc(i.dueDate)]))
      .get();

  Future<List<LedgerTransaction>> txs() => db.select(db.transactions).get();

  test('generates due and upcoming instances through end of next month', () async {
    await repo.create(salary());
    final list = await instances();
    expect(list.map((i) => i.dueDate), [DateTime(2026, 9, 25), DateTime(2026, 10, 25)]);
    expect(list.map((i) => i.status), [RecurringStatus.pending, RecurringStatus.scheduled]);
    expect(list.every((i) => i.amount == 5000000), isTrue);
  });

  test('monthly rule on the 31st yields 30 Sep', () async {
    now = DateTime(2026, 9, 1, 8);
    await repo.create(salary(day: 31));
    expect((await instances()).map((i) => i.dueDate), [DateTime(2026, 9, 30), DateTime(2026, 10, 31)]);
  });

  test('sync is idempotent: no duplicate instances for the same rule/date', () async {
    await repo.create(salary());
    await engine.sync(now);
    await Future.wait([engine.sync(now), engine.sync(now)]);
    expect(await instances(), hasLength(2));

    now = DateTime(2026, 10, 3, 9);
    await engine.sync(now);
    await engine.sync(now);
    expect((await instances()).map((i) => i.dueDate), [
      DateTime(2026, 9, 25),
      DateTime(2026, 10, 25),
      DateTime(2026, 11, 25),
    ]);
  });

  test('confirm creates exactly one transaction, even on double tap', () async {
    await repo.create(salary());
    final due = (await instances()).first;
    final results = await Future.wait([engine.confirm(due.id), engine.confirm(due.id)]);
    expect(results.whereType<String>(), hasLength(1));
    expect(await engine.confirm(due.id), isNull);

    final all = await txs();
    expect(all, hasLength(1));
    final tx = all.single;
    expect(tx.amount, 5000000);
    expect(tx.type, TransactionType.income);
    expect(tx.sourceType, SourceType.recurring);
    expect(tx.recurringInstanceId, due.id);
    expect(tx.transactionAt, DateTime(2026, 9, 25, 9));

    final after = (await instances()).first;
    expect(after.status, RecurringStatus.confirmed);
    expect(after.transactionId, tx.id);
  });

  test('confirm with adjusted amount/date posts the adjusted values', () async {
    await repo.create(salary());
    final due = (await instances()).first;
    await engine.confirm(due.id, amount: 5250000, date: DateTime(2026, 9, 26));
    final tx = (await txs()).single;
    expect(tx.amount, 5250000);
    expect(tx.transactionAt, DateTime(2026, 9, 26, 9));
  });

  test('skip and cancel create no transaction and close the instance', () async {
    await repo.create(salary());
    final list = await instances();
    expect(await engine.skip(list[0].id), isTrue);
    expect(await engine.cancel(list[1].id), isTrue);
    expect(await engine.confirm(list[0].id), isNull);
    expect(await txs(), isEmpty);
    expect((await instances()).map((i) => i.status), [RecurringStatus.skipped, RecurringStatus.cancelled]);

    // Closed dates are not regenerated.
    await engine.sync(now);
    expect(await instances(), hasLength(2));
  });

  test('auto-confirm posts one transaction per due instance, only once', () async {
    now = DateTime(2026, 9, 1, 8);
    await repo.create(salary(autoConfirm: true));
    now = DateTime(2026, 9, 30, 10);
    await engine.sync(now);
    await engine.sync(now);
    final all = await txs();
    expect(all.map((t) => t.transactionAt), [DateTime(2026, 9, 25, 9)]);
    expect(all.every((t) => t.sourceType == SourceType.recurring), isTrue);
    final list = await instances();
    expect(list.map((i) => i.status), [RecurringStatus.confirmed, RecurringStatus.scheduled]);
  });

  test('a past start date never auto-posts occurrences before the rule was created', () async {
    await repo.create(salary(autoConfirm: true, start: DateTime(2026, 8, 1)));
    await engine.sync(now);
    expect(await txs(), isEmpty);
    expect((await instances()).every((i) => i.dueDate.isAfter(DateTime(2026, 8, 31))), isTrue);
  });

  test('auto-confirm on the due day before reminder time uses now', () async {
    now = DateTime(2026, 9, 25, 7, 15);
    await repo.create(salary(autoConfirm: true));
    expect((await txs()).single.transactionAt, DateTime(2026, 9, 25, 7, 15));
  });

  test('a linked confirmed transaction repairs its open instance instead of posting again', () async {
    await repo.create(salary());
    final due = (await instances()).first;
    await ledger.create(
      TransactionDraft(
        type: TransactionType.income,
        amount: 5000000,
        accountId: bca,
        categoryId: SystemCategories.salary,
        transactionAt: DateTime(2026, 9, 25, 9),
        sourceType: SourceType.recurring,
        recurringInstanceId: due.id,
      ),
    );
    await engine.sync(now);
    expect(await engine.confirm(due.id), isNull);
    expect(await txs(), hasLength(1));
    expect((await instances()).first.status, RecurringStatus.confirmed);
  });

  test('deleting the transaction reopens the instance', () async {
    await repo.create(salary());
    final due = (await instances()).first;
    final txId = await engine.confirm(due.id);
    await ledger.delete(txId!);
    final reopened = (await instances()).first;
    expect(reopened.status, RecurringStatus.pending);
    expect(reopened.transactionId, isNull);
  });

  test('editing a rule updates open snapshots and regenerates the schedule', () async {
    await repo.create(salary());
    final id = (await db.select(db.recurringRules).getSingle()).id;
    final first = (await instances()).first;
    await engine.confirm(first.id);

    now = DateTime(2026, 9, 30, 11);
    await repo.update(id, salary(amount: 6000000, day: 28));
    final list = await instances();
    expect(list.map((i) => i.dueDate), [DateTime(2026, 9, 25), DateTime(2026, 10, 28)]);
    expect(list[0].status, RecurringStatus.confirmed);
    expect(list[0].amount, 5000000);
    expect(list[1].amount, 6000000);
    expect(list[1].status, RecurringStatus.scheduled);
    expect(await txs(), hasLength(1));
  });

  test('deactivate removes future open instances; delete keeps transactions', () async {
    await repo.create(salary());
    final id = (await db.select(db.recurringRules).getSingle()).id;
    await engine.confirm((await instances()).first.id);

    now = DateTime(2026, 9, 30, 11);
    await repo.setActive(id, false);
    expect((await instances()).map((i) => i.status), [RecurringStatus.confirmed]);
    await engine.sync(now);
    expect(await instances(), hasLength(1));

    now = DateTime(2026, 9, 30, 12);
    await repo.setActive(id, true);
    expect((await instances()).map((i) => i.dueDate), [DateTime(2026, 9, 25), DateTime(2026, 10, 25)]);

    await repo.delete(id);
    expect(await instances(), isEmpty);
    expect(await txs(), hasLength(1));
  });

  test('rule validation rejects mismatched category and bad interval', () async {
    expect(
      () => repo.create(
        RecurringRuleDraft(
          type: TransactionType.expense,
          name: 'Internet',
          amount: 300000,
          accountId: bca,
          categoryId: SystemCategories.salary,
          frequency: RecurringFrequency.monthly,
          dayOfMonth: 5,
          startDate: DateTime(2026, 9, 1),
        ),
      ),
      throwsA(isA<LedgerValidationException>()),
    );
    expect(
      () => repo.create(
        RecurringRuleDraft(
          type: TransactionType.expense,
          name: 'Laundry',
          amount: 50000,
          accountId: bca,
          categoryId: SystemCategories.otherExpense,
          frequency: RecurringFrequency.custom,
          intervalDays: 0,
          startDate: DateTime(2026, 9, 1),
        ),
      ),
      throwsA(isA<LedgerValidationException>()),
    );
  });

  test('reminder text and time follow the rule offset', () async {
    await repo.create(salary());
    final rule = await (db.update(db.recurringRules)).writeReturning(
      const RecurringRulesCompanion(reminderOffsetDays: Value(1), reminderTime: Value('08:30')),
    );
    expect(reminderAt(rule.single, DateTime(2026, 10, 25)), DateTime(2026, 10, 24, 8, 30));
    expect(reminderBody(rule.single, 5000000, 'BCA'), 'Salary Rp 5.000.000 dijadwalkan besok ke BCA');
  });
}
