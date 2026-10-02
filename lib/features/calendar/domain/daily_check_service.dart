import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/notifications/notification_service.dart' as notif;
import '../../../core/notifications/notification_service.dart'
    show NotificationIds, NotificationKind, NotificationService, dailyCheckPayload;
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../recurring/domain/due_dates.dart' show daysBetween, monthNames;

final dailyCheckServiceProvider = Provider<DailyCheckService>(
  (ref) => DailyCheckService(
    ref.watch(databaseProvider),
    ref.watch(appSettingsRepositoryProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Days ahead (after today) that get a daily check scheduled.
const dailyCheckWindowDays = 30;

/// Number of confirmed transactions per local date within `[from, toExclusive)`.
Future<Map<DateTime, int>> confirmedTransactionCounts(
  AppDatabase db,
  DateTime from,
  DateTime toExclusive,
) async {
  final rows = await db.customSelect(
    'SELECT substr(transaction_at, 1, 10) AS d, COUNT(*) AS c FROM transactions '
    "WHERE status = 'confirmed' AND transaction_at >= ? AND transaction_at < ? "
    'GROUP BY d',
    variables: [Variable.withString(sqlDateTime(from)), Variable.withString(sqlDateTime(toExclusive))],
    readsFrom: {db.transactions},
  ).get();
  return {for (final r in rows) DateTime.parse(r.read<String>('d')): r.read<int>('c')};
}

/// Keeps `daily_activity` in step with the ledger and schedules the per-date
/// daily check + monthly review notifications (08-notification-calendar).
class DailyCheckService {
  DailyCheckService(
    this.db,
    this.settings, {
    DateTime Function()? clock,
    NotificationService? notifications,
  }) : _clock = clock ?? DateTime.now,
       _notifications = notifications ?? NotificationService.instance;

  final AppDatabase db;
  final AppSettingsRepository settings;
  final DateTime Function() _clock;
  final NotificationService _notifications;

  /// Ledger listener: a date with confirmed transactions becomes ACTIVE (and
  /// its daily check is cancelled); an ACTIVE date left without confirmed
  /// transactions returns to UNKNOWN (and is rescheduled if still ahead).
  Future<void> onLedgerChange(LedgerChange c) async {
    final days = {for (final t in c.rows) dateOnly(t.transactionAt)};
    for (final day in days) {
      await _refreshDay(day);
    }
  }

  Future<void> _refreshDay(DateTime day) async {
    final counts = await confirmedTransactionCounts(db, day, DateTime(day.year, day.month, day.day + 1));
    final row = await _row(day);
    final now = _clock();
    if ((counts[day] ?? 0) > 0) {
      // Already ACTIVE: its daily check was cancelled when it became active.
      if (row?.status == ActivityStatus.active) return;
      await db.into(db.dailyActivity).insertOnConflictUpdate(
        DailyActivityCompanion.insert(date: day, status: ActivityStatus.active, checkedAt: Value(now)),
      );
      await _notifications.cancelDailyCheck(day);
      return;
    }
    if (row?.status != ActivityStatus.active) return;
    await (db.update(db.dailyActivity)..where((d) => d.date.equalsValue(day))).write(
      const DailyActivityCompanion(status: Value(ActivityStatus.unknown), checkedAt: Value(null)),
    );
    final today = dateOnly(now);
    final inWindow = !day.isBefore(today) && daysBetween(today, day) <= dailyCheckWindowDays;
    if (inWindow && await _dailyCheckEnabled()) {
      final t = await _dailyCheckTime();
      await _notifications.scheduleDailyCheck(day, hour: t.$1, minute: t.$2);
    }
  }

  /// "Tidak ada transaksi hari ini": NO_ACTIVITY unless the day already has
  /// confirmed transactions (then it is ACTIVE). Cancels its daily check.
  Future<void> markNoActivity(DateTime day) async {
    final d = dateOnly(day);
    final counts = await confirmedTransactionCounts(db, d, DateTime(d.year, d.month, d.day + 1));
    if ((counts[d] ?? 0) > 0) {
      await _refreshDay(d);
      return;
    }
    await notif.markNoActivity(db, d);
    await _notifications.cancelDailyCheck(d);
  }

  /// Schedules daily checks for today..+[dailyCheckWindowDays] on UNKNOWN
  /// dates only (others are cancelled), and the monthly review for the last
  /// day of this and the next two months. Disabled reminders, and all of
  /// them before onboarding is done, are cancelled.
  ///
  /// Runs on every resume, so it diffs against the pending requests (one
  /// plugin call) and only schedules/cancels what differs: each plugin call
  /// rewrites the plugin's whole stored schedule on the platform thread.
  Future<void> reschedule(DateTime now) async {
    final today = dateOnly(now);
    final end = DateTime(today.year, today.month, today.day + dailyCheckWindowDays + 1);
    final onboarded = await settings.getBool(SettingKeys.onboardingDone);
    final enabled = onboarded && await _dailyCheckEnabled();
    final review = onboarded && await settings.getBool(SettingKeys.monthlyReviewEnabled, fallback: true);
    final t = await _dailyCheckTime();
    final rows = await (db.select(db.dailyActivity)
          ..where(
            (d) => d.date.isBiggerOrEqualValue(sqlDate(today)) & d.date.isSmallerThanValue(sqlDate(end)),
          ))
        .get();
    final status = {for (final r in rows) r.date: r.status};
    final counts = await confirmedTransactionCounts(db, today, end);
    final pending = await _notifications.pendingPayloads();

    Future<void> cancelIfPending(int id) async {
      if (pending.containsKey(id)) await _notifications.cancel(id);
    }

    for (var i = 0; i <= dailyCheckWindowDays; i++) {
      final day = DateTime(today.year, today.month, today.day + i);
      final unknown = (status[day] ?? ActivityStatus.unknown) == ActivityStatus.unknown && (counts[day] ?? 0) == 0;
      if (enabled && unknown) {
        final payload = jsonEncode(dailyCheckPayload(day, hour: t.$1, minute: t.$2));
        if (pending[NotificationIds.dailyCheck(day)] != payload) {
          await _notifications.scheduleDailyCheck(day, hour: t.$1, minute: t.$2);
        }
      } else {
        await cancelIfPending(NotificationIds.dailyCheck(day));
        await cancelIfPending(NotificationIds.dailyCheckLater(day));
      }
    }

    for (var k = 0; k < 3; k++) {
      final month = DateTime(today.year, today.month + k);
      final id = NotificationIds.monthlyReview(month);
      if (!review) {
        await cancelIfPending(id);
        continue;
      }
      final payload = {'kind': NotificationKind.monthlyReview, 'month': isoDate(month).substring(0, 7)};
      if (pending[id] == jsonEncode(payload)) continue;
      final last = monthEnd(month);
      await _notifications.schedule(
        id: id,
        at: DateTime(last.year, last.month, last.day, 19),
        title: 'Monthly review',
        body: monthlyReviewBody(month),
        payload: payload,
      );
    }
  }

  Future<DailyActivityRow?> _row(DateTime day) =>
      (db.select(db.dailyActivity)..where((d) => d.date.equalsValue(day))).getSingleOrNull();

  Future<bool> _dailyCheckEnabled() => settings.getBool(SettingKeys.dailyCheckEnabled, fallback: true);

  Future<(int, int)> _dailyCheckTime() async {
    final t = parseTimeOfDay(await settings.get(SettingKeys.dailyCheckTime));
    return (t.hour, t.minute);
  }
}

/// "Review September: income, expense, budget, goals, dan cash flow."
String monthlyReviewBody(DateTime month) =>
    'Review ${monthNames[month.month - 1]}: income, expense, budget, goals, dan cash flow.';
