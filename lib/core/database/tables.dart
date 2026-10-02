import 'package:drift/drift.dart';

import 'converters.dart';
import 'enums.dart';

// Schema follows 04-database-schema.md plus the approved additions:
// accounts.icon, budgets.attention_threshold/last_notified_threshold,
// recurring_rules.interval_days/month_of_year/reminder_offset_days/reminder_time,
// attachments.image_hash, planning_settings.flexible_residual_mode/user_reserve,
// and the merchant_mappings table.

mixin _Timestamps on Table {
  TextColumn get createdAt => text().map(const LocalDateTimeConverter())();
  TextColumn get updatedAt => text().map(const LocalDateTimeConverter())();
}

@DataClassName('Account')
class Accounts extends Table with _Timestamps {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 60)();
  TextColumn get type => text().map(const DbEnumConverter(AccountType.values))();
  TextColumn get icon => text().nullable()();
  IntColumn get openingBalance => integer().withDefault(const Constant(0))();
  TextColumn get currency => text().withDefault(const Constant('IDR'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Category')
class Categories extends Table with _Timestamps {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 40)();
  TextColumn get type =>
      text().map(const DbEnumConverter(CategoryType.values))();
  TextColumn get planningBucket =>
      text().map(const DbEnumConverter(PlanningBucket.values)).nullable()();
  TextColumn get expenseNature =>
      text().map(const DbEnumConverter(ExpenseNature.values)).nullable()();
  TextColumn get icon => text().nullable()();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

// Indexes (schema v2) back the hot paths: period ranges and list ordering on
// transaction_at, per-account balances, budget actuals per category and
// period, and the FK lookups done on transaction/goal deletes.
@TableIndex(name: 'transactions_transaction_at', columns: {#transactionAt})
@TableIndex(name: 'transactions_account_id', columns: {#accountId})
@TableIndex(
  name: 'transactions_transfer_to_account_id',
  columns: {#transferToAccountId},
)
@TableIndex(
  name: 'transactions_category_id_transaction_at',
  columns: {#categoryId, #transactionAt},
)
@TableIndex(
  name: 'transactions_recurring_instance_id',
  columns: {#recurringInstanceId},
)
@DataClassName('LedgerTransaction')
class Transactions extends Table with _Timestamps {
  TextColumn get id => text()();
  TextColumn get type =>
      text().map(const DbEnumConverter(TransactionType.values))();
  IntColumn get amount => integer()();
  @ReferenceName('ledgerTransactions')
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get categoryId =>
      text().nullable().references(Categories, #id)();
  @ReferenceName('incomingTransfers')
  TextColumn get transferToAccountId =>
      text().nullable().references(Accounts, #id)();
  TextColumn get transactionAt =>
      text().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();
  TextColumn get sourceType => text()
      .map(const DbEnumConverter(SourceType.values))
      .withDefault(const Constant('manual'))();
  TextColumn get recurringInstanceId => text().nullable()();
  TextColumn get status => text()
      .map(const DbEnumConverter(TransactionStatus.values))
      .withDefault(const Constant('confirmed'))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (amount > 0)',
    "CHECK ((type = 'transfer' AND transfer_to_account_id IS NOT NULL "
        'AND transfer_to_account_id <> account_id) '
        "OR (type <> 'transfer' AND transfer_to_account_id IS NULL "
        'AND category_id IS NOT NULL))',
  ];
}

@TableIndex(name: 'attachments_transaction_id', columns: {#transactionId})
@TableIndex(name: 'attachments_image_hash', columns: {#imageHash})
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get transactionId =>
      text().references(Transactions, #id, onDelete: KeyAction.cascade)();
  TextColumn get localPath => text()();
  TextColumn get mimeType => text()();
  TextColumn get sourceKind =>
      text().map(const DbEnumConverter(AttachmentKind.values))();
  TextColumn get imageHash => text().nullable()();

  /// SHA-256 (hex) of the stored file; null for rows created before schema 4
  /// or files written without hashing. Verified by integrity check and used
  /// to verify unpacked backup entries at restore.
  TextColumn get fileSha256 => text().nullable()();
  TextColumn get createdAt => text().map(const LocalDateTimeConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

class Budgets extends Table with _Timestamps {
  TextColumn get id => text()();
  TextColumn get categoryId => text().references(Categories, #id)();
  TextColumn get periodStart => text().map(const DateOnlyConverter())();
  TextColumn get periodEnd => text().map(const DateOnlyConverter())();
  IntColumn get amount => integer()();
  IntColumn get attentionThreshold =>
      integer().withDefault(const Constant(70))();
  IntColumn get warningThreshold => integer().withDefault(const Constant(85))();
  IntColumn get overThreshold => integer().withDefault(const Constant(100))();

  /// Highest threshold (percentage points) already notified this period.
  IntColumn get lastNotifiedThreshold => integer().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {categoryId, periodStart},
  ];

  @override
  List<String> get customConstraints => ['CHECK (amount > 0)'];
}

// Schema v3: a goal may follow one Savings account's calculated balance
// instead of its movements; one account backs at most one goal.
@TableIndex.sql(
  'CREATE UNIQUE INDEX goals_linked_account_id ON goals (linked_account_id) '
  'WHERE linked_account_id IS NOT NULL',
)
class Goals extends Table with _Timestamps {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 60)();
  TextColumn get type => text().map(const DbEnumConverter(GoalType.values))();
  IntColumn get targetAmount => integer()();

  /// Cache of SUM(goal_movements.amount); rebuilt by GoalRepository. Progress
  /// of an unlinked goal only (see FinanceService.goalProgresses).
  IntColumn get currentAmount => integer().withDefault(const Constant(0))();
  TextColumn get targetDate =>
      text().map(const DateOnlyConverter()).nullable()();
  IntColumn get monthlyTarget => integer().nullable()();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Savings account whose calculated balance is this goal's progress (v3).
  TextColumn get linkedAccountId => text().nullable().references(
    Accounts,
    #id,
    onDelete: KeyAction.setNull,
  )();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (target_amount > 0)'];
}

@TableIndex(name: 'goal_movements_goal_id', columns: {#goalId})
@TableIndex(name: 'goal_movements_transaction_id', columns: {#transactionId})
class GoalMovements extends Table {
  TextColumn get id => text()();
  TextColumn get goalId =>
      text().references(Goals, #id, onDelete: KeyAction.cascade)();
  TextColumn get transactionId => text().nullable().references(
    Transactions,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// Positive contribution, negative withdrawal.
  IntColumn get amount => integer()();
  TextColumn get movementType =>
      text().map(const DbEnumConverter(MovementType.values))();
  TextColumn get movementAt => text().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (amount <> 0)'];
}

class RecurringRules extends Table with _Timestamps {
  TextColumn get id => text()();

  /// income or expense only.
  TextColumn get type =>
      text().map(const DbEnumConverter(TransactionType.values))();
  TextColumn get name => text().withLength(min: 1, max: 60)();
  IntColumn get amount => integer()();
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get categoryId => text().references(Categories, #id)();
  TextColumn get frequency =>
      text().map(const DbEnumConverter(RecurringFrequency.values))();

  /// Only for `custom` frequency.
  IntColumn get intervalDays => integer().nullable()();
  IntColumn get dayOfMonth => integer().nullable()();

  /// 1 = Monday … 7 = Sunday (DateTime.weekday).
  IntColumn get dayOfWeek => integer().nullable()();
  IntColumn get monthOfYear => integer().nullable()();
  TextColumn get startDate => text().map(const DateOnlyConverter())();
  TextColumn get endDate => text().map(const DateOnlyConverter()).nullable()();
  BoolColumn get reminderEnabled =>
      boolean().withDefault(const Constant(true))();

  /// 0 = H, 1 = H-1, 3 = H-3.
  IntColumn get reminderOffsetDays => integer().withDefault(const Constant(0))();

  /// `HH:mm` local time.
  TextColumn get reminderTime =>
      text().withDefault(const Constant('09:00'))();
  BoolColumn get autoConfirm => boolean().withDefault(const Constant(false))();
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (amount > 0)',
    "CHECK (type IN ('income', 'expense'))",
  ];
}

@TableIndex(
  name: 'recurring_instances_due_date_status',
  columns: {#dueDate, #status},
)
@TableIndex(
  name: 'recurring_instances_transaction_id',
  columns: {#transactionId},
)
class RecurringInstances extends Table with _Timestamps {
  TextColumn get id => text()();
  TextColumn get recurringRuleId =>
      text().references(RecurringRules, #id, onDelete: KeyAction.cascade)();
  TextColumn get dueDate => text().map(const DateOnlyConverter())();
  IntColumn get amount => integer()();
  TextColumn get status =>
      text().map(const DbEnumConverter(RecurringStatus.values))();
  TextColumn get transactionId => text().nullable().references(
    Transactions,
    #id,
    onDelete: KeyAction.setNull,
  )();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {recurringRuleId, dueDate},
  ];
}

@DataClassName('DailyActivityRow')
class DailyActivity extends Table {
  TextColumn get date => text().map(const DateOnlyConverter())();
  TextColumn get status =>
      text().map(const DbEnumConverter(ActivityStatus.values))();
  TextColumn get checkedAt =>
      text().map(const LocalDateTimeConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {date};
}

@DataClassName('PlanningSetting')
class PlanningSettings extends Table with _Timestamps {
  TextColumn get id => text()();
  IntColumn get essentialPercent => integer()();
  IntColumn get familyPercent => integer()();
  IntColumn get emergencyPercent => integer()();
  IntColumn get savingsPercent => integer()();
  IntColumn get developmentPercent => integer()();
  IntColumn get personalPercent => integer()();
  BoolColumn get flexibleResidualMode =>
      boolean().withDefault(const Constant(false))();
  IntColumn get targetEmergencyMonths =>
      integer().withDefault(const Constant(3))();
  IntColumn get emergencyLookbackMonths =>
      integer().withDefault(const Constant(3))();
  IntColumn get minimumCashBuffer => integer().withDefault(const Constant(0))();

  /// Manual user-defined reserve included in Reserved Money.
  IntColumn get userReserve => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class MerchantMappings extends Table with _Timestamps {
  TextColumn get id => text()();

  /// Lower-cased, whitespace-collapsed raw OCR merchant text.
  TextColumn get rawMerchant => text().unique()();
  TextColumn get normalizedMerchant => text()();
  TextColumn get categoryId => text().nullable().references(
    Categories,
    #id,
    onDelete: KeyAction.setNull,
  )();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AppSetting')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  TextColumn get updatedAt => text().map(const LocalDateTimeConverter())();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('BackupRecord')
class Backups extends Table {
  TextColumn get id => text()();
  TextColumn get fileName => text()();
  TextColumn get schemaVersion => text()();
  TextColumn get createdAt => text().map(const LocalDateTimeConverter())();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
