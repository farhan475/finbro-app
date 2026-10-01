import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/budgets/data/budget_repository.dart';
import 'package:finbro_app/features/budgets/domain/budget_alert_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late BudgetRepository budgets;
  late List<BudgetAlert> alerts;
  late String budgetId;
  const acc = 'acc-bca';
  final now = DateTime(2026, 9, 15, 12);

  setUpAll(() => initializeDateFormatting('id_ID'));

  setUp(() async {
    db = AppDatabase.memory();
    alerts = [];
    final service = BudgetAlertService(db, sink: (a) async => alerts.add(a));
    ledger = LedgerService(db, listeners: () => [service.onLedgerChange]);
    budgets = BudgetRepository(db);
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(
        id: acc,
        name: 'BCA',
        type: AccountType.bank,
        openingBalance: const Value(10000000),
        createdAt: now,
        updatedAt: now,
      ),
    );
    budgetId = await budgets.create(
      categoryId: SystemCategories.food,
      month: now,
      amount: 1000000,
    );
  });
  tearDown(() => db.close());

  Future<String> spend(int amount, {DateTime? at, String category = SystemCategories.food}) =>
      ledger.create(
        TransactionDraft(
          type: TransactionType.expense,
          amount: amount,
          accountId: acc,
          categoryId: category,
          transactionAt: at ?? now,
        ),
      );

  Future<void> edit(String id, int amount) async {
    final tx = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
    final d = TransactionDraft.fromRow(tx);
    await ledger.update(
      id,
      TransactionDraft(
        type: d.type,
        amount: amount,
        accountId: d.accountId,
        categoryId: d.categoryId,
        transactionAt: d.transactionAt,
      ),
    );
  }

  Future<int?> stored() async => (await budgets.get(budgetId))!.lastNotifiedThreshold;

  test('each threshold fires once: 70 → 85 → 100 → over, no spam', () async {
    await spend(700000);
    expect(alerts.map((a) => a.level), [70]);
    expect(alerts.last.body, contains('Budget Food sudah 70%'));

    await spend(100000); // 80%: still attention
    expect(alerts, hasLength(1));

    await spend(50000); // 85%
    expect(alerts.map((a) => a.level), [70, 85]);
    expect(alerts.last.body, 'Budget Food sudah 85% (Rp 850.000 dari Rp 1.000.000).');
    expect(alerts.last.budgetId, budgetId);

    await spend(150000); // 100%
    expect(alerts.last.level, 100);
    expect(alerts.last.body, contains('mencapai batas'));

    await spend(100000); // 110%
    expect(alerts.last.level, 101);
    expect(alerts.last.body, contains('melewati budget'));
    expect(alerts.last.body, contains('lebih Rp 100.000'));

    await spend(10000); // still over
    expect(alerts, hasLength(4));
    expect(await stored(), 101);
  });

  test('jumping several thresholds notifies only the highest', () async {
    await spend(1200000);
    expect(alerts.map((a) => a.level), [101]);
  });

  test('lowering after edit/delete lets a threshold fire again later', () async {
    final big = await spend(900000); // 90% → warning
    expect(alerts.map((a) => a.level), [85]);

    await edit(big, 750000); // 75% → lowered to attention, no alert
    expect(alerts, hasLength(1));
    expect(await stored(), 70);

    await edit(big, 760000); // still attention (already recorded)
    expect(alerts, hasLength(1));

    final extra = await spend(100000); // 86% → warning fires again
    expect(alerts.map((a) => a.level), [85, 85]);

    await ledger.delete(extra); // 76%
    await ledger.delete(big); // 0%
    expect(await stored(), isNull);
    expect(alerts, hasLength(2));

    await spend(700000);
    expect(alerts.last.level, 70);
  });

  test('changing budget amount resets the notified threshold', () async {
    await spend(900000);
    expect(await stored(), 85);
    await budgets.update(budgetId, amount: 1000000, attention: 70, warning: 85, over: 100);
    expect(await stored(), 85, reason: 'unchanged limits keep state');
    await budgets.update(budgetId, amount: 800000, attention: 70, warning: 85, over: 100);
    expect(await stored(), isNull);
    await spend(10000); // 910k / 800k
    expect(alerts.last.level, 101);
  });

  test('ignores other months, categories, income and disabled alerts', () async {
    await spend(900000, at: DateTime(2026, 10, 1));
    await spend(900000, category: 'sys-expense-transport');
    await ledger.create(
      TransactionDraft(
        type: TransactionType.income,
        amount: 5000000,
        accountId: acc,
        categoryId: SystemCategories.salary,
        transactionAt: now,
      ),
    );
    await ledger.create(
      TransactionDraft(
        type: TransactionType.expense,
        amount: 900000,
        accountId: acc,
        categoryId: SystemCategories.food,
        transactionAt: now,
      ),
      status: TransactionStatus.draft,
    );
    expect(alerts, isEmpty);

    await AppSettingsRepository(db).setBool(SettingKeys.budgetAlertsEnabled, false);
    await spend(900000);
    expect(alerts, isEmpty);
    expect(await stored(), isNull);
  });

  test('custom thresholds are respected', () async {
    await budgets.update(budgetId, amount: 1000000, attention: 50, warning: 75, over: 90);
    await spend(500000);
    await spend(250000);
    await spend(160000); // 91% > over 90
    expect(alerts.map((a) => a.level), [50, 75, 91]);
  });
}
