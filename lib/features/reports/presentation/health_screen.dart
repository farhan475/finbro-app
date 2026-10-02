import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatting/money.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../dashboard/presentation/available_breakdown_sheet.dart';
import '../data/report_providers.dart';
import '../domain/health_metrics.dart';
import 'widgets/period_switcher.dart';

/// Financial Health metric panel (03 §20): value, benchmark and data source
/// per metric. No single score.
class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key, this.initialMonth});
  final DateTime? initialMonth;

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen> {
  late DateTime _month = monthStart(widget.initialMonth ?? ref.read(clockProvider)());

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider)();
    final next = DateTime(_month.year, _month.month + 1);
    return Scaffold(
      appBar: AppBar(title: const Text('Financial Health')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          PeriodSwitcher(
            label: formatMonth(_month),
            onPrevious: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
            onNext: next.isAfter(now) ? null : () => setState(() => _month = next),
          ),
          AsyncView(
            value: ref.watch(healthDataProvider(_month)),
            builder: (data) {
              final metrics = buildHealthMetrics(data.metrics, data.plan);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final m in metrics) ...[
                    _MetricCard(
                      metric: m,
                      onTap: m.kind == HealthMetricKind.availableToSpend
                          ? () => showAvailableBreakdownSheet(context, data.metrics.available)
                          : null,
                    ),
                    const SizedBox(height: 10),
                  ],
                  // Insight card (reference): neutral facts, no score.
                  FinCard(
                    color: context.fin.surface2,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lightbulb_outline, color: context.fin.warning),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final line in healthSummary(data.metrics))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(line, style: context.text.bodyMedium),
                                ),
                              const SizedBox(height: 4),
                              Text(
                                'Tanpa skor tunggal: setiap metric menampilkan nilai, target yang dipakai, '
                                'dan sumber datanya. Emergency Fund dan Available to Spend dihitung per hari ini.',
                                style: context.text.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

IconData _metricIcon(HealthMetricKind k) => switch (k) {
  HealthMetricKind.netCashFlow => Icons.account_balance_wallet_outlined,
  HealthMetricKind.savingsRate => Icons.pie_chart_outline,
  HealthMetricKind.essentialRatio => Icons.home_outlined,
  HealthMetricKind.familyRatio => Icons.family_restroom_outlined,
  HealthMetricKind.developmentRatio => Icons.trending_up,
  HealthMetricKind.budgetUsage => Icons.donut_large_outlined,
  HealthMetricKind.emergencyCoverage => Icons.health_and_safety_outlined,
  HealthMetricKind.recurringRatio => Icons.autorenew,
  HealthMetricKind.availableToSpend => Icons.savings_outlined,
};

/// Reference row: icon tile, title + value, share on the right and a bar;
/// benchmark, comparison and source stay below for auditability (03 §20).
class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric, this.onTap});
  final HealthMetric metric;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final percent = metric.percent;
    return FinCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: fin.accentSoft, borderRadius: BorderRadius.circular(12)),
                child: Icon(_metricIcon(metric.kind), size: 20, color: fin.accentText),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(metric.title, style: context.text.titleSmall),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        metric.value,
                        style: context.text.bodyMedium!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ),
                  ],
                ),
              ),
              if (percent != null) ...[
                const SizedBox(width: 8),
                Text(formatPercent(percent), style: context.text.labelMedium),
              ],
            ],
          ),
          if (percent != null) ...[const SizedBox(height: 10), FinProgressBar(percent: percent)],
          const SizedBox(height: 10),
          Text(metric.benchmark, style: context.text.bodySmall!.copyWith(color: fin.text)),
          if (metric.comparison != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: fin.surface2, borderRadius: BorderRadius.circular(8)),
              child: Text(metric.comparison!, style: context.text.labelSmall!.copyWith(color: fin.text)),
            ),
          ],
          if (metric.detail != null) ...[
            const SizedBox(height: 6),
            Text(metric.detail!, style: context.text.bodySmall),
          ],
          const SizedBox(height: 6),
          Text('Sumber: ${metric.source}', style: context.text.bodySmall),
          if (onTap != null) ...[
            const SizedBox(height: 4),
            Text('Ketuk untuk melihat rincian', style: context.text.labelSmall),
          ],
        ],
      ),
    );
  }
}
