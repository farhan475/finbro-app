import 'package:drift/drift.dart' show TableUpdateQuery, Value;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final now = DateTime(2026, 9, 30, 21);

  setUp(() async {
    db = AppDatabase.memory();
    // First query runs onCreate (seed inserts); finish it before any listener.
    await db.customSelect('SELECT 1').get();
    container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Values emitted by [provider] after its initial tick.
  List<int> ticksOf(StreamProvider<int> provider) {
    final ticks = <int>[];
    container.listen(provider, (_, next) {
      if (next.value case final v? when v > 0) ticks.add(v);
    });
    return ticks;
  }

  Future<void> settle() => Future<void>.delayed(dbChangesCoalesce * 3);

  Future<void> addAccount(String id) => db.into(db.accounts).insert(
    AccountsCompanion.insert(id: id, name: id, type: AccountType.bank, createdAt: now, updatedAt: now),
  );

  test('settings and daily_activity writes do not tick ledger providers', () async {
    final ticks = ticksOf(dbChangesProvider);
    await settle();
    await AppSettingsRepository(db).set(SettingKeys.hideBalance, 'true');
    await db.into(db.dailyActivity).insert(
      DailyActivityCompanion.insert(date: DateTime(2026, 9, 30), status: ActivityStatus.noActivity),
    );
    await settle();
    expect(ticks, isEmpty);
  });

  test('a burst of ledger writes produces one tick', () async {
    final ticks = ticksOf(dbChangesProvider);
    await settle();
    await addAccount('a');
    await addAccount('b');
    await addAccount('c');
    await settle();
    expect(ticks, [1]);

    await addAccount('d');
    await settle();
    expect(ticks, [1, 2]);
  });

  test('activityChangesProvider also ticks on daily_activity writes', () async {
    final ticks = ticksOf(activityChangesProvider);
    await settle();
    await db.into(db.dailyActivity).insert(
      DailyActivityCompanion.insert(date: DateTime(2026, 9, 30), status: ActivityStatus.noActivity),
    );
    await settle();
    expect(ticks, [1]);
    await AppSettingsRepository(db).set(SettingKeys.userName, 'Farhan');
    await settle();
    expect(ticks, [1]);
  });

  test('setting a key to its current value writes nothing', () async {
    final settings = AppSettingsRepository(db);
    var writes = 0;
    final sub = db.tableUpdates(TableUpdateQuery.onTable(db.appSettings)).listen((_) => writes++);
    addTearDown(sub.cancel);

    await settings.set(SettingKeys.themeMode, 'dark');
    await settings.set(SettingKeys.themeMode, 'dark');
    await settings.setBool(SettingKeys.hideBalance, true);
    await settings.setBool(SettingKeys.hideBalance, true);
    await pumpEventQueue();
    expect(writes, 2);

    await settings.set(SettingKeys.themeMode, 'light');
    await pumpEventQueue();
    expect(writes, 3);
    expect(await settings.get(SettingKeys.themeMode), 'light');
  });

  test('a future-dated transaction ticks once its time passes (checked on resume)', () async {
    var t = now;
    container.dispose();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db), clockProvider.overrideWithValue(() => t)],
    );
    await addAccount('a');
    await db.into(db.transactions).insert(
      TransactionsCompanion.insert(
        id: 'tx', type: TransactionType.income, amount: 1000, accountId: 'a',
        categoryId: const Value('sys-income-salary'),
        transactionAt: DateTime(2026, 9, 30, 22), createdAt: now, updatedAt: now,
      ),
    );
    final ticks = ticksOf(dbChangesProvider);
    await settle();
    final check = container.read(timeBoundaryCheckProvider);

    check.check();
    await settle();
    expect(ticks, isEmpty);

    t = DateTime(2026, 9, 30, 22, 0, 1);
    check.check();
    await settle();
    expect(ticks, [1]);
  });
}
