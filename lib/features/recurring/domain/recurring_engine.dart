import 'package:drift/drift.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../core/utilities/ids.dart';
import 'due_dates.dart';

final recurringEngineProvider = Provider<RecurringEngine>(
  (ref) => RecurringEngine(
    ref.watch(databaseProvider),
    ref.watch(ledgerServiceProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Instances are generated through the end of next month.
DateTime generationHorizon(DateTime now) => monthEnd(DateTime(now.year, now.month + 1));

/// `HH:mm` reminder time of a rule (default 09:00).
TimeOfDay ruleReminderTime(RecurringRule r) =>
    parseTimeOfDay(r.reminderTime, fallback: const TimeOfDay(hour: 9, minute: 0));

/// Transaction time for confirming an instance on [date]: that date at the
/// rule's reminder time, or [now] if that moment is still in the future.
DateTime recurringTransactionAt(RecurringRule rule, DateTime date, DateTime now) {
  final t = ruleReminderTime(rule);
  final at = DateTime(date.year, date.month, date.day, t.hour, t.minute);
  return at.isAfter(now) ? now : at;
}

/// When the reminder for an instance due on [due] fires.
DateTime reminderAt(RecurringRule rule, DateTime due) {
  final t = ruleReminderTime(rule);
  return DateTime(due.year, due.month, due.day - rule.reminderOffsetDays, t.hour, t.minute);
}

/// Notification text, e.g. "Salary Rp 5.000.000 dijadwalkan besok ke BCA".
String reminderBody(RecurringRule rule, int amount, String accountName) {
  final when = switch (rule.reminderOffsetDays) {
    0 => 'hari ini',
    1 => 'besok',
    final n => 'dalam $n hari',
  };
  final dir = rule.type == TransactionType.income ? 'ke' : 'dari';
  return '${rule.name} ${formatRupiah(amount)} dijadwalkan $when $dir $accountName';
}

const _openStatuses = ['scheduled', 'pending'];

/// Generates recurring instances, processes auto-confirm and keeps reminder
/// notifications in sync. Runs on app start/resume (no background service)
/// and after every rule change.
class RecurringEngine {
  RecurringEngine(
    this.db,
    this.ledger, {
    DateTime Function()? clock,
    NotificationService? notifications,
  }) : _clock = clock ?? DateTime.now,
       _notifications = notifications ?? NotificationService.instance;

  final AppDatabase db;
  final LedgerService ledger;
  final DateTime Function() _clock;
  final NotificationService _notifications;

  final _confirming = <String>{};
  Future<void> _tail = Future.value();

  /// Runs [action] after every previously queued sync or rule change, so
  /// they never interleave (an in-flight sync never works from a stale rule).
  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// Idempotent: generates missing instances up to [generationHorizon],
  /// moves due instances to pending, auto-confirms opted-in rules and
  /// (re)schedules reminders. Calls are serialized (never interleave).
  Future<void> sync(DateTime now) => _serialized(() => _sync(now));

  Future<void> _sync(DateTime now) async {
    final today = dateOnly(now);
    await _repairConfirmed(now);

    final rules = await (db.select(db.recurringRules)..where((r) => r.active.equals(true))).get();
    await _generate(rules, now);
    await _normalizeStatuses(today, now);

    for (final rule in rules.where((r) => r.autoConfirm)) {
      final due = await (db.select(db.recurringInstances)
            ..where(
              (i) =>
                  i.recurringRuleId.equals(rule.id) &
                  i.status.isIn(_openStatuses) &
                  // Dates before the rule existed are never posted
                  // automatically (they stay pending for a manual confirm).
                  i.dueDate.isBiggerOrEqualValue(sqlDate(rule.createdAt)) &
                  i.dueDate.isSmallerOrEqualValue(sqlDate(today)),
            )
            ..orderBy([(i) => OrderingTerm.asc(i.dueDate)]))
          .get();
      for (final inst in due) {
        try {
          await confirm(inst.id, now: now);
        } on LedgerValidationException catch (e) {
          AppLogger.error('Auto-confirm rule ${rule.id} ${isoDate(inst.dueDate)} gagal: ${e.message}');
        }
      }
    }
    await _syncReminders(today);
  }

  /// Saves a rule edit or (de)activation ([changes]), then regenerates: open
  /// instances outside the start/end dates or from today on that no longer
  /// match the schedule are removed, remaining open ones get the new amount,
  /// and the schedule is synced. Serialized with [sync].
  Future<void> updateRule(String ruleId, RecurringRulesCompanion changes, DateTime now) =>
      _serialized(() async {
        await (db.update(db.recurringRules)..where((r) => r.id.equals(ruleId))).write(changes);
        await _regenerate(ruleId, now);
        await _sync(now);
      });

  /// Deletes a rule (its instances cascade) after cancelling the reminders
  /// of its open instances. Confirmed transactions stay in the ledger.
  Future<void> deleteRule(String ruleId) => _serialized(() async {
    final open = await (db.select(db.recurringInstances)
          ..where((i) => i.recurringRuleId.equals(ruleId) & i.status.isIn(_openStatuses)))
        .get();
    for (final inst in open) {
      await _notifications.cancel(NotificationIds.recurring(inst.id));
    }
    await (db.delete(db.recurringRules)..where((r) => r.id.equals(ruleId))).go();
  });

  Future<void> _regenerate(String ruleId, DateTime now) async {
    final rule = await (db.select(db.recurringRules)..where((r) => r.id.equals(ruleId))).getSingleOrNull();
    if (rule == null) return;
    final today = dateOnly(now);
    final desired = rule.active
        ? RecurrenceSpec.fromRule(rule).occurrences(today, generationHorizon(now)).toSet()
        : const <DateTime>{};
    final open = await (db.select(db.recurringInstances)
          ..where((i) => i.recurringRuleId.equals(ruleId) & i.status.isIn(_openStatuses)))
        .get();
    final end = rule.endDate;
    for (final inst in open) {
      final outside = inst.dueDate.isBefore(rule.startDate) || (end != null && inst.dueDate.isAfter(end));
      final stale = !inst.dueDate.isBefore(today) && !desired.contains(inst.dueDate);
      if (outside || stale) {
        await _notifications.cancel(NotificationIds.recurring(inst.id));
        await (db.delete(db.recurringInstances)..where((i) => i.id.equals(inst.id))).go();
      } else if (inst.amount != rule.amount) {
        await (db.update(db.recurringInstances)..where((i) => i.id.equals(inst.id))).write(
          RecurringInstancesCompanion(amount: Value(rule.amount), updatedAt: Value(now)),
        );
      }
    }
  }

  /// Confirms an open instance: creates exactly one ledger transaction
  /// (source `recurring`) and links it. [date] defaults to the due date (or
  /// today if earlier); [amount]/[accountId] default to the snapshot/rule.
  /// Returns the new transaction id, or null when nothing was created
  /// (already closed or a confirmation is in flight).
  Future<String?> confirm(
    String instanceId, {
    int? amount,
    DateTime? date,
    String? accountId,
    DateTime? now,
  }) async {
    if (!_confirming.add(instanceId)) return null;
    try {
      final at = now ?? _clock();
      final inst = await (db.select(db.recurringInstances)..where((i) => i.id.equals(instanceId)))
          .getSingleOrNull();
      if (inst == null || !inst.status.isOpen) return null;

      // A linked confirmed transaction already exists (e.g. created outside
      // the engine): link it instead of posting twice.
      final existing = await (db.select(db.transactions)
            ..where(
              (t) =>
                  t.recurringInstanceId.equals(instanceId) &
                  t.status.equalsValue(TransactionStatus.confirmed),
            )
            ..limit(1))
          .getSingleOrNull();
      if (existing != null) {
        await _close(instanceId, RecurringStatus.confirmed, at, transactionId: existing.id);
        return null;
      }

      final rule = await (db.select(db.recurringRules)..where((r) => r.id.equals(inst.recurringRuleId)))
          .getSingle();
      final today = dateOnly(at);
      final day = date ?? (inst.dueDate.isAfter(today) ? today : inst.dueDate);
      final txId = await ledger.create(
        TransactionDraft(
          type: rule.type,
          amount: amount ?? inst.amount,
          accountId: accountId ?? rule.accountId,
          categoryId: rule.categoryId,
          transactionAt: recurringTransactionAt(rule, day, at),
          note: rule.name,
          sourceType: SourceType.recurring,
          recurringInstanceId: instanceId,
        ),
        // Posting and closing commit together; if the instance was closed
        // meanwhile, the posting rolls back.
        inTransaction: (txId) async {
          if (!await _markClosed(instanceId, RecurringStatus.confirmed, at, transactionId: txId)) {
            throw const _InstanceClosed();
          }
        },
      );
      await _notifications.cancel(NotificationIds.recurring(instanceId));
      return txId;
    } on _InstanceClosed {
      return null;
    } finally {
      _confirming.remove(instanceId);
    }
  }

  /// Marks an open instance skipped (no transaction). False if not open or
  /// a confirmation is in flight.
  Future<bool> skip(String instanceId) => _closeManually(instanceId, RecurringStatus.skipped);

  /// Cancels an open instance (no transaction). False if not open or a
  /// confirmation is in flight.
  Future<bool> cancel(String instanceId) => _closeManually(instanceId, RecurringStatus.cancelled);

  Future<bool> _closeManually(String instanceId, RecurringStatus status) async =>
      !_confirming.contains(instanceId) && await _close(instanceId, status, _clock());

  Future<bool> _close(
    String instanceId,
    RecurringStatus status,
    DateTime now, {
    String? transactionId,
  }) async {
    final closed = await _markClosed(instanceId, status, now, transactionId: transactionId);
    await _notifications.cancel(NotificationIds.recurring(instanceId));
    return closed;
  }

  Future<bool> _markClosed(
    String instanceId,
    RecurringStatus status,
    DateTime now, {
    String? transactionId,
  }) async {
    final n = await (db.update(db.recurringInstances)
          ..where((i) => i.id.equals(instanceId) & i.status.isIn(_openStatuses)))
        .write(
          RecurringInstancesCompanion(
            status: Value(status),
            transactionId: transactionId == null ? const Value.absent() : Value(transactionId),
            updatedAt: Value(now),
          ),
        );
    return n > 0;
  }

  Future<void> _repairConfirmed(DateTime now) async {
    final rows = await db.customSelect(
      'SELECT i.id AS iid, t.id AS tid FROM recurring_instances i '
      'JOIN transactions t ON t.recurring_instance_id = i.id '
      "WHERE t.status = 'confirmed' AND i.status IN ('scheduled', 'pending')",
      readsFrom: {db.recurringInstances, db.transactions},
    ).get();
    for (final r in rows) {
      await _close(r.read<String>('iid'), RecurringStatus.confirmed, now, transactionId: r.read<String>('tid'));
    }
  }

  /// Inserts the missing instances of [rules] up to [generationHorizon] in
  /// one batch, and writes nothing when none are missing (a drift batch
  /// always notifies listeners).
  ///
  /// Candidates start at the current recurrence period, or right after the
  /// rule's latest instance when that is earlier (catch-up after the app was
  /// not opened), but never before the period of the rule's creation or last
  /// change: a past start date or an edit does not backfill older periods.
  /// A candidate is dropped when its period already has an instance of any
  /// status, so an edited schedule never adds a second payment to a settled
  /// period, yet the current period keeps its obligation when it has none.
  Future<void> _generate(List<RecurringRule> rules, DateTime now) async {
    if (rules.isEmpty) return;
    final today = dateOnly(now);
    final horizon = generationHorizon(now);
    final latest = {
      for (final r in await db.customSelect(
        'SELECT recurring_rule_id AS rid, MAX(due_date) AS last FROM recurring_instances '
        'GROUP BY recurring_rule_id',
        readsFrom: {db.recurringInstances},
      ).get())
        r.read<String>('rid'): DateTime.parse(r.read<String>('last')),
    };

    final plans = <(RecurringRule, RecurrenceSpec, List<DateTime>)>[];
    for (final rule in rules) {
      final spec = RecurrenceSpec.fromRule(rule);
      final current = spec.periodStart(today);
      final last = latest[rule.id];
      final next = last == null ? current : DateTime(last.year, last.month, last.day + 1);
      final resume = next.isBefore(current) ? next : current;
      final changed = spec.periodStart(rule.updatedAt);
      final dates = spec.occurrences(resume.isAfter(changed) ? resume : changed, horizon);
      if (dates.isNotEmpty) plans.add((rule, spec, dates));
    }
    if (plans.isEmpty) return;

    final lowest = plans.map((p) => p.$2.periodStart(p.$3.first)).reduce((a, b) => a.isBefore(b) ? a : b);
    final existing = <String, List<DateTime>>{};
    final known = await (db.select(db.recurringInstances)
          ..where(
            (i) =>
                i.recurringRuleId.isIn([for (final p in plans) p.$1.id]) &
                i.dueDate.isBiggerOrEqualValue(sqlDate(lowest)),
          ))
        .get();
    for (final inst in known) {
      existing.putIfAbsent(inst.recurringRuleId, () => []).add(inst.dueDate);
    }

    final rows = <RecurringInstancesCompanion>[];
    for (final (rule, spec, dates) in plans) {
      final taken = existing[rule.id] ?? <DateTime>[];
      for (final d in dates) {
        if (taken.any((t) => spec.samePeriod(t, d))) continue;
        taken.add(d);
        rows.add(
          RecurringInstancesCompanion.insert(
            id: newId(),
            recurringRuleId: rule.id,
            dueDate: d,
            amount: rule.amount,
            status: d.isAfter(today) ? RecurringStatus.scheduled : RecurringStatus.pending,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }
    if (rows.isEmpty) return;
    // UNIQUE (recurring_rule_id, due_date) keeps generation idempotent.
    await db.batch((b) => b.insertAll(db.recurringInstances, rows, mode: InsertMode.insertOrIgnore));
  }

  Future<void> _normalizeStatuses(DateTime today, DateTime now) async {
    await (db.update(db.recurringInstances)
          ..where(
            (i) =>
                i.status.equalsValue(RecurringStatus.scheduled) &
                i.dueDate.isSmallerOrEqualValue(sqlDate(today)),
          ))
        .write(RecurringInstancesCompanion(status: const Value(RecurringStatus.pending), updatedAt: Value(now)));
    // A reopened future instance (its transaction was deleted) is scheduled again.
    await (db.update(db.recurringInstances)
          ..where(
            (i) => i.status.equalsValue(RecurringStatus.pending) & i.dueDate.isBiggerThanValue(sqlDate(today)),
          ))
        .write(RecurringInstancesCompanion(status: const Value(RecurringStatus.scheduled), updatedAt: Value(now)));
  }

  Future<void> _syncReminders(DateTime today) async {
    final pending = (await _notifications.pendingPayloads()).keys.toSet();
    final q = db.select(db.recurringInstances).join([
      innerJoin(db.recurringRules, db.recurringRules.id.equalsExp(db.recurringInstances.recurringRuleId)),
    ])..where(db.recurringInstances.dueDate.isBiggerOrEqualValue(sqlDate(today)));
    final rows = await q.get();
    final accounts = rows.isEmpty
        ? const <String, String>{}
        : {for (final a in await db.select(db.accounts).get()) a.id: a.name};
    final wanted = <int>{};
    for (final row in rows) {
      final inst = row.readTable(db.recurringInstances);
      final rule = row.readTable(db.recurringRules);
      final id = NotificationIds.recurring(inst.id);
      if (!inst.status.isOpen || !rule.active || !rule.reminderEnabled) continue;
      wanted.add(id);
      await _notifications.schedule(
        id: id,
        at: reminderAt(rule, inst.dueDate),
        title: rule.type == TransactionType.income ? 'Income terjadwal' : 'Expense terjadwal',
        body: reminderBody(rule, inst.amount, accounts[rule.accountId] ?? '-'),
        payload: {'kind': NotificationKind.recurring, 'instanceId': inst.id},
      );
    }
    // Every other pending recurring reminder is obsolete: its instance was
    // closed, its rule changed, or the instance no longer exists (e.g. the
    // database was replaced by a restore).
    for (final id in pending) {
      if (NotificationIds.isRecurring(id) && !wanted.contains(id)) {
        await _notifications.cancel(id);
      }
    }
  }
}

/// Thrown inside the confirm transaction when the instance is no longer open.
class _InstanceClosed implements Exception {
  const _InstanceClosed();
}
