// Financial Health metric panel (03 §20): each metric shows its value, the
// benchmark/target used and the data source. No single score.

import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/money.dart';
import 'report_shaping.dart';

enum HealthMetricKind {
  netCashFlow('Net Cash Flow'),
  savingsRate('Savings Rate'),
  essentialRatio('Essential Expense Ratio'),
  familyRatio('Family Support Ratio'),
  developmentRatio('Development Allocation Ratio'),
  budgetUsage('Budget Usage'),
  emergencyCoverage('Emergency Fund Coverage'),
  recurringRatio('Recurring Expense Ratio'),
  availableToSpend('Available to Spend');

  const HealthMetricKind(this.title);
  final String title;
}

class HealthMetric {
  const HealthMetric({
    required this.kind,
    required this.value,
    required this.benchmark,
    required this.source,
    this.comparison,
    this.detail,
  });

  final HealthMetricKind kind;

  String get title => kind.title;

  /// Display value (`N/A` when the denominator is zero).
  final String value;

  /// Benchmark or target the value is read against.
  final String benchmark;

  /// Formula and data origin, so the number is auditable.
  final String source;

  /// Factual position against the benchmark (`Di bawah rencana 45%`), or null
  /// when it cannot be determined.
  final String? comparison;

  /// Underlying amounts (e.g. `Rp 1.200.000 dari Rp 5.000.000`).
  final String? detail;
}

/// Factual position of [value] against a planning percentage.
String? comparePlan(double? value, int planPercent) {
  if (value == null) return null;
  final diff = value - planPercent;
  if (diff.abs() < 0.5) return 'Sesuai rencana $planPercent%';
  return diff < 0 ? 'Di bawah rencana $planPercent%' : 'Di atas rencana $planPercent%';
}

String _ofIncome(int part, int income) => '${formatRupiah(part)} dari income ${formatRupiah(income)}';

/// Builds the metric panel for one period. Emergency Fund Coverage and
/// Available to Spend are point-in-time figures at the metrics' `now`.
List<HealthMetric> buildHealthMetrics(FinancialMetrics m, PlanningSetting plan) {
  final income = m.summary.income;
  final net = m.summary.netCashFlow;
  final emergency = m.emergency;
  final coverage = emergency.coverageMonths;
  final available = m.available;
  final savingsTarget = plan.savingsPercent + plan.emergencyPercent;

  return [
    HealthMetric(
      kind: HealthMetricKind.netCashFlow,
      value: formatRupiah(net, signed: true),
      benchmark: 'Acuan: ≥ Rp 0 (income menutup expense)',
      source: 'Total Income − Total Expense dari transaksi confirmed. Transfer tidak dihitung.',
      comparison: net > 0 ? 'Surplus' : (net < 0 ? 'Defisit' : 'Seimbang'),
      detail: 'Income ${formatRupiah(income)} · Expense ${formatRupiah(m.summary.expense)}',
    ),
    HealthMetric(
      kind: HealthMetricKind.savingsRate,
      value: formatPercent(m.savingsRate, decimals: 1),
      benchmark: 'Rencana Savings + Emergency Fund: $savingsTarget%',
      source: 'Net Amount Saved ÷ Total Income × 100. Net Amount Saved = kontribusi bersih '
          'ke goal Savings/Emergency/Development (di luar transfer ke account Savings) '
          '+ transfer bersih ke account Savings dari account lain.',
      comparison: comparePlan(m.savingsRate, savingsTarget),
      detail: _ofIncome(m.netSaved, income),
    ),
    HealthMetric(
      kind: HealthMetricKind.essentialRatio,
      value: formatPercent(m.essentialRatio, decimals: 1),
      benchmark: 'Rencana Essential Spending: ${plan.essentialPercent}%',
      source: 'Expense kategori dengan sifat essential ÷ Total Income × 100.',
      comparison: comparePlan(m.essentialRatio, plan.essentialPercent),
      detail: _ofIncome(m.essentialExpense, income),
    ),
    HealthMetric(
      kind: HealthMetricKind.familyRatio,
      value: formatPercent(m.familyRatio, decimals: 1),
      benchmark: 'Rencana Family Support: ${plan.familyPercent}%',
      source: 'Expense kategori planning bucket Family ÷ Total Income × 100.',
      comparison: comparePlan(m.familyRatio, plan.familyPercent),
      detail: _ofIncome(m.familySupport, income),
    ),
    HealthMetric(
      kind: HealthMetricKind.developmentRatio,
      value: formatPercent(m.developmentRatio, decimals: 1),
      benchmark: 'Rencana Development Fund: ${plan.developmentPercent}%',
      source: 'Expense bucket Development + kontribusi bersih ke goal Development ÷ Total Income × 100.',
      comparison: comparePlan(m.developmentRatio, plan.developmentPercent),
      detail: _ofIncome(m.developmentAllocation, income),
    ),
    HealthMetric(
      kind: HealthMetricKind.budgetUsage,
      value: formatPercent(m.budgetUsage, decimals: 1),
      benchmark: 'Batas: 100% dari total budget aktif',
      source: 'Total expense aktual kategori ber-budget ÷ total budget aktif pada bulan yang dipilih × 100.',
      comparison: switch (m.budgetUsage) {
        null => null,
        final u when u > 100 => 'Melewati total budget',
        final u when u >= 100 => 'Tepat di batas budget',
        _ => 'Di bawah total budget',
      },
      detail: m.budgetTotal == 0
          ? 'Belum ada budget aktif pada bulan tersebut'
          : '${formatRupiah(m.budgetUsed)} dari budget ${formatRupiah(m.budgetTotal)}',
    ),
    HealthMetric(
      kind: HealthMetricKind.emergencyCoverage,
      value: coverage == null ? 'N/A' : formatMonths(coverage),
      benchmark: 'Target: ${emergency.targetMonths} bulan'
          '${emergency.targetAmount > 0 ? ' (≈ ${formatRupiah(emergency.targetAmount)})' : ''}',
      source: 'Saldo goal Emergency aktif ÷ rata-rata expense essential '
          '${emergency.lookbackMonths} bulan penuh terakhir.',
      comparison: coverage == null
          ? null
          : (coverage >= emergency.targetMonths ? 'Mencapai target' : 'Di bawah target'),
      detail: 'Saldo ${formatRupiah(emergency.balance)} · rata-rata essential '
          '${formatRupiah(emergency.avgEssentialMonthly.round())}/bulan',
    ),
    HealthMetric(
      kind: HealthMetricKind.recurringRatio,
      value: formatPercent(m.recurringRatio, decimals: 1),
      benchmark: 'Tanpa target; menunjukkan porsi income untuk kewajiban rutin',
      source: 'Expense confirmed yang berasal dari transaksi berulang ÷ Total Income × 100.',
      detail: _ofIncome(m.recurringExpense, income),
    ),
    HealthMetric(
      kind: HealthMetricKind.availableToSpend,
      value: formatRupiah(available.value),
      benchmark: 'Acuan: ≥ Rp 0 setelah semua cadangan',
      source: 'Total Balance − reserved (goal, sisa alokasi Family, reserve manual) '
          '− upcoming obligations − minimum cash buffer.',
      comparison: available.value < 0 ? 'Cadangan melebihi saldo' : null,
      detail: 'Total Balance ${formatRupiah(available.totalBalance)} · '
          'reserved ${formatRupiah(available.reserved)} · '
          'obligations ${formatRupiah(available.upcomingObligations)} · '
          'buffer ${formatRupiah(available.minimumCashBuffer)}',
    ),
  ];
}

/// Neutral, factual summary sentences (no judgement, no score).
List<String> healthSummary(FinancialMetrics m) {
  final e = m.emergency;
  final coverage = e.coverageMonths;
  final net = m.summary.netCashFlow;
  return [
    if (m.summary.income == 0 && m.summary.expense == 0)
      'Belum ada income atau expense confirmed pada periode ini.'
    else if (net >= 0)
      'Income melebihi expense sebesar ${formatRupiah(net)} pada periode ini.'
    else
      'Expense melebihi income sebesar ${formatRupiah(-net)} pada periode ini.',
    if (coverage != null)
      'Emergency fund menutup ${formatMonths(coverage)} dari target ${e.targetMonths} bulan.'
    else
      'Emergency Fund Coverage belum bisa dihitung: belum ada expense essential '
          'dalam ${e.lookbackMonths} bulan penuh terakhir.',
  ];
}
