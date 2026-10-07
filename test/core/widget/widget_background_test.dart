import 'package:drift/drift.dart' show Value;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/core/widget/widget_background.dart';
import 'package:finbro_app/core/widget/widget_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late AppSettingsRepository settings;
  final now = DateTime(2026, 10, 3, 9, 5);

  setUpAll(() => initializeDateFormatting('id_ID'));

  setUp(() async {
    db = AppDatabase.memory();
    settings = AppSettingsRepository(db);
    final created = DateTime(2026, 10, 1);
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: 'a1',
      name: 'Cash',
      type: AccountType.cash,
      createdAt: created,
      updatedAt: created,
    ));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
      id: 'c',
      name: 'Other income',
      type: CategoryType.income,
      createdAt: created,
      updatedAt: created,
    ));
    await settings.setBool(SettingKeys.onboardingDone, true);
  });

  tearDown(() async => db.close());

  Future<void> addIncome(String id, int amount, DateTime at) => db.into(db.transactions).insert(TransactionsCompanion.insert(
    id: id,
    type: TransactionType.income,
    amount: amount,
    accountId: 'a1',
    categoryId: const Value('c'),
    transactionAt: at,
    createdAt: at,
    updatedAt: at,
  ));

  group('computeWidgetSnapshot', () {
    test('no PIN: total balance with a dated update caption', () async {
      await addIncome('t1', 15000, DateTime(2026, 10, 1));
      final s = await computeWidgetSnapshot(db, now: now);
      expect(s.masked, isFalse);
      expect(s.balanceText, 'Rp 15.000');
      expect(s.updatedText, 'Diperbarui 3 Okt 09:05');
    });

    test('rows dated after now are not counted yet', () async {
      await addIncome('t1', 15000, DateTime(2026, 10, 1));
      await addIncome('t2', 5000, DateTime(2026, 10, 4));
      expect((await computeWidgetSnapshot(db, now: now)).balanceText, 'Rp 15.000');
      expect((await computeWidgetSnapshot(db, now: DateTime(2026, 10, 4, 1))).balanceText, 'Rp 20.000');
    });

    test('PIN set: always masked as locked, even with hide-balance on', () async {
      await settings.set(SettingKeys.pinHash, 'h');
      await settings.set(SettingKeys.pinSalt, 's');
      await settings.setBool(SettingKeys.hideBalance, true);
      final s = await computeWidgetSnapshot(db, now: now);
      expect(s, const WidgetSnapshot(balanceText: widgetMaskedBalance, masked: true, updatedText: 'Terkunci'));
    });

    test('hide-balance toggle masks without a PIN', () async {
      await settings.setBool(SettingKeys.hideBalance, true);
      final s = await computeWidgetSnapshot(db, now: now);
      expect(s, const WidgetSnapshot(balanceText: widgetMaskedBalance, masked: true, updatedText: 'Saldo disembunyikan'));
    });

    test('before onboarding: no amount, asks to open the app', () async {
      await settings.setBool(SettingKeys.onboardingDone, false);
      expect(await computeWidgetSnapshot(db, now: now), WidgetSnapshot.notSetUp);
    });
  });

  group('WidgetSync', () {
    late List<WidgetSnapshot> rendered;
    late WidgetSync sync;

    setUp(() {
      rendered = [];
      sync = WidgetSync(db, render: (s) async => rendered.add(s), clock: () => now, coalesce: Duration.zero)..start();
    });

    tearDown(() => sync.dispose());

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

    test('pushes a new snapshot after a balance change and after masking', () async {
      await addIncome('t1', 15000, DateTime(2026, 10, 1));
      await settle();
      expect(rendered.last.balanceText, 'Rp 15.000');

      await settings.setBool(SettingKeys.hideBalance, true);
      await settle();
      expect(rendered.last.updatedText, 'Saldo disembunyikan');

      await settings.setBool(SettingKeys.hideBalance, false);
      await settle();
      expect(rendered.last.balanceText, 'Rp 15.000');
    });

    test('unrelated settings writes do not re-send an unchanged snapshot; refresh always does', () async {
      await sync.refresh(now);
      expect(rendered, hasLength(1));

      await settings.set(SettingKeys.lastBackupAt, '2026-10-03T09:00:00');
      await settle();
      expect(rendered, hasLength(1));

      await sync.refresh(now);
      expect(rendered, hasLength(2));
    });
  });
}
