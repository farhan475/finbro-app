import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';

final budgetAlertServiceProvider = Provider<BudgetAlertService>(
  (ref) => BudgetAlertService(
    ref.watch(databaseProvider),
    finance: ref.watch(financeServiceProvider),
    settings: ref.watch(appSettingsRepositoryProvider),
  ),
);

/// A budget threshold notification about to be delivered.
class BudgetAlert {
  const BudgetAlert({
    required this.budgetId,
    required this.level,
    required this.title,
    required this.body,
  });
  final String budgetId;

  /// Stored in `budgets.last_notified_threshold` (see [budgetAlertLevel]).
  final int level;
  final String title;
  final String body;
}

typedef BudgetAlertSink = Future<void> Function(BudgetAlert alert);

Future<void> _showNotification(BudgetAlert a) => NotificationService.instance.show(
  id: NotificationIds.budget(a.budgetId),
  title: a.title,
  body: a.body,
  payload: {'kind': NotificationKind.budget, 'budgetId': a.budgetId},
  alert: true,
);

/// Alert level of [b] at [actual] spent: the highest crossed threshold
/// (attention / warning / over), or `overThreshold + 1` once usage is
/// strictly above the over threshold ("melewati budget", status over).
/// Null while below every threshold. Integer math, no float rounding.
int? budgetAlertLevel(int actual, Budget b) {
  if (b.amount > 0 && actual * 100 > b.overThreshold * b.amount) return b.overThreshold + 1;
  return crossedThreshold(actual, b.amount, [b.attentionThreshold, b.warningThreshold, b.overThreshold]);
}

/// FR-NOT-002 / 08 §3: after a confirmed expense changes, notify when a
/// budget covering it crosses a higher threshold than already notified this
/// period. `last_notified_threshold` only moves up by notifying; when usage
/// drops (edit/delete) it is lowered to the level actually crossed so the
/// same threshold can fire again later, but never twice in a row.
class BudgetAlertService {
  BudgetAlertService(
    this.db, {
    FinanceService? finance,
    AppSettingsRepository? settings,
    BudgetAlertSink? sink,
  }) : finance = finance ?? FinanceService(db),
       settings = settings ?? AppSettingsRepository(db),
       _sink = sink ?? _showNotification;

  final AppDatabase db;
  final FinanceService finance;
  final AppSettingsRepository settings;
  final BudgetAlertSink _sink;

  /// Ledger post-commit listener (register in `ledgerListenersProvider`).
  Future<void> onLedgerChange(LedgerChange c) async {
    final touched = <(String, DateTime)>{
      for (final t in c.rows)
        if (t.type == TransactionType.expense &&
            t.status == TransactionStatus.confirmed &&
            t.categoryId != null)
          (t.categoryId!, dateOnly(t.transactionAt)),
    };
    if (touched.isEmpty) return;
    if (!await settings.getBool(SettingKeys.budgetAlertsEnabled, fallback: true)) return;

    final seen = <String>{};
    for (final (categoryId, day) in touched) {
      final budgets = await (db.select(db.budgets)
            ..where(
              (b) =>
                  b.isActive.equals(true) &
                  b.categoryId.equals(categoryId) &
                  b.periodStart.isSmallerOrEqualValue(sqlDate(day)) &
                  b.periodEnd.isBiggerOrEqualValue(sqlDate(day)),
            ))
          .get();
      for (final b in budgets) {
        if (seen.add(b.id)) await _evaluate(b);
      }
    }
  }

  Future<void> _evaluate(Budget b) async {
    final actual = await finance.budgetActual(b);
    final usage = budgetUsage(actual, b.amount);
    final level = budgetAlertLevel(actual, b);
    final stored = b.lastNotifiedThreshold;
    if (level == stored) return;

    if (level != null && (stored == null || level > stored)) {
      await _store(b.id, level);
      final category = await (db.select(db.categories)
            ..where((c) => c.id.equals(b.categoryId)))
          .getSingle();
      await _sink(_message(b, category.name, level, actual, usage));
    } else {
      // Usage dropped below the notified level: lower it (no notification).
      await _store(b.id, level);
    }
  }

  Future<void> _store(String id, int? level) =>
      (db.update(db.budgets)..where((x) => x.id.equals(id))).write(
        BudgetsCompanion(lastNotifiedThreshold: Value(level)),
      );

  static BudgetAlert _message(Budget b, String name, int level, int actual, double usage) {
    final pct = formatPercent(usage);
    final amounts = '${formatRupiah(actual)} dari ${formatRupiah(b.amount)}';
    final status = budgetStatus(
      actual,
      b.amount,
      attention: b.attentionThreshold,
      warning: b.warningThreshold,
      over: b.overThreshold,
    );
    final String body;
    if (level > b.overThreshold) {
      body = 'Pengeluaran $name melewati budget: $pct ($amounts), '
          'lebih ${formatRupiah(actual - b.amount)}.';
    } else if (level == b.overThreshold) {
      body = 'Budget $name sudah mencapai batas: $pct ($amounts).';
    } else {
      body = 'Budget $name sudah $pct ($amounts).';
    }
    return BudgetAlert(
      budgetId: b.id,
      level: level,
      title: 'Budget $name · ${status.label}',
      body: body,
    );
  }
}
