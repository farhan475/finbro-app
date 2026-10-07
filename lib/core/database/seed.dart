import 'package:drift/drift.dart';

import 'app_database.dart';

/// Stable id of the single planning_settings row.
const planningSettingsId = 'default';

class _SeedCategory {
  const _SeedCategory(this.id, this.name, this.icon, [this.bucket, this.nature]);
  final String id;
  final String name;
  final String icon;
  final PlanningBucket? bucket;
  final ExpenseNature? nature;
}

const _income = [
  _SeedCategory('sys-income-salary', 'Salary', 'salary'),
  _SeedCategory('sys-income-freelance', 'Freelance', 'freelance'),
  _SeedCategory('sys-income-allowance', 'Allowance', 'allowance'),
  _SeedCategory('sys-income-gift', 'Gift', 'gift'),
  _SeedCategory('sys-income-interest', 'Interest', 'interest'),
  _SeedCategory('sys-income-other', 'Other Income', 'other'),
];

const _e = ExpenseNature.essential;
const _d = ExpenseNature.discretionary;

const _expense = [
  _SeedCategory('sys-expense-food', 'Food', 'food', PlanningBucket.essential, _e),
  _SeedCategory('sys-expense-transport', 'Transport', 'transport', PlanningBucket.essential, _e),
  _SeedCategory('sys-expense-bills', 'Bills', 'bills', PlanningBucket.essential, _e),
  _SeedCategory('sys-expense-shopping', 'Shopping', 'shopping', PlanningBucket.personal, _d),
  _SeedCategory('sys-expense-entertainment', 'Entertainment', 'entertainment', PlanningBucket.personal, _d),
  _SeedCategory('sys-expense-health', 'Health', 'health', PlanningBucket.essential, _e),
  _SeedCategory('sys-expense-education', 'Education', 'education', PlanningBucket.essential, _e),
  _SeedCategory('sys-expense-development', 'Development', 'development', PlanningBucket.development, _d),
  _SeedCategory('sys-expense-family', 'Family', 'family', PlanningBucket.family, _d),
  _SeedCategory('sys-expense-personal-care', 'Personal Care', 'personal_care', PlanningBucket.personal, _d),
  _SeedCategory('sys-expense-subscription', 'Subscription', 'subscription', PlanningBucket.personal, _d),
  _SeedCategory('sys-expense-other', 'Other', 'other', PlanningBucket.flexible, _d),
];

/// Well-known category ids referenced by features (e.g. salary recurring,
/// reconciliation adjustments).
abstract final class SystemCategories {
  static const salary = 'sys-income-salary';
  static const otherIncome = 'sys-income-other';
  static const otherExpense = 'sys-expense-other';
  static const food = 'sys-expense-food';
  static const family = 'sys-expense-family';
}

/// Default manual rates: rupiah per 1 unit of the currency code.
const _defaultRates = <String, double>{
  'USD': 16250.0,
  'SGD': 12250.0,
  'MYR': 3750.0,
  'EUR': 17250.0,
  'GBP': 20200.0,
  'JPY': 105.0,
  'AUD': 10400.0,
  'CHF': 17900.0,
  'CNY': 2200.0,
  'HKD': 2030.0,
};

/// Inserts the default exchange rates (schema v5). Used both by
/// [seedDefaults] on fresh installs and by the v5 migration step; rows that
/// already exist are left untouched so user-edited rates survive.
Future<void> seedExchangeRates(AppDatabase db) async {
  final now = DateTime.now();
  await db.batch((b) {
    _defaultRates.forEach((code, rate) {
      b.insert(
        db.exchangeRates,
        ExchangeRatesCompanion.insert(code: code, rateToIdr: rate, updatedAt: Value(now)),
        mode: InsertMode.insertOrIgnore,
      );
    });
  });
}

Future<void> seedDefaults(AppDatabase db) async {
  final now = DateTime.now();
  await db.batch((b) {
    for (final c in _income) {
      b.insert(
        db.categories,
        CategoriesCompanion.insert(
          id: c.id,
          name: c.name,
          type: CategoryType.income,
          icon: Value(c.icon),
          isSystem: const Value(true),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    for (final c in _expense) {
      b.insert(
        db.categories,
        CategoriesCompanion.insert(
          id: c.id,
          name: c.name,
          type: CategoryType.expense,
          planningBucket: Value(c.bucket),
          expenseNature: Value(c.nature),
          icon: Value(c.icon),
          isSystem: const Value(true),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    b.insert(
      db.planningSettings,
      PlanningSettingsCompanion.insert(
        id: planningSettingsId,
        essentialPercent: 45,
        familyPercent: 10,
        emergencyPercent: 10,
        savingsPercent: 15,
        developmentPercent: 10,
        personalPercent: 10,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });
  await seedExchangeRates(db);
}
