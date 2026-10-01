import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../../shared/widgets/transaction_tile.dart';
import '../data/report_providers.dart';
import '../domain/report_shaping.dart';
import '../reports_routes.dart';
import 'report_labels.dart';
import 'widgets/period_switcher.dart';
import 'report_pdf_export.dart';
import 'widgets/report_charts.dart';

/// Laporan: monthly/yearly summary, trends, composition, ranking, budget.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportScope _scope = ReportScope.monthly;
  late DateTime _anchor = ref.read(clockProvider)();
  bool _exporting = false;

  Future<void> _exportPdf(ReportQuery query) async {
    setState(() => _exporting = true);
    try {
      await exportReportPdf(context, ref, query);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider)();
    final query = (scope: _scope, anchor: _scope.periodFor(_anchor).start);
    final next = _scope.shift(query.anchor, 1);
    // Financial Health is monthly: open the selected month, or for a year the
    // current month (this year) / December (past years).
    final healthMonth = switch (_scope) {
      ReportScope.monthly => query.anchor,
      ReportScope.yearly =>
        query.anchor.year >= now.year ? DateTime(now.year, now.month) : DateTime(query.anchor.year, 12),
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Laporan'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            icon: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _exporting ? null : () => _exportPdf(query),
          ),
          IconButton(
            tooltip: 'Financial Health',
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => context.push(healthLocation(healthMonth)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SegmentedButton<ReportScope>(
            segments: [
              for (final s in ReportScope.values) ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_scope},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _scope = s.first),
          ),
          const SizedBox(height: 4),
          PeriodSwitcher(
            label: periodTitle(_scope, query.anchor),
            onPrevious: () => setState(() => _anchor = _scope.shift(query.anchor, -1)),
            onNext: next.isAfter(now) ? null : () => setState(() => _anchor = next),
          ),
          _SummarySection(query: query),
          const SectionHeader('Income vs Expense'),
          FinCard(
            child: AsyncView(
              value: ref.watch(reportTrendProvider(query)),
              builder: (points) => IncomeExpenseBarChart(points: points),
            ),
          ),
          _SpendingSections(query: query),
          if (_scope == ReportScope.monthly) ...[
            const SectionHeader('Budget vs Actual'),
            FinCard(
              child: AsyncView(
                value: ref.watch(reportBudgetProvider(query.anchor)),
                builder: (items) => items.isEmpty
                    ? const EmptyState(
                        icon: Icons.pie_chart_outline,
                        title: 'Belum ada budget',
                        message: 'Budget yang aktif pada bulan ini akan dibandingkan dengan expense aktual.',
                      )
                    : BudgetActualBars(items: items),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FinCard(
            onTap: () => context.push(healthLocation(healthMonth)),
            child: Row(
              children: [
                const Icon(Icons.monitor_heart_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Financial Health', style: context.text.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        'Savings rate, essential ratio, emergency fund, dan metric lain beserta target dan sumber datanya.',
                        style: context.text.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummarySection extends ConsumerWidget {
  const _SummarySection({required this.query});
  final ReportQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(reportOverviewProvider(query)),
      builder: (o) {
        final caption = comparisonCaption(o.previousPeriod, query.scope, partial: o.partial);
        final netDiff = o.current.netCashFlow - o.previous.netCashFlow;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader('Ringkasan'),
            FinCard(
              child: Column(
                children: [
                  _SummaryRow(
                    label: 'Total Income',
                    value: formatRupiah(o.current.income),
                    change: formatChange(percentChange(o.current.income, o.previous.income)),
                    caption: caption,
                  ),
                  const Divider(height: 20),
                  _SummaryRow(
                    label: 'Total Expense',
                    value: formatRupiah(o.current.expense),
                    change: formatChange(percentChange(o.current.expense, o.previous.expense)),
                    caption: caption,
                  ),
                  const Divider(height: 20),
                  _SummaryRow(
                    label: 'Net Cash Flow',
                    value: formatRupiah(o.current.netCashFlow, signed: true),
                    // Percent change of a value that can flip sign is misleading;
                    // show the absolute change instead (03 §17).
                    change: netDiff == 0 ? 'Rp 0' : formatRupiah(netDiff, signed: true),
                    caption: caption,
                  ),
                  const Divider(height: 20),
                  _SummaryRow(
                    label: 'Savings Rate',
                    value: formatPercent(o.savingsRate, decimals: 1),
                    change: formatPointChange(o.savingsRate, o.previousSavingsRate),
                    caption: caption,
                    footnote: 'Net Amount Saved ${formatRupiah(o.netSaved)} ÷ Total Income',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SpendingSections extends ConsumerWidget {
  const _SpendingSections({required this.query});
  final ReportQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(reportOverviewProvider(query)),
      builder: (o) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Spending'),
          FinCard(child: SpendingDonut(slices: o.slices)),
          const SectionHeader('Top Spending'),
          FinCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Kategori', style: context.text.labelMedium),
                const SizedBox(height: 4),
                RankingBars(
                  items: [
                    for (final c in o.categories.take(5)) (label: c.name, amount: c.amount, share: c.share),
                  ],
                ),
                if (o.topTransactions.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text('Transaksi terbesar', style: context.text.labelMedium),
                  for (final tx in o.topTransactions) TransactionTile(tx),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    required this.change,
    required this.caption,
    this.footnote,
  });

  final String label;
  final String value;
  final String change;
  final String caption;
  final String? footnote;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: context.text.bodyMedium),
            const SizedBox(height: 2),
            Text('$change $caption', style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (footnote != null)
              Text(footnote!, style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 2,
        child: Align(
          alignment: Alignment.topRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              style: context.text.titleSmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ),
      ),
    ],
  );
}
