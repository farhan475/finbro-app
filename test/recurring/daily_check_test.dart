import 'dart:convert';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/core/notifications/notification_service.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/calendar/domain/daily_check_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_notifications.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late DailyCheckService daily;
  final now = DateTime(2026, 9, 30, 21);
  final today = DateTime(2026, 9, 30);
  const bca = 'acc-bca';

  setUp(() async {
    db = AppDatabase.memory();
    daily = DailyCheckService(db, AppSettingsRepository(db), clock: () => now);
    ledger = LedgerService(db, listeners: () => [daily.onLedgerChange]);
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(id: bca, name: 'BCA', type: AccountType.bank, createdAt: now, updatedAt: now),
    );
  });
  tearDown(() => db.close());

  Future<ActivityStatus?> statusOf(DateTime day) async =>
      (await (db.select(db.dailyActivity)..where((d) => d.date.equalsValue(day))).getSingleOrNull())?.status;

  Future<String> expense(DateTime at, {TransactionStatus status = TransactionStatus.confirmed}) => ledger.create(
    TransactionDraft(
      type: TransactionType.expense,
      amount: 35000,
      accountId: bca,
      categoryId: SystemCategories.food,
      transactionAt: at,
    ),
    status: status,
  );

  test('a confirmed transaction marks its date ACTIVE', () async {
    expect(await statusOf(today), isNull);
    await expense(DateTime(2026, 9, 30, 12, 5));
    expect(await statusOf(today), ActivityStatus.active);
  });

  test('deleting the last transaction returns the date to UNKNOWN', () async {
    final a = await expense(DateTime(2026, 9, 30, 8));
    final b = await expense(DateTime(2026, 9, 30, 13));
    await ledger.delete(a);
    expect(await statusOf(today), ActivityStatus.active);
    await ledger.delete(b);
    expect(await statusOf(today), ActivityStatus.unknown);
  });

  test('moving a transaction to another date updates both dates', () async {
    final id = await expense(DateTime(2026, 9, 29, 8));
    final row = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
    final draft = TransactionDraft.fromRow(row);
    await ledger.update(
      id,
      TransactionDraft(
        type: draft.type,
        amount: draft.amount,
        accountId: draft.accountId,
        categoryId: draft.categoryId,
        transactionAt: DateTime(2026, 9, 30, 8),
      ),
    );
    expect(await statusOf(DateTime(2026, 9, 29)), ActivityStatus.unknown);
    expect(await statusOf(today), ActivityStatus.active);
  });

  test('NO_ACTIVITY is only overwritten by ACTIVE', () async {
    await daily.markNoActivity(today);
    expect(await statusOf(today), ActivityStatus.noActivity);

    // Drafts are not activity.
    await expense(DateTime(2026, 9, 30, 9), status: TransactionStatus.draft);
    expect(await statusOf(today), ActivityStatus.noActivity);

    // A transaction on another date leaves it untouched.
    await expense(DateTime(2026, 9, 28, 9));
    expect(await statusOf(today), ActivityStatus.noActivity);

    final id = await expense(DateTime(2026, 9, 30, 10));
    expect(await statusOf(today), ActivityStatus.active);

    // Marking no activity on an ACTIVE day keeps it ACTIVE.
    await daily.markNoActivity(today);
    expect(await statusOf(today), ActivityStatus.active);

    await ledger.delete(id);
    expect(await statusOf(today), ActivityStatus.unknown);
  });

  test('markNoActivity on a day with transactions but no row marks it ACTIVE', () async {
    await expense(DateTime(2026, 9, 27, 9));
    await db.delete(db.dailyActivity).go();
    await daily.markNoActivity(DateTime(2026, 9, 27));
    expect(await statusOf(DateTime(2026, 9, 27)), ActivityStatus.active);
  });

  test('confirmedTransactionCounts groups confirmed rows by local date', () async {
    await expense(DateTime(2026, 9, 29, 23, 59));
    await expense(DateTime(2026, 9, 30, 0, 0));
    await expense(DateTime(2026, 9, 30, 18));
    await expense(DateTime(2026, 9, 30, 19), status: TransactionStatus.draft);
    final counts = await confirmedTransactionCounts(db, DateTime(2026, 9, 1), DateTime(2026, 10, 1));
    expect(counts, {DateTime(2026, 9, 29): 1, today: 2});
  });

  test('a second transaction on an ACTIVE day writes no daily_activity row', () async {
    await expense(DateTime(2026, 9, 30, 8));
    var writes = 0;
    final sub = db.tableUpdates(TableUpdateQuery.onTable(db.dailyActivity)).listen((_) => writes++);
    addTearDown(sub.cancel);
    await expense(DateTime(2026, 9, 30, 12));
    await pumpEventQueue();
    expect(writes, 0);
    expect(await statusOf(today), ActivityStatus.active);
  });

  group('reschedule', () {
    late FakeNotifications notifications;
    late AppSettingsRepository settings;
    late DailyCheckService service;
    final dailyIds = [for (var i = 0; i <= dailyCheckWindowDays; i++) NotificationIds.dailyCheck(DateTime(2026, 9, 30 + i))];
    final reviewIds = [for (var k = 0; k < 3; k++) NotificationIds.monthlyReview(DateTime(2026, 9 + k))];

    setUp(() {
      notifications = FakeNotifications();
      settings = AppSettingsRepository(db);
      service = DailyCheckService(db, settings, clock: () => now, notifications: notifications);
    });

    test('schedules nothing before onboarding is done', () async {
      await service.reschedule(now);
      expect(notifications.pluginCalls, 0);
    });

    test('only schedules or cancels what differs from the pending set', () async {
      await settings.setBool(SettingKeys.onboardingDone, true);
      await service.reschedule(now);
      expect(notifications.scheduled, [...dailyIds, ...reviewIds]);
      expect(notifications.cancelled, isEmpty);

      // Unchanged inputs: a resume costs no plugin calls.
      notifications.resetCalls();
      await service.reschedule(now);
      expect(notifications.pluginCalls, 0);

      // New time: every daily check is replaced, monthly reviews stay.
      notifications.resetCalls();
      await settings.set(SettingKeys.dailyCheckTime, '07:15');
      await service.reschedule(now);
      expect(notifications.scheduled, dailyIds);
      expect(notifications.cancelled, isEmpty);
      expect(
        notifications.pending[NotificationIds.dailyCheck(today)],
        jsonEncode(dailyCheckPayload(today, hour: 7, minute: 15, exact: true)),
      );

      // A day that became NO_ACTIVITY elsewhere: only its pending id is cancelled.
      notifications.resetCalls();
      final tomorrow = DateTime(2026, 10, 1);
      await db.into(db.dailyActivity).insert(
        DailyActivityCompanion.insert(date: tomorrow, status: ActivityStatus.noActivity),
      );
      await service.reschedule(now);
      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled, [NotificationIds.dailyCheck(tomorrow)]);

      // Disabling cancels exactly the pending ones.
      notifications.resetCalls();
      await settings.setBool(SettingKeys.dailyCheckEnabled, false);
      await settings.setBool(SettingKeys.monthlyReviewEnabled, false);
      await service.reschedule(now);
      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled.toSet(), {...dailyIds, ...reviewIds}..remove(NotificationIds.dailyCheck(tomorrow)));
      expect(notifications.pending, isEmpty);
    });

    test('delivery mode follows the exact-alarm permission and setting', () async {
      await settings.setBool(SettingKeys.onboardingDone, true);
      notifications.exactAllowed = false;
      await service.reschedule(now);
      expect(notifications.exact.keys.toSet(), {...dailyIds, ...reviewIds});
      expect(notifications.exact.values, everyElement(isFalse));

      // Unchanged permission: nothing is rescheduled.
      notifications.resetCalls();
      await service.reschedule(now);
      expect(notifications.pluginCalls, 0);

      // Permission granted: every pending reminder is rescheduled exactly once, exact.
      notifications.exactAllowed = true;
      await service.reschedule(now);
      expect(notifications.scheduled, [...dailyIds, ...reviewIds]);
      expect(notifications.cancelled, isEmpty);
      expect(notifications.exact.values, everyElement(isTrue));

      notifications.resetCalls();
      await service.reschedule(now);
      expect(notifications.pluginCalls, 0);

      // Setting off: always inexact, even while Android allows exact alarms.
      await settings.setBool(SettingKeys.exactReminders, false);
      await service.reschedule(now);
      expect(notifications.scheduled, [...dailyIds, ...reviewIds]);
      expect(notifications.exact.values, everyElement(isFalse));
    });
  });

  test('monthly review body names the month', () {
    expect(monthlyReviewBody(DateTime(2026, 9)), 'Review September: income, expense, budget, goals, dan cash flow.');
  });
}
