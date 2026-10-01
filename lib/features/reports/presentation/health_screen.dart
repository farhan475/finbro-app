import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
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
                  FinCard(
                    color: context.fin.surface2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in healthSummary(data.metrics))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(line, style: context.text.bodyMedium),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          'Tanpa skor tunggal: setiap metric menampilkan nilai, target yang dipakai, '
                          'dan sumber datanya. Emergency Fund dan Available to Spend dihitung per hari ini.',
                          style: context.text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final m in metrics) ...[
                    _MetricCard(
                      metric: m,
                      onTap: m.kind == HealthMetricKind.availableToSpend
                          ? () => showAvailableBreakdownSheet(context, data.metrics.available)
                          : null,
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric, this.onTap});
  final HealthMetric metric;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return FinCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(metric.title, style: context.text.titleSmall)),
              const SizedBox(width: 12),
              Flexible(
                fit: FlexFit.tight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    metric.value,
                    style: context.text.titleMedium!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(metric.benchmark, style: context.text.bodySmall!.copyWith(color: fin.text)),
          if (metric.comparison != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: fin.surface2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: fin.border),
              ),
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
