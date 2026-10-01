import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import 'merchant_text.dart';

/// Why an existing transaction looks like the scanned one.
enum DuplicateReason {
  sameImage('Gambar yang sama sudah pernah disimpan'),
  sameMerchant('Nominal & merchant sama, tanggal berdekatan'),
  sameCategory('Nominal & kategori sama, tanggal berdekatan');

  const DuplicateReason(this.label);
  final String label;
}

class DuplicateCandidate {
  const DuplicateCandidate(this.transaction, this.reasons);
  final LedgerTransaction transaction;
  final Set<DuplicateReason> reasons;
}

/// Heuristic duplicate check before a scanned transaction is saved
/// (07-ocr-screenshot §6). A candidate is either
/// - same amount AND date within ±[windowDays] calendar days AND (merchant
///   similar to the note OR same category), or
/// - an attachment with the same image SHA-256.
/// Voided rows are ignored. The user may still save.
class DuplicateDetector {
  const DuplicateDetector(this.db);

  static const windowDays = 2;

  final AppDatabase db;

  Future<List<DuplicateCandidate>> find({
    required int amount,
    required DateTime transactionAt,
    String? merchant,
    String? categoryId,
    String? imageHash,
  }) async {
    final found = <String, DuplicateCandidate>{};
    void add(LedgerTransaction t, DuplicateReason r) {
      final existing = found[t.id];
      if (existing == null) {
        found[t.id] = DuplicateCandidate(t, {r});
      } else {
        existing.reasons.add(r);
      }
    }

    if (imageHash != null && imageHash.isNotEmpty) {
      final q = db.select(db.transactions).join([
        innerJoin(db.attachments, db.attachments.transactionId.equalsExp(db.transactions.id)),
      ])..where(db.attachments.imageHash.equals(imageHash) & _notVoid());
      for (final row in await q.get()) {
        add(row.readTable(db.transactions), DuplicateReason.sameImage);
      }
    }

    final day = DateTime(transactionAt.year, transactionAt.month, transactionAt.day);
    final from = DateTime(day.year, day.month, day.day - windowDays);
    final to = DateTime(day.year, day.month, day.day + windowDays + 1);
    final near = await (db.select(db.transactions)
          ..where(
            (t) =>
                t.amount.equals(amount) &
                _notVoid() &
                t.transactionAt.isBiggerOrEqualValue(sqlDateTime(from)) &
                t.transactionAt.isSmallerThanValue(sqlDateTime(to)),
          ))
        .get();
    for (final t in near) {
      if (merchantsSimilar(merchant, t.note)) add(t, DuplicateReason.sameMerchant);
      if (categoryId != null && t.categoryId == categoryId) add(t, DuplicateReason.sameCategory);
    }

    final out = found.values.toList()
      ..sort((a, b) => b.transaction.transactionAt.compareTo(a.transaction.transactionAt));
    return out;
  }

  Expression<bool> _notVoid() => db.transactions.status.equalsValue(TransactionStatus.voided).not();
}

final duplicateDetectorProvider = Provider<DuplicateDetector>(
  (ref) => DuplicateDetector(ref.watch(databaseProvider)),
);
