import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../providers.dart';
import '../storage/attachment_storage.dart';
import '../utilities/app_logger.dart';
import '../utilities/ids.dart';

/// Input for creating/updating a ledger transaction (manual, OCR, recurring).
class TransactionDraft {
  const TransactionDraft({
    required this.type,
    required this.amount,
    required this.accountId,
    required this.transactionAt,
    this.categoryId,
    this.transferToAccountId,
    this.note,
    this.sourceType = SourceType.manual,
    this.recurringInstanceId,
    this.attachments = const [],
  });

  final TransactionType type;
  final int amount;
  final String accountId;
  final String? categoryId;
  final String? transferToAccountId;
  final DateTime transactionAt;
  final String? note;
  final SourceType sourceType;
  final String? recurringInstanceId;

  /// New attachments to link (files already copied to private storage).
  final List<AttachmentDraft> attachments;

  factory TransactionDraft.fromRow(LedgerTransaction t) => TransactionDraft(
    type: t.type,
    amount: t.amount,
    accountId: t.accountId,
    categoryId: t.categoryId,
    transferToAccountId: t.transferToAccountId,
    transactionAt: t.transactionAt,
    note: t.note,
    sourceType: t.sourceType,
    recurringInstanceId: t.recurringInstanceId,
  );
}

class AttachmentDraft {
  const AttachmentDraft({
    required this.localPath,
    required this.mimeType,
    required this.kind,
    this.imageHash,
    this.fileSha256,
  });

  final String localPath;
  final String mimeType;
  final AttachmentKind kind;
  final String? imageHash;

  /// SHA-256 of the file at [localPath] (see `AttachmentStorage.import`).
  final String? fileSha256;
}

class LedgerValidationException implements Exception {
  const LedgerValidationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What changed, delivered to listeners after the DB transaction commits.
/// `before` is null for creates, `after` is null for deletes.
class LedgerChange {
  const LedgerChange({this.before, this.after});
  final LedgerTransaction? before;
  final LedgerTransaction? after;

  Iterable<LedgerTransaction> get rows => [?before, ?after];
}

typedef LedgerListener = Future<void> Function(LedgerChange change);

/// Post-commit listeners (budget alerts, daily activity). Wired in
/// `lib/app/ledger_wiring.dart`.
final ledgerListenersProvider = Provider<List<LedgerListener>>((ref) => const []);

final ledgerServiceProvider = Provider<LedgerService>(
  (ref) => LedgerService(
    ref.watch(databaseProvider),
    listeners: () => ref.read(ledgerListenersProvider),
  ),
);

/// Single write path for balance-changing operations. Every mutation runs in
/// one SQLite transaction (05-architecture §7); balances are never stored,
/// they are replayed from confirmed rows (FinanceService).
class LedgerService {
  LedgerService(this.db, {List<LedgerListener> Function()? listeners})
    : _listeners = listeners ?? (() => const []);

  final AppDatabase db;
  final List<LedgerListener> Function() _listeners;

  /// [inTransaction] runs inside the same SQLite transaction after the
  /// insert (e.g. closing the recurring instance it confirms); throwing
  /// there rolls the whole posting back.
  Future<String> create(
    TransactionDraft d, {
    TransactionStatus status = TransactionStatus.confirmed,
    Future<void> Function(String id)? inTransaction,
  }) async {
    final id = newId();
    final row = await db.transaction(() async {
      await _validate(d);
      final now = DateTime.now();
      await db.into(db.transactions).insert(
        TransactionsCompanion.insert(
          id: id,
          type: d.type,
          amount: d.amount,
          accountId: d.accountId,
          categoryId: Value(d.categoryId),
          transferToAccountId: Value(
            d.type == TransactionType.transfer ? d.transferToAccountId : null,
          ),
          transactionAt: d.transactionAt,
          note: Value(_clean(d.note)),
          sourceType: Value(d.sourceType),
          recurringInstanceId: Value(d.recurringInstanceId),
          status: Value(status),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await _insertAttachments(id, d.attachments);
      await inTransaction?.call(id);
      return _get(id);
    });
    await _notify(LedgerChange(after: row));
    return id;
  }

  Future<void> update(String id, TransactionDraft d) async {
    late LedgerTransaction before;
    final after = await db.transaction(() async {
      before = await _get(id);
      await _validate(d, previous: before);
      await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
        TransactionsCompanion(
          type: Value(d.type),
          amount: Value(d.amount),
          accountId: Value(d.accountId),
          categoryId: Value(d.categoryId),
          transferToAccountId: Value(
            d.type == TransactionType.transfer ? d.transferToAccountId : null,
          ),
          transactionAt: Value(d.transactionAt),
          note: Value(_clean(d.note)),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _insertAttachments(id, d.attachments);
      return _get(id);
    });
    await _notify(LedgerChange(before: before, after: after));
  }

  /// Promotes a draft to confirmed (e.g. reviewed scan).
  Future<void> confirm(String id) async {
    late LedgerTransaction before;
    final after = await db.transaction(() async {
      before = await _get(id);
      await _validate(TransactionDraft.fromRow(before), previous: before);
      await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
        TransactionsCompanion(
          status: const Value(TransactionStatus.confirmed),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return _get(id);
    });
    await _notify(LedgerChange(before: before, after: after));
  }

  /// FR-TRX-005. Removes linked goal movements (and rebuilds goal caches),
  /// reopens a linked recurring instance (or closes it as skipped when its
  /// rule auto-confirms, so the next sync does not post it again), then
  /// deletes attachment files.
  Future<void> delete(String id) async {
    late LedgerTransaction before;
    final files = await db.transaction(() async {
      before = await _get(id);
      final atts = await (db.select(db.attachments)
            ..where((a) => a.transactionId.equals(id)))
          .get();
      final goalIds = await (db.selectOnly(db.goalMovements, distinct: true)
            ..addColumns([db.goalMovements.goalId])
            ..where(db.goalMovements.transactionId.equals(id)))
          .map((r) => r.read(db.goalMovements.goalId)!)
          .get();
      await (db.delete(db.goalMovements)
            ..where((m) => m.transactionId.equals(id)))
          .go();
      for (final g in goalIds) {
        await recomputeGoalAmount(db, g);
      }
      final linked = await (db.select(db.recurringInstances).join([
        innerJoin(db.recurringRules, db.recurringRules.id.equalsExp(db.recurringInstances.recurringRuleId)),
      ])..where(db.recurringInstances.transactionId.equals(id)))
          .get();
      for (final row in linked) {
        final inst = row.readTable(db.recurringInstances);
        final autoConfirm = row.readTable(db.recurringRules).autoConfirm;
        await (db.update(db.recurringInstances)..where((i) => i.id.equals(inst.id))).write(
          RecurringInstancesCompanion(
            status: Value(autoConfirm ? RecurringStatus.skipped : RecurringStatus.pending),
            transactionId: const Value(null),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
      await (db.delete(db.transactions)..where((t) => t.id.equals(id))).go();
      return atts.map((a) => a.localPath).toList();
    });
    for (final path in files) {
      try {
        // local_path may come from a restored backup: never delete outside
        // the attachments directory.
        if (!await AttachmentStorage.isManaged(path)) {
          AppLogger.info('Attachment di luar penyimpanan aplikasi tidak dihapus: $path');
          continue;
        }
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e, s) {
        AppLogger.error('Gagal menghapus attachment $path', e, s);
      }
    }
    await _notify(LedgerChange(before: before));
  }

  /// FR-TRX-006: copy with current timestamp, no attachments. A draft stays
  /// a draft (never becomes a balance-changing row by duplication).
  Future<String> duplicate(String id, {DateTime? at}) async {
    final src = await _get(id);
    final d = TransactionDraft.fromRow(src);
    return create(
      TransactionDraft(
        type: d.type,
        amount: d.amount,
        accountId: d.accountId,
        categoryId: d.categoryId,
        transferToAccountId: d.transferToAccountId,
        transactionAt: at ?? DateTime.now(),
        note: d.note,
      ),
      status: src.status == TransactionStatus.draft ? TransactionStatus.draft : TransactionStatus.confirmed,
    );
  }

  Future<LedgerTransaction> _get(String id) =>
      (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();

  Future<void> _insertAttachments(String txId, List<AttachmentDraft> list) async {
    final now = DateTime.now();
    for (final a in list) {
      await db.into(db.attachments).insert(
        AttachmentsCompanion.insert(
          id: newId(),
          transactionId: txId,
          localPath: a.localPath,
          mimeType: a.mimeType,
          sourceKind: a.kind,
          imageHash: Value(a.imageHash),
          fileSha256: Value(a.fileSha256),
          createdAt: now,
        ),
      );
    }
  }

  Future<void> _validate(TransactionDraft d, {LedgerTransaction? previous}) async {
    if (d.amount <= 0) {
      throw const LedgerValidationException('Nominal harus lebih dari 0.');
    }
    final account = await (db.select(db.accounts)
          ..where((a) => a.id.equals(d.accountId)))
        .getSingleOrNull();
    if (account == null) {
      throw const LedgerValidationException('Account tidak ditemukan.');
    }
    // Archived accounts keep history but accept no new postings.
    final accountUnchanged = previous != null && previous.accountId == d.accountId;
    if (!account.isActive && !accountUnchanged) {
      throw LedgerValidationException('Account ${account.name} sudah diarsipkan.');
    }

    if (d.type == TransactionType.transfer) {
      final to = d.transferToAccountId;
      if (to == null) {
        throw const LedgerValidationException('Pilih account tujuan transfer.');
      }
      if (to == d.accountId) {
        throw const LedgerValidationException(
          'Account asal dan tujuan harus berbeda.',
        );
      }
      final dest = await (db.select(db.accounts)..where((a) => a.id.equals(to)))
          .getSingleOrNull();
      if (dest == null) {
        throw const LedgerValidationException('Account tujuan tidak ditemukan.');
      }
      final destUnchanged = previous != null && previous.transferToAccountId == to;
      if (!dest.isActive && !destUnchanged) {
        throw LedgerValidationException('Account ${dest.name} sudah diarsipkan.');
      }
      // Kurs bersifat manual dan tidak ada konversi otomatis antar sisi
      // transfer: sisi penerima mencatat transfer masuknya sendiri.
      if (account.currency != dest.currency) {
        throw const LedgerValidationException(
          'Transfer antar mata uang berbeda belum didukung. '
          'Pindahkan via dua transaksi atau samakan mata uang akun.',
        );
      }
      return;
    }

    final catId = d.categoryId;
    if (catId == null) {
      throw const LedgerValidationException('Pilih kategori.');
    }
    final cat = await (db.select(db.categories)..where((c) => c.id.equals(catId)))
        .getSingleOrNull();
    if (cat == null) {
      throw const LedgerValidationException('Kategori tidak ditemukan.');
    }
    // Archived categories keep history but accept no new postings.
    final categoryUnchanged = previous != null && previous.categoryId == catId;
    if (!cat.isActive && !categoryUnchanged) {
      throw LedgerValidationException('Kategori ${cat.name} sudah diarsipkan.');
    }
    final expected = d.type == TransactionType.income
        ? CategoryType.income
        : CategoryType.expense;
    if (cat.type != expected) {
      throw const LedgerValidationException('Kategori tidak sesuai jenis transaksi.');
    }
  }

  Future<void> _notify(LedgerChange change) async {
    for (final l in _listeners()) {
      try {
        await l(change);
      } catch (e, s) {
        // Listeners are side effects (notifications, activity markers);
        // they must never roll back or block a committed transaction.
        AppLogger.error('Ledger listener gagal', e, s);
      }
    }
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}

/// Rebuilds goals.current_amount from goal_movements (cache must stay derivable).
Future<void> recomputeGoalAmount(AppDatabase db, String goalId) async {
  final sum = db.goalMovements.amount.sum();
  final total = await (db.selectOnly(db.goalMovements)
        ..addColumns([sum])
        ..where(db.goalMovements.goalId.equals(goalId)))
      .map((r) => r.read(sum) ?? 0)
      .getSingle();
  await (db.update(db.goals)..where((g) => g.id.equals(goalId))).write(
    GoalsCompanion(currentAmount: Value(total), updatedAt: Value(DateTime.now())),
  );
}
