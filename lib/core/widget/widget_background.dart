import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../database/app_database.dart';
import '../finance/finance_math.dart';
import '../finance/finance_service.dart';
import '../formatting/dates.dart';
import '../formatting/money.dart';
import '../settings/app_settings_repository.dart';

/// Method channel between the Android home-screen widget (Kotlin) and Dart.
/// Dart→Kotlin `render`: store the snapshot and update every placed widget
/// (handled by `WidgetChannel` on the app engine, the WorkManager engine and
/// the headless widget engine). Dart→Kotlin `done`: the headless widget
/// engine finished (`WidgetRefreshWorker` then destroys it).
const widgetChannel = MethodChannel('id.finbro.app/widget');

/// Placeholder shown instead of an amount (same as the Home balance card).
const widgetMaskedBalance = 'Rp ••••••';

/// Text tone the widget colors a value with; never the only signal (the
/// text carries an arrow, a sign or a status label).
enum WidgetTone { neutral, positive, warning, negative }

/// Figures shown when the widget is resized taller (owner decision, 7 Okt
/// 2026: the widget grows with its size instead of a toggle). Medium size:
/// [changeText], [incomeText], [expenseText]. Large size additionally:
/// [availableText], [budgetText], [upcomingText]. Only computed when an
/// amount may be shown.
@immutable
class WidgetDetails {
  const WidgetDetails({
    required this.changeText,
    required this.changeTone,
    required this.incomeText,
    required this.expenseText,
    required this.availableText,
    required this.availableTone,
    required this.budgetText,
    required this.budgetTone,
    required this.upcomingText,
    required this.upcomingTone,
  });

  /// `↑ +34% dari bulan lalu` against the month-start balance; null when
  /// that balance was not positive (Home shows no change line then).
  final String? changeText;
  final WidgetTone changeTone;

  /// Confirmed income / expense of the current month.
  final String incomeText;
  final String expenseText;

  final String availableText;
  final WidgetTone availableTone;

  /// Highest-usage budget of the month (`Family · 100% · Limit reached`).
  final String budgetText;
  final WidgetTone budgetTone;

  /// Next open recurring item (`Internet · Besok · -Rp 385.000`).
  final String upcomingText;
  final WidgetTone upcomingTone;

  Map<String, Object?> toArguments() => {
    'changeText': changeText,
    'changeTone': changeTone.name,
    'incomeText': incomeText,
    'expenseText': expenseText,
    'availableText': availableText,
    'availableTone': availableTone.name,
    'budgetText': budgetText,
    'budgetTone': budgetTone.name,
    'upcomingText': upcomingText,
    'upcomingTone': upcomingTone.name,
  };

  @override
  bool operator ==(Object other) => other is WidgetDetails && mapEquals(other.toArguments(), toArguments());

  @override
  int get hashCode => Object.hashAll(toArguments().values);
}

/// What the widget shows for one compute.
@immutable
class WidgetSnapshot {
  const WidgetSnapshot({
    required this.balanceText,
    required this.masked,
    required this.updatedText,
    this.chart = const [],
    this.details,
  });

  /// Before onboarding (or before the app ever created its database): there
  /// is no balance to show yet.
  static const notSetUp = WidgetSnapshot(
    balanceText: 'Rp –',
    masked: false,
    updatedText: 'Buka FinBro untuk mulai',
  );

  /// The database could not be read; never leave an amount on screen.
  static const unavailable = WidgetSnapshot(
    balanceText: widgetMaskedBalance,
    masked: true,
    updatedText: 'Buka FinBro untuk memperbarui',
  );

  /// `Rp 1.234.567` when [masked] is false, [widgetMaskedBalance] otherwise.
  final String balanceText;
  final bool masked;

  /// `Diperbarui 3 Okt 09:05`, `Terkunci` (PIN set) or `Saldo disembunyikan`.
  final String updatedText;

  /// Total Balance path of the current month in rupiah (month start, then
  /// one point per day up to today), drawn as the widget's line chart like
  /// the Home sparkline. Empty whenever no amount may be shown.
  final List<int> chart;

  /// Unmasked total below zero: the widget shows it in red, like Home.
  bool get negative => chart.isNotEmpty && chart.last < 0;

  /// Extra rows for taller widgets; null whenever no amount may be shown.
  final WidgetDetails? details;

  Map<String, Object?> toArguments() => {
    'balanceText': balanceText,
    'updatedText': updatedText,
    'chart': chart,
    'negative': negative,
    ...?details?.toArguments(),
  };

  @override
  bool operator ==(Object other) =>
      other is WidgetSnapshot &&
      other.balanceText == balanceText &&
      other.masked == masked &&
      other.updatedText == updatedText &&
      listEquals(other.chart, chart) &&
      other.details == details;

  @override
  int get hashCode => Object.hash(balanceText, masked, updatedText, Object.hashAll(chart), details);
}

/// Computes what the widget must display from [db].
///
/// Owner decision: while an app-lock PIN is set the widget is ALWAYS masked
/// (`••••••` + `Terkunci`), without exception — the user can disable the lock
/// to see amounts. The in-app hide-balance toggle masks as well
/// (`Saldo disembunyikan`). The caption carries the date so a widget that
/// has not been refreshed for days does not look current. Pure data logic
/// (no platform calls), unit-testable on Linux; needs Indonesian date
/// symbols (`initializeDateFormatting(appLocale)`).
Future<WidgetSnapshot> computeWidgetSnapshot(AppDatabase db, {DateTime? now}) async {
  final settings = AppSettingsRepository(db);
  final pinHash = await settings.get(SettingKeys.pinHash);
  final pinSalt = await settings.get(SettingKeys.pinSalt);
  if ((pinHash?.isNotEmpty ?? false) && (pinSalt?.isNotEmpty ?? false)) {
    return const WidgetSnapshot(balanceText: widgetMaskedBalance, masked: true, updatedText: 'Terkunci');
  }
  if (await settings.getBool(SettingKeys.hideBalance)) {
    return const WidgetSnapshot(balanceText: widgetMaskedBalance, masked: true, updatedText: 'Saldo disembunyikan');
  }
  if (!await settings.getBool(SettingKeys.onboardingDone)) return WidgetSnapshot.notSetUp;

  final clock = now ?? DateTime.now();
  final finance = FinanceService(db, clock: () => clock);
  final path = await finance.monthBalancePath(clock);
  return WidgetSnapshot(
    balanceText: formatRupiah(path.last),
    masked: false,
    updatedText: 'Diperbarui ${formatDayShort(clock)} ${formatTime(clock)}',
    chart: path,
    details: await _details(db, finance, clock, start: path.first, total: path.last),
  );
}

Future<WidgetDetails> _details(AppDatabase db, FinanceService finance, DateTime now, {required int start, required int total}) async {
  final month = await finance.summary(Period.month(now));
  final available = (await finance.availableToSpendBreakdown(now, totalBalance: total, monthIncome: month.income)).value;
  final budgets = await finance.budgetUsages(now);
  final upcoming = await finance.upcomingRecurring(now, limit: 1);

  final change = start > 0 ? percentChange(total, start) : null;
  final budget = budgets.firstOrNull;
  final next = upcoming.firstOrNull;
  String? upcomingAmount;
  if (next != null) {
    final account = await (db.select(db.accounts)..where((a) => a.id.equals(next.rule.accountId))).getSingleOrNull();
    final income = next.rule.type == TransactionType.income;
    upcomingAmount = formatMoney(
      income ? next.instance.amount : -next.instance.amount,
      currencyFromCode(account?.currency) ?? Currency.idr,
      signed: true,
    );
  }
  return WidgetDetails(
    changeText: change == null ? null : '${change >= 0 ? '↑' : '↓'} ${formatChange(change)} dari bulan lalu',
    changeTone: change == null || change.abs() < 0.05
        ? WidgetTone.neutral
        : (change > 0 ? WidgetTone.positive : WidgetTone.negative),
    incomeText: formatRupiah(month.income),
    expenseText: formatRupiah(month.expense),
    availableText: formatRupiah(available),
    availableTone: available < 0 ? WidgetTone.negative : WidgetTone.neutral,
    budgetText: budget == null
        ? 'Belum ada budget bulan ini'
        : '${budget.category.name} · ${formatPercent(budget.usage)} · ${budget.status.label}',
    budgetTone: switch (budget?.status) {
      null || BudgetStatus.normal => WidgetTone.neutral,
      BudgetStatus.attention || BudgetStatus.warning => WidgetTone.warning,
      BudgetStatus.reached || BudgetStatus.over => WidgetTone.negative,
    },
    upcomingText: next == null
        ? 'Tidak ada jadwal $upcomingWindowDays hari ke depan'
        : '${next.rule.name} · ${dueLabel(next.instance.dueDate, now)} · $upcomingAmount',
    upcomingTone: next != null && next.instance.dueDate.isBefore(dateOnly(now)) ? WidgetTone.negative : WidgetTone.neutral,
  );
}

/// Sends [snapshot] to the Android side (`WidgetChannel.render`).
Future<void> renderWidget(WidgetSnapshot snapshot) =>
    widgetChannel.invokeMethod<void>('render', snapshot.toArguments());

/// Headless Dart entrypoint run by `WidgetRefreshWorker` (Kotlin, WorkManager)
/// for system-triggered updates (widget placed or resized, periodic update)
/// when the app itself may not be running: computes one snapshot from disk,
/// renders it and reports `done` so the worker can destroy the engine. While
/// the app runs, `WidgetSync` renders from the app's own connection.
@pragma('vm:entry-point')
Future<void> widgetBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    await initializeDateFormatting(appLocale);
    await _renderFromDisk();
  } finally {
    try {
      await widgetChannel.invokeMethod<void>('done');
    } on MissingPluginException {
      // Not started by the worker; nothing waits for completion.
    }
  }
}

/// Opens the database file (never creates it), computes the snapshot and
/// hands it to Kotlin. Same DB-open pattern as `notificationBackgroundHandler`.
Future<void> _renderFromDisk() async {
  WidgetSnapshot snapshot;
  try {
    if (!await (await databaseFile()).exists()) {
      // Widget placed before the first app launch: opening would create and
      // seed a database outside the app's own startup.
      snapshot = WidgetSnapshot.notSetUp;
    } else {
      final db = await openDeviceDatabase();
      try {
        snapshot = await computeWidgetSnapshot(db);
      } finally {
        await db.close();
      }
    }
  } catch (_) {
    snapshot = WidgetSnapshot.unavailable;
  }
  try {
    await renderWidget(snapshot);
  } on PlatformException {
    // Kotlin side rejected the snapshot; it keeps its last masked state.
  } on MissingPluginException {
    // `render` handler missing on this engine; nothing else to do here.
  }
}
