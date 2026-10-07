import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/recurring/domain/recurring_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_notifications.dart';

/// The app and the periodic background job sync the same database file on
/// two connections, possibly at the same moment.
void main() {
  late Directory tmp;
  late AppDatabase app;
  late AppDatabase background;
  const bca = 'acc-bca';
  const rule = 'rule-1';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('finbro-concurrency-test-');
    final file = File(p.join(tmp.path, 'finbro.sqlite'));
    app = AppDatabase.open(file);
    final t = DateTime(2026, 1, 1);
    // Creates and seeds the file before the second connection opens it.
    await app.into(app.accounts).insert(
      AccountsCompanion.insert(id: bca, name: 'BCA', type: AccountType.bank, createdAt: t, updatedAt: t),
    );
    background = AppDatabase.open(file);
  });

  tearDown(() async {
    await app.close();
    await background.close();
    await tmp.delete(recursive: true);
  });

  Future<void> insertRule({
    required RecurringFrequency frequency,
    required DateTime since,
    int? dayOfMonth,
    int? intervalDays,
  }) => app.into(app.recurringRules).insert(
    RecurringRulesCompanion.insert(
      id: rule,
      type: TransactionType.income,
      name: 'Salary',
      amount: 5000000,
      accountId: bca,
      categoryId: SystemCategories.salary,
      frequency: frequency,
      dayOfMonth: Value(dayOfMonth),
      intervalDays: Value(intervalDays),
      startDate: since,
      autoConfirm: const Value(true),
      createdAt: since,
      updatedAt: since,
    ),
  );

  Future<void> insertInstance(String id, DateTime due, RecurringStatus status) =>
      app.into(app.recurringInstances).insert(
        RecurringInstancesCompanion.insert(
          id: id,
          recurringRuleId: rule,
          dueDate: due,
          amount: 5000000,
          status: status,
          createdAt: due,
          updatedAt: due,
        ),
      );

  RecurringEngine engineOn(AppDatabase db, DateTime now, {FakeNotifications? notifications}) =>
      RecurringEngine(db, LedgerService(db), clock: () => now, notifications: notifications);

  Future<List<RecurringInstance>> instances() =>
      (app.select(app.recurringInstances)..orderBy([(i) => OrderingTerm.asc(i.dueDate)])).get();

  Future<List<LedgerTransaction>> txs() => app.select(app.transactions).get();

  test('syncing on both connections at once creates and posts every instance once', () async {
    final now = DateTime(2026, 9, 30, 10);
    // Daily since 31 Aug; the app was last synced that day, so 1–30 Sep are
    // due (auto-confirmed) and 1 Sep–31 Oct get generated.
    await insertRule(frequency: RecurringFrequency.custom, intervalDays: 1, since: DateTime(2026, 8, 31));
    await insertInstance('seen', DateTime(2026, 8, 31), RecurringStatus.skipped);
    final a = engineOn(app, now);
    final b = engineOn(background, now);

    await Future.wait([a.sync(now), b.sync(now)]);
    await Future.wait([a.sync(now), b.sync(now)]);

    final all = await instances();
    expect(all, hasLength(1 + 61));
    expect(all.map((i) => i.dueDate).toSet(), hasLength(all.length));
    final confirmed = all.where((i) => i.status == RecurringStatus.confirmed).toList();
    expect(confirmed.map((i) => i.dueDate), [for (var d = 1; d <= 30; d++) DateTime(2026, 9, d)]);

    final posted = await txs();
    expect(posted, hasLength(30));
    expect({for (final t in posted) t.recurringInstanceId}, {for (final i in confirmed) i.id});
    expect({for (final t in posted) t.id}, {for (final i in confirmed) i.transactionId});
  });

  test('a rule edit never deletes an instance the other connection just confirmed', () async {
    final now = DateTime(2026, 9, 25, 10);
    await insertRule(frequency: RecurringFrequency.monthly, dayOfMonth: 25, since: DateTime(2026, 8, 1));
    await insertInstance('sep-25', DateTime(2026, 9, 25), RecurringStatus.pending);
    final b = engineOn(background, now);
    final notifications = _HookedNotifications();
    final a = engineOn(app, now, notifications: notifications);
    // The background job syncs (and auto-confirms 25 Sep) exactly while the
    // app regenerates after moving the rule to the 10th: between reading the
    // open instances and removing 25 Sep as off-schedule.
    notifications.beforeNextCancel = () => b.sync(now);

    await a.updateRule(
      rule,
      RecurringRulesCompanion(dayOfMonth: const Value(10), updatedAt: Value(now)),
      now,
    );

    final posted = await txs();
    expect(posted, hasLength(1), reason: 'September is paid once');
    expect(posted.single.recurringInstanceId, 'sep-25');
    final all = await instances();
    expect(all.map((i) => (i.dueDate, i.status)), [
      (DateTime(2026, 9, 25), RecurringStatus.confirmed),
      (DateTime(2026, 10, 10), RecurringStatus.scheduled),
    ]);
  });
}

/// Runs [beforeNextCancel] once, right before the next cancel call.
class _HookedNotifications extends FakeNotifications {
  Future<void> Function()? beforeNextCancel;

  @override
  Future<void> cancel(int id) async {
    final hook = beforeNextCancel;
    beforeNextCancel = null;
    if (hook != null) await hook();
    await super.cancel(id);
  }
}
