/// Domain enums persisted as TEXT. `db` values follow 04-database-schema.md.
library;

abstract interface class DbEnum {
  String get db;
}

T enumFromDb<T extends DbEnum>(List<T> values, String raw) {
  for (final v in values) {
    if (v.db == raw) return v;
  }
  throw ArgumentError('Unknown value "$raw" for $T');
}

enum AccountType implements DbEnum {
  cash('cash', 'Cash'),
  bank('bank', 'Bank'),
  ewallet('ewallet', 'E-Wallet'),
  savings('savings', 'Savings'),
  other('other', 'Lainnya');

  const AccountType(this.db, this.label);
  @override
  final String db;
  final String label;
}

enum CategoryType implements DbEnum {
  income('income'),
  expense('expense');

  const CategoryType(this.db);
  @override
  final String db;
}

enum PlanningBucket implements DbEnum {
  essential('essential', 'Essential Spending'),
  family('family', 'Family Support'),
  emergency('emergency', 'Emergency Fund'),
  savings('savings', 'Savings'),
  development('development', 'Development Fund'),
  personal('personal', 'Personal Spending'),
  flexible('flexible', 'Flexible/Unallocated');

  const PlanningBucket(this.db, this.label);
  @override
  final String db;
  final String label;
}

enum ExpenseNature implements DbEnum {
  essential('essential'),
  discretionary('discretionary');

  const ExpenseNature(this.db);
  @override
  final String db;
}

enum TransactionType implements DbEnum {
  income('income', 'Income'),
  expense('expense', 'Expense'),
  transfer('transfer', 'Transfer');

  const TransactionType(this.db, this.label);
  @override
  final String db;
  final String label;
}

enum SourceType implements DbEnum {
  manual('manual'),
  receiptOcr('receipt_ocr'),
  screenshot('screenshot'),
  recurring('recurring');

  const SourceType(this.db);
  @override
  final String db;
}

enum TransactionStatus implements DbEnum {
  draft('draft'),
  confirmed('confirmed'),
  voided('void');

  const TransactionStatus(this.db);
  @override
  final String db;
}

enum AttachmentKind implements DbEnum {
  receipt('receipt'),
  screenshot('screenshot'),
  document('document');

  const AttachmentKind(this.db);
  @override
  final String db;
}

enum GoalType implements DbEnum {
  emergency('emergency', 'Emergency Fund'),
  savings('savings', 'Savings'),
  development('development', 'Development Fund'),
  custom('custom', 'Custom');

  const GoalType(this.db, this.label);
  @override
  final String db;
  final String label;
}

enum MovementType implements DbEnum {
  contribution('contribution'),
  withdrawal('withdrawal'),
  adjustment('adjustment');

  const MovementType(this.db);
  @override
  final String db;
}

enum RecurringFrequency implements DbEnum {
  weekly('weekly', 'Mingguan'),
  monthly('monthly', 'Bulanan'),
  yearly('yearly', 'Tahunan'),
  custom('custom', 'Interval kustom');

  const RecurringFrequency(this.db, this.label);
  @override
  final String db;
  final String label;
}

enum RecurringStatus implements DbEnum {
  scheduled('scheduled'),
  pending('pending'),
  confirmed('confirmed'),
  skipped('skipped'),
  cancelled('cancelled');

  const RecurringStatus(this.db);
  @override
  final String db;

  bool get isOpen => this == scheduled || this == pending;
}

enum ActivityStatus implements DbEnum {
  unknown('unknown'),
  active('active'),
  noActivity('no_activity');

  const ActivityStatus(this.db);
  @override
  final String db;
}
