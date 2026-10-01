import '../../../core/database/app_database.dart';
import '../../../core/database/seed.dart';
import '../../../core/ledger/ledger_service.dart';

/// Note put on adjustment postings created from reconciliation.
const reconciliationNote = 'Penyesuaian saldo';

/// FR-ACC-002: compares the user's actual balance with the calculated one.
class Reconciliation {
  const Reconciliation({required this.calculated, required this.actual});

  final int calculated;
  final int actual;

  /// Positive: the real balance is higher than recorded (missing income);
  /// negative: lower than recorded (missing expense).
  int get variance => actual - calculated;

  bool get matches => variance == 0;

  /// Posting that makes the calculated balance equal [actual]: an income
  /// (Other Income) or expense (Other) for the variance. Null when matching.
  TransactionDraft? adjustment(String accountId, DateTime at) {
    final v = variance;
    if (v == 0) return null;
    final income = v > 0;
    return TransactionDraft(
      type: income ? TransactionType.income : TransactionType.expense,
      amount: v.abs(),
      accountId: accountId,
      categoryId: income ? SystemCategories.otherIncome : SystemCategories.otherExpense,
      transactionAt: at,
      note: reconciliationNote,
    );
  }
}
