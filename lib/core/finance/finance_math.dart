// Pure formulas from 03-financial-rules-and-formulas.md. No I/O.

import '../database/enums.dart';

/// [minor] units of [c] → whole rupiah at [rateToIdr] (rupiah per 1 unit),
/// rounded like FinanceService's SQL conversion. A missing rate falls back
/// to 1.0, also matching the SQL; IDR is returned unchanged.
int toIdr(int minor, Currency c, double? rateToIdr) {
  if (c == Currency.idr) return minor;
  var divisor = 1;
  for (var i = 0; i < c.decimals; i++) {
    divisor *= 10;
  }
  return (minor * (rateToIdr ?? 1.0) / divisor).round();
}

/// `part / whole × 100`; null when [whole] is 0 (never show a fake %).
double? ratioPercent(num part, num whole) => whole == 0 ? null : part / whole * 100;

/// §17 Monthly change. Null when previous is 0 → UI shows N/A.
double? percentChange(num current, num previous) =>
    previous == 0 ? null : (current - previous) / previous * 100;

/// §12 Budget Usage.
double budgetUsage(int actual, int budget) => budget <= 0 ? 0 : actual / budget * 100;

/// §13 Budget Variance. Positive = remaining, negative = over.
int budgetVariance(int budget, int actual) => budget - actual;

enum BudgetStatus {
  normal('Normal'),
  attention('Attention'),
  warning('Warning'),
  reached('Limit reached'),
  over('Over budget');

  const BudgetStatus(this.label);
  final String label;
}

/// Thresholds in percentage points: default 70 / 85 / 100. Compared in
/// integers (`actual × 100` vs `threshold × budget`) so an exact hit such as
/// 57.000 of 100.000 at 57% is never lost to floating-point rounding.
BudgetStatus budgetStatus(
  int actual,
  int budget, {
  int attention = 70,
  int warning = 85,
  int over = 100,
}) {
  if (budget <= 0) return BudgetStatus.normal;
  final used = actual * 100;
  if (used > over * budget) return BudgetStatus.over;
  if (used >= over * budget) return BudgetStatus.reached;
  if (used >= warning * budget) return BudgetStatus.warning;
  if (used >= attention * budget) return BudgetStatus.attention;
  return BudgetStatus.normal;
}

/// Highest threshold reached by [actual] of [budget], or null if below all
/// of them (integer comparison, see [budgetStatus]).
int? crossedThreshold(int actual, int budget, List<int> thresholds) {
  if (budget <= 0) return null;
  int? hit;
  for (final t in [...thresholds]..sort()) {
    if (actual * 100 >= t * budget) hit = t;
  }
  return hit;
}

/// §14 Emergency Fund Coverage in months; null if no essential history.
double? emergencyCoverage(int emergencyBalance, double avgEssentialMonthly) =>
    avgEssentialMonthly <= 0 ? null : emergencyBalance / avgEssentialMonthly;

/// §2 Calculated Balance.
int calculatedBalance({
  required int opening,
  required int incomeIn,
  required int expenseOut,
  required int transferIn,
  required int transferOut,
}) => opening + incomeIn - expenseOut + transferIn - transferOut;

/// §4 Available to Spend.
int availableToSpend({
  required int totalBalance,
  required int reserved,
  required int upcomingObligations,
  required int minimumCashBuffer,
}) => totalBalance - reserved - upcomingObligations - minimumCashBuffer;

/// Goal progress 0..100+ (FR-GOA-002).
double goalProgress(int current, int target) => target <= 0 ? 0 : current / target * 100;

/// Planning bucket percentages (planning_settings).
class AllocationPlan {
  const AllocationPlan({
    required this.essential,
    required this.family,
    required this.emergency,
    required this.savings,
    required this.development,
    required this.personal,
    this.flexibleResidual = false,
  });

  final int essential;
  final int family;
  final int emergency;
  final int savings;
  final int development;
  final int personal;
  final bool flexibleResidual;

  int get total => essential + family + emergency + savings + development + personal;

  /// §18: total must be 100 unless Flexible Residual mode is on (then ≤ 100).
  String? validate() {
    for (final v in [essential, family, emergency, savings, development, personal]) {
      if (v < 0 || v > 100) return 'Persentase harus 0–100.';
    }
    if (flexibleResidual) {
      return total > 100 ? 'Total alokasi melebihi 100%.' : null;
    }
    return total == 100 ? null : 'Total alokasi harus 100% (saat ini $total%).';
  }

  Map<PlanningBucket, int> get percents => {
    PlanningBucket.essential: essential,
    PlanningBucket.family: family,
    PlanningBucket.emergency: emergency,
    PlanningBucket.savings: savings,
    PlanningBucket.development: development,
    PlanningBucket.personal: personal,
  };
}

/// §18–§19, §21: split [income] by plan. Each bucket is floored to whole
/// rupiah; residual (rounding + unallocated %) goes to Flexible/Unallocated,
/// so the result always sums to [income].
Map<PlanningBucket, int> allocateIncome(int income, AllocationPlan plan) {
  final out = <PlanningBucket, int>{};
  var used = 0;
  plan.percents.forEach((bucket, pct) {
    final v = income * pct ~/ 100;
    out[bucket] = v;
    used += v;
  });
  out[PlanningBucket.flexible] = income - used;
  return out;
}
