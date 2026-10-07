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
  recurring('recurring'),
  statementImport('statement_import');

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

/// Supported currencies. `db` is the lowercase ISO code, matching the plain
/// TEXT `accounts.currency` column (default 'IDR') — no converter needed.
enum Currency implements DbEnum {
  idr('IDR', 'Rp', 'Rupiah', 0),
  usd('USD', '\$', 'US Dollar', 2),
  sgd('SGD', 'S\$', 'Singapore Dollar', 2),
  myr('MYR', 'RM', 'Malaysian Ringgit', 2),
  eur('EUR', '€', 'Euro', 2),
  gbp('GBP', '£', 'British Pound', 2),
  jpy('JPY', '¥', 'Japanese Yen', 0),
  aud('AUD', 'A\$', 'Australian Dollar', 2),
  chf('CHF', 'Fr', 'Swiss Franc', 2),
  cny('CNY', '¥', 'Chinese Yuan', 2),
  hkd('HKD', 'HK\$', 'Hong Kong Dollar', 2);

  const Currency(this.code, this.symbol, this.displayName, this.decimals);
  @override
  String get db => code.toLowerCase();
  final String code;
  final String symbol;
  final String displayName;
  final int decimals;

  /// Parses a stored/canonical code ('usd', 'USD'); unknown → IDR.
  static Currency fromCode(String code) => Currency.values.firstWhere(
    (c) => c.code == code.toUpperCase(),
    orElse: () => Currency.idr,
  );
}
