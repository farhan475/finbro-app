import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/ids.dart';
import '../domain/recurring_engine.dart';

final recurringRepositoryProvider = Provider<RecurringRepository>(
  (ref) => RecurringRepository(
    ref.watch(databaseProvider),
    ref.watch(recurringEngineProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Instance together with its rule.
class InstanceView {
  const InstanceView(this.instance, this.rule);
  final RecurringInstance instance;
  final RecurringRule rule;

  /// Signed expected amount (+income / -expense).
  int get signedAmount => rule.type == TransactionType.income ? instance.amount : -instance.amount;
}

class RuleOverview {
  const RuleOverview(this.rule, this.next, this.pendingCount);
  final RecurringRule rule;

  /// Earliest open instance (pending or scheduled), if any.
  final RecurringInstance? next;
  final int pendingCount;
}

class RuleDetail {
  const RuleDetail(this.rule, this.instances);
  final RecurringRule rule;

  /// All instances, newest due date first.
  final List<RecurringInstance> instances;
}

/// All rules (active first) with next due and pending count.
final recurringRulesProvider = FutureProvider.autoDispose<List<RuleOverview>>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(recurringRepositoryProvider).overview();
});

final recurringRuleDetailProvider = FutureProvider.autoDispose.family<RuleDetail?, String>((ref, id) {
  ref.watch(dbChangesProvider);
  return ref.watch(recurringRepositoryProvider).detail(id);
});

/// Open instances (pending first, then upcoming scheduled) ordered by due date.
final openInstancesProvider = FutureProvider.autoDispose<List<InstanceView>>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(recurringRepositoryProvider).openInstances();
});

final instanceViewProvider = FutureProvider.autoDispose.family<InstanceView?, String>((ref, id) {
  ref.watch(dbChangesProvider);
  return ref.watch(recurringRepositoryProvider).instance(id);
});

/// Editable fields of a recurring rule. Only the fields relevant to
/// [frequency] are stored; the others are cleared.
class RecurringRuleDraft {
  const RecurringRuleDraft({
    required this.type,
    required this.name,
    required this.amount,
    required this.accountId,
    required this.categoryId,
    required this.frequency,
    required this.startDate,
    this.endDate,
    this.dayOfWeek,
    this.dayOfMonth,
    this.monthOfYear,
    this.intervalDays,
    this.reminderEnabled = true,
    this.reminderOffsetDays = 0,
    this.reminderTime = '09:00',
    this.autoConfirm = false,
  });

  factory RecurringRuleDraft.fromRule(RecurringRule r) => RecurringRuleDraft(
    type: r.type,
    name: r.name,
    amount: r.amount,
    accountId: r.accountId,
    categoryId: r.categoryId,
    frequency: r.frequency,
    startDate: r.startDate,
    endDate: r.endDate,
    dayOfWeek: r.dayOfWeek,
    dayOfMonth: r.dayOfMonth,
    monthOfYear: r.monthOfYear,
    intervalDays: r.intervalDays,
    reminderEnabled: r.reminderEnabled,
    reminderOffsetDays: r.reminderOffsetDays,
    reminderTime: r.reminderTime,
    autoConfirm: r.autoConfirm,
  );

  final TransactionType type;
  final String name;
  final int amount;
  final String accountId;
  final String categoryId;
  final RecurringFrequency frequency;
  final DateTime startDate;
  final DateTime? endDate;
  final int? dayOfWeek;
  final int? dayOfMonth;
  final int? monthOfYear;
  final int? intervalDays;
  final bool reminderEnabled;

  /// 0 = H, 1 = H-1, 3 = H-3.
  final int reminderOffsetDays;

  /// `HH:mm`.
  final String reminderTime;
  final bool autoConfirm;
}

/// Allowed reminder offsets (08-notification-calendar §4).
const reminderOffsets = [0, 1, 3];

String reminderOffsetLabel(int days) => days == 0 ? 'H (hari-H)' : 'H-$days';

class RecurringRepository {
  RecurringRepository(this.db, this.engine, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final RecurringEngine engine;
  final DateTime Function() _clock;

  Future<String> create(RecurringRuleDraft d) async {
    await _validate(d);
    final id = newId();
    final now = _clock();
    await db.into(db.recurringRules).insert(
      RecurringRulesCompanion.insert(
        id: id,
        type: d.type,
        name: d.name.trim(),
        amount: d.amount,
        accountId: d.accountId,
        categoryId: d.categoryId,
        frequency: d.frequency,
        intervalDays: Value(d.frequency == RecurringFrequency.custom ? d.intervalDays : null),
        dayOfMonth: Value(_usesDayOfMonth(d.frequency) ? d.dayOfMonth : null),
        dayOfWeek: Value(d.frequency == RecurringFrequency.weekly ? d.dayOfWeek : null),
        monthOfYear: Value(d.frequency == RecurringFrequency.yearly ? d.monthOfYear : null),
        startDate: dateOnly(d.startDate),
        endDate: Value(d.endDate == null ? null : dateOnly(d.endDate!)),
        reminderEnabled: Value(d.reminderEnabled),
        reminderOffsetDays: Value(d.reminderOffsetDays),
        reminderTime: Value(d.reminderTime),
        autoConfirm: Value(d.autoConfirm),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await engine.sync(now);
    return id;
  }

  /// Saves an edit and regenerates open instances (amount snapshots of open
  /// instances follow the new amount). The current period keeps one
  /// obligation; periods already settled get no second one.
  Future<void> update(String id, RecurringRuleDraft d) async {
    await _validate(d, ruleId: id);
    final now = _clock();
    await engine.updateRule(
      id,
      RecurringRulesCompanion(
        type: Value(d.type),
        name: Value(d.name.trim()),
        amount: Value(d.amount),
        accountId: Value(d.accountId),
        categoryId: Value(d.categoryId),
        frequency: Value(d.frequency),
        intervalDays: Value(d.frequency == RecurringFrequency.custom ? d.intervalDays : null),
        dayOfMonth: Value(_usesDayOfMonth(d.frequency) ? d.dayOfMonth : null),
        dayOfWeek: Value(d.frequency == RecurringFrequency.weekly ? d.dayOfWeek : null),
        monthOfYear: Value(d.frequency == RecurringFrequency.yearly ? d.monthOfYear : null),
        startDate: Value(dateOnly(d.startDate)),
        endDate: Value(d.endDate == null ? null : dateOnly(d.endDate!)),
        reminderEnabled: Value(d.reminderEnabled),
        reminderOffsetDays: Value(d.reminderOffsetDays),
        reminderTime: Value(d.reminderTime),
        autoConfirm: Value(d.autoConfirm),
        updatedAt: Value(now),
      ),
      now,
    );
  }

  /// Deactivating removes open instances from today on; history stays.
  /// Reactivating schedules again from the current period (no older
  /// backfill).
  Future<void> setActive(String id, bool active) async {
    final now = _clock();
    await engine.updateRule(id, RecurringRulesCompanion(active: Value(active), updatedAt: Value(now)), now);
  }

  /// Deletes the rule: open instances and their reminders are cancelled.
  /// Confirmed transactions stay in the ledger.
  Future<void> delete(String id) => engine.deleteRule(id);

  Future<List<RuleOverview>> overview() async {
    final rules = await (db.select(db.recurringRules)
          ..orderBy([(r) => OrderingTerm.desc(r.active), (r) => OrderingTerm.asc(r.name)]))
        .get();
    final open = await (db.select(db.recurringInstances)
          ..where((i) => i.status.isIn(const ['scheduled', 'pending']))
          ..orderBy([(i) => OrderingTerm.asc(i.dueDate)]))
        .get();
    final next = <String, RecurringInstance>{};
    final pending = <String, int>{};
    for (final i in open) {
      next.putIfAbsent(i.recurringRuleId, () => i);
      if (i.status == RecurringStatus.pending) {
        pending[i.recurringRuleId] = (pending[i.recurringRuleId] ?? 0) + 1;
      }
    }
    return [for (final r in rules) RuleOverview(r, next[r.id], pending[r.id] ?? 0)];
  }

  Future<RuleDetail?> detail(String id) async {
    final rule = await (db.select(db.recurringRules)..where((r) => r.id.equals(id))).getSingleOrNull();
    if (rule == null) return null;
    final instances = await (db.select(db.recurringInstances)
          ..where((i) => i.recurringRuleId.equals(id))
          ..orderBy([(i) => OrderingTerm.desc(i.dueDate)]))
        .get();
    return RuleDetail(rule, instances);
  }

  Future<InstanceView?> instance(String id) async {
    final q = _joined()..where(db.recurringInstances.id.equals(id));
    final row = await q.getSingleOrNull();
    return row == null ? null : _view(row);
  }

  Future<List<InstanceView>> openInstances({int limit = 50}) async {
    final q = _joined()
      ..where(db.recurringInstances.status.isIn(const ['scheduled', 'pending']))
      ..orderBy([OrderingTerm.asc(db.recurringInstances.dueDate)])
      ..limit(limit);
    return (await q.get()).map(_view).toList();
  }

  /// Instances due within `[from, to]` (date-only, inclusive).
  Future<List<InstanceView>> instancesBetween(DateTime from, DateTime to) async {
    final q = _joined()
      ..where(
        db.recurringInstances.dueDate.isBiggerOrEqualValue(sqlDate(from)) &
            db.recurringInstances.dueDate.isSmallerOrEqualValue(sqlDate(to)),
      )
      ..orderBy([OrderingTerm.asc(db.recurringInstances.dueDate)]);
    return (await q.get()).map(_view).toList();
  }

  JoinedSelectStatement<HasResultSet, dynamic> _joined() => db.select(db.recurringInstances).join([
    innerJoin(db.recurringRules, db.recurringRules.id.equalsExp(db.recurringInstances.recurringRuleId)),
  ]);

  InstanceView _view(TypedResult row) =>
      InstanceView(row.readTable(db.recurringInstances), row.readTable(db.recurringRules));

  static bool _usesDayOfMonth(RecurringFrequency f) =>
      f == RecurringFrequency.monthly || f == RecurringFrequency.yearly;

  Future<void> _validate(RecurringRuleDraft d, {String? ruleId}) async {
    final name = d.name.trim();
    if (name.isEmpty) throw const LedgerValidationException('Nama wajib diisi.');
    if (name.length > 60) throw const LedgerValidationException('Nama maksimal 60 karakter.');
    if (d.type == TransactionType.transfer) {
      throw const LedgerValidationException('Recurring hanya untuk Income atau Expense.');
    }
    if (d.amount <= 0) throw const LedgerValidationException('Nominal harus lebih dari 0.');
    switch (d.frequency) {
      case RecurringFrequency.weekly:
        if (d.dayOfWeek == null || d.dayOfWeek! < 1 || d.dayOfWeek! > 7) {
          throw const LedgerValidationException('Pilih hari dalam minggu.');
        }
      case RecurringFrequency.monthly:
        if (d.dayOfMonth == null || d.dayOfMonth! < 1 || d.dayOfMonth! > 31) {
          throw const LedgerValidationException('Pilih tanggal 1–31.');
        }
      case RecurringFrequency.yearly:
        if (d.monthOfYear == null || d.monthOfYear! < 1 || d.monthOfYear! > 12) {
          throw const LedgerValidationException('Pilih bulan.');
        }
        if (d.dayOfMonth == null || d.dayOfMonth! < 1 || d.dayOfMonth! > 31) {
          throw const LedgerValidationException('Pilih tanggal 1–31.');
        }
      case RecurringFrequency.custom:
        if (d.intervalDays == null || d.intervalDays! < 1 || d.intervalDays! > 3650) {
          throw const LedgerValidationException('Interval harus 1–3650 hari.');
        }
    }
    final end = d.endDate;
    if (end != null && dateOnly(end).isBefore(dateOnly(d.startDate))) {
      throw const LedgerValidationException('Tanggal selesai tidak boleh sebelum tanggal mulai.');
    }
    if (!reminderOffsets.contains(d.reminderOffsetDays)) {
      throw const LedgerValidationException('Pengingat harus H, H-1, atau H-3.');
    }
    final t = d.reminderTime.split(':');
    if (t.length != 2 || formatTimeOfDay(parseTimeOfDay(d.reminderTime)) != d.reminderTime) {
      throw const LedgerValidationException('Jam pengingat tidak valid.');
    }

    final account = await (db.select(db.accounts)..where((a) => a.id.equals(d.accountId))).getSingleOrNull();
    if (account == null) throw const LedgerValidationException('Account tidak ditemukan.');
    if (!account.isActive) {
      final previous = ruleId == null
          ? null
          : await (db.select(db.recurringRules)..where((r) => r.id.equals(ruleId))).getSingleOrNull();
      if (previous?.accountId != d.accountId) {
        throw LedgerValidationException('Account ${account.name} sudah diarsipkan.');
      }
    }
    final cat = await (db.select(db.categories)..where((c) => c.id.equals(d.categoryId))).getSingleOrNull();
    if (cat == null) throw const LedgerValidationException('Kategori tidak ditemukan.');
    final expected = d.type == TransactionType.income ? CategoryType.income : CategoryType.expense;
    if (cat.type != expected) {
      throw const LedgerValidationException('Kategori tidak sesuai jenis transaksi.');
    }
  }
}
