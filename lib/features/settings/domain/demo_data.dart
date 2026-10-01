import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/seed.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../core/utilities/ids.dart';

/// Debug-only sample data (TODO Release: "Demo data toggle for development").
final demoDataProvider = Provider<DemoData>(
  (ref) => DemoData(ref.watch(databaseProvider), attachmentsDir: AttachmentStorage.directory),
);

class DemoData {
  DemoData(this.db, {required this.attachmentsDir});

  final AppDatabase db;
  final Future<Directory> Function() attachmentsDir;

  /// Accounts BCA/GoPay/SeaBank/Cash (reused by name if they exist), three
  /// months of income/expense/transfers up to [now], budgets and goals.
  /// Returns the number of transactions created.
  Future<int> seed(DateTime now) async {
    final bca = await _account('BCA', AccountType.bank, 5000000, 'bank');
    final gopay = await _account('GoPay', AccountType.ewallet, 150000, 'ewallet');
    final seabank = await _account('SeaBank', AccountType.bank, 2000000, 'savings');
    final cash = await _account('Cash', AccountType.cash, 300000, 'cash');

    // Listener-free ledger: demo history must not fire budget notifications.
    final ledger = LedgerService(db);
    final rnd = Random(7);
    var created = 0;

    Future<void> add(TransactionType type, DateTime at, int amount, String account,
        {String? category, String? to, String? note}) async {
      if (at.isAfter(now)) return;
      await ledger.create(TransactionDraft(
        type: type,
        amount: amount,
        accountId: account,
        categoryId: category,
        transferToAccountId: to,
        transactionAt: at,
        note: note,
      ));
      created++;
    }

    Future<void> expense(DateTime at, int amount, String account, String category, String note) =>
        add(TransactionType.expense, at, amount, account, category: category, note: note);
    Future<void> transfer(DateTime at, int amount, String from, String to, String note) =>
        add(TransactionType.transfer, at, amount, from, to: to, note: note);
    int pick(List<int> options) => options[rnd.nextInt(options.length)];

    for (var k = 2; k >= 0; k--) {
      final m = DateTime(now.year, now.month - k);
      DateTime d(int day, [int hour = 12, int minute = 0]) => DateTime(m.year, m.month, day, hour, minute);
      final days = monthEnd(m).day;

      await add(TransactionType.income, d(1, 9), 8500000, bca,
          category: SystemCategories.salary, note: 'Gaji bulanan');
      if (k == 1) {
        await add(TransactionType.income, d(12, 16), 1750000, seabank,
            category: 'sys-income-freelance', note: 'Project desain landing page');
      }
      await add(TransactionType.income, d(days, 8), 18500, seabank,
          category: 'sys-income-interest', note: 'Bunga tabungan');

      await transfer(d(2, 10), 1500000, bca, seabank, 'Sisihkan tabungan');
      await transfer(d(2, 10, 5), 500000, bca, gopay, 'Top up GoPay');
      await transfer(d(16, 10), 400000, bca, gopay, 'Top up GoPay');
      await transfer(d(3, 11), 700000, bca, cash, 'Tarik tunai');

      await expense(d(3, 19), 1000000, bca, SystemCategories.family, 'Kiriman untuk orang tua');
      await expense(d(5, 20), 350000, bca, 'sys-expense-bills', 'Listrik PLN');
      await expense(d(5, 20, 10), 385000, bca, 'sys-expense-bills', 'Internet rumah');
      await expense(d(10, 9), 100000, gopay, 'sys-expense-bills', 'Pulsa & data');
      await expense(d(8, 7), 54990, bca, 'sys-expense-subscription', 'Spotify');
      await expense(d(20, 21), 250000, bca, 'sys-expense-development', 'Kursus online');
      await expense(d(14, 17), 85000, cash, 'sys-expense-health', 'Apotek');
      await expense(d(22, 15), 120000, bca, 'sys-expense-personal-care', 'Potong rambut & skincare');
      await expense(d(9, 20), pick([189000, 245000, 329000, 415000]), bca, 'sys-expense-shopping', 'Belanja online');
      await expense(d(24, 18), pick([150000, 210000, 275000]), bca, 'sys-expense-shopping', 'Kebutuhan rumah');
      await expense(d(13, 20), pick([55000, 75000, 100000]), gopay, 'sys-expense-entertainment', 'Nonton bioskop');
      await expense(d(27, 21), pick([60000, 120000, 150000]), bca, 'sys-expense-entertainment', 'Nongkrong');

      for (var day = 1; day <= days; day++) {
        final wallet = day.isOdd ? gopay : cash;
        await expense(d(day, 12, 15), pick([18000, 22000, 25000, 32000, 38000]), wallet,
            SystemCategories.food, 'Makan siang');
        if (rnd.nextInt(3) == 0) {
          await expense(d(day, 19, 30), pick([15000, 28000, 45000, 60000]), gopay,
              SystemCategories.food, 'Makan malam');
        }
        if (day % 3 == 0) {
          await expense(d(day, 8, 10), pick([14000, 18000, 23000, 31000]), gopay,
              'sys-expense-transport', 'Ojek online');
        }
        if (day % 7 == 1) {
          await expense(d(day, 7, 30), 50000, cash, 'sys-expense-transport', 'Bensin');
        }
      }
    }

    await _budgets(now);
    await _goals(now);
    AppLogger.info('Data demo dibuat: $created transaksi');
    return created;
  }

  /// Deletes every row and attachment file, then re-seeds default categories
  /// and planning. Onboarding starts again because app_settings is cleared.
  Future<void> wipeAll() async {
    await db.transaction(() async {
      for (final table in <TableInfo<Table, Object?>>[
        db.attachments,
        db.goalMovements,
        db.recurringInstances,
        db.budgets,
        db.merchantMappings,
        db.transactions,
        db.recurringRules,
        db.goals,
        db.accounts,
        db.categories,
        db.planningSettings,
        db.dailyActivity,
        db.backups,
        db.appSettings,
      ]) {
        await db.delete(table).go();
      }
      await seedDefaults(db);
    });
    final dir = await attachmentsDir();
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
    AppLogger.info('Semua data dihapus (debug)');
  }

  Future<String> _account(String name, AccountType type, int opening, String icon) async {
    final existing = await (db.select(db.accounts)..where((a) => a.name.lower().equals(name.toLowerCase())))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    final id = newId();
    final t = DateTime.now();
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: id,
      name: name,
      type: type,
      icon: Value(icon),
      openingBalance: Value(opening),
      createdAt: t,
      updatedAt: t,
    ));
    return id;
  }

  Future<void> _budgets(DateTime now) async {
    const plan = {
      'sys-expense-food': 1500000,
      'sys-expense-transport': 600000,
      'sys-expense-bills': 900000,
      'sys-expense-shopping': 550000,
      'sys-expense-entertainment': 250000,
      'sys-expense-family': 1000000,
    };
    final t = DateTime.now();
    for (final month in [DateTime(now.year, now.month - 1), monthStart(now)]) {
      for (final e in plan.entries) {
        await db.into(db.budgets).insert(
          BudgetsCompanion.insert(
            id: newId(),
            categoryId: e.key,
            periodStart: month,
            periodEnd: monthEnd(month),
            amount: e.value,
            createdAt: t,
            updatedAt: t,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    }
  }

  Future<void> _goals(DateTime now) async {
    final t = DateTime.now();
    final goals = [
      (name: 'Emergency Fund', type: GoalType.emergency, target: 25000000, monthly: 1000000, initial: 2000000, due: null),
      (name: 'MacBook', type: GoalType.custom, target: 18000000, monthly: 750000, initial: 0, due: addMonths(now, 10)),
      (name: 'Development Fund', type: GoalType.development, target: 5000000, monthly: 300000, initial: 0, due: null),
    ];
    for (final (i, g) in goals.indexed) {
      final id = newId();
      await db.into(db.goals).insert(GoalsCompanion.insert(
        id: id,
        name: g.name,
        type: g.type,
        targetAmount: g.target,
        monthlyTarget: Value(g.monthly),
        targetDate: Value(g.due == null ? null : dateOnly(g.due!)),
        priority: Value(i),
        createdAt: t,
        updatedAt: t,
      ));
      Future<void> move(DateTime at, int amount, String note) => db.into(db.goalMovements).insert(
        GoalMovementsCompanion.insert(
          id: newId(),
          goalId: id,
          amount: amount,
          movementType: MovementType.contribution,
          movementAt: at,
          note: Value(note),
        ),
      );
      if (g.initial > 0) await move(DateTime(now.year, now.month - 2, 1, 12), g.initial, 'Saldo awal');
      for (var k = 2; k >= 0; k--) {
        final at = DateTime(now.year, now.month - k, 2, 12);
        if (!at.isAfter(now)) await move(at, g.monthly, 'Setoran bulanan');
      }
      await recomputeGoalAmount(db, id);
    }
  }
}
