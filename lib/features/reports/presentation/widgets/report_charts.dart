import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/finance/finance_service.dart';
import '../../../../core/formatting/dates.dart';
import '../../../../core/formatting/money.dart';
import '../../../../shared/widgets/fin_widgets.dart';
import '../../domain/report_shaping.dart';

/// Axis-less accent line with a fading fill (Home balance card). [values]
/// are plotted left to right; a single value is drawn as a flat line.
class BalanceSparkline extends StatelessWidget {
  const BalanceSparkline({super.key, required this.values, this.height = 84});
  final List<int> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    final accent = context.fin.accent;
    final v = values.isEmpty ? const [0, 0] : (values.length == 1 ? [values.first, values.first] : values);
    final lo = v.reduce(math.min).toDouble();
    final hi = v.reduce(math.max).toDouble();
    final pad = hi == lo ? (hi.abs() * 0.1 + 1) : (hi - lo) * 0.15;
    return SizedBox(
      height: height,
      child: ExcludeSemantics(
        child: LineChart(
          LineChartData(
            minY: lo - pad,
            maxY: hi + pad,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: const FlTitlesData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: [for (var i = 0; i < v.length; i++) FlSpot(i.toDouble(), v[i].toDouble())],
                color: accent,
                barWidth: 2.2,
                isCurved: true,
                preventCurveOverShooting: true,
                dotData: FlDotData(
                  // Every third point plus the latest, as in the reference.
                  checkToShowDot: (s, _) => s.x % 3 == 0 || s.x == v.length - 1,
                  getDotPainter: (_, _, _, _) =>
                      FlDotCirclePainter(radius: 2.4, color: accent, strokeWidth: 0),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [accent.withValues(alpha: 0.28), accent.withValues(alpha: 0)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Legend entry: swatch (solid or dashed line) + label.
class LegendItem {
  const LegendItem(this.label, this.color, {this.dashed = false, this.value});
  final String label;
  final Color color;
  final bool dashed;
  final String? value;
}

class ChartLegend extends StatelessWidget {
  const ChartLegend(this.items, {super.key});
  final List<LegendItem> items;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 6,
    children: [
      for (final i in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Swatch(color: i.color, dashed: i.dashed),
            const SizedBox(width: 6),
            Text(i.value == null ? i.label : '${i.label} ${i.value}', style: context.text.labelMedium),
          ],
        ),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.dashed});
  final Color color;
  final bool dashed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    height: 10,
    child: Center(
      child: Row(
        children: [
          for (var i = 0; i < (dashed ? 3 : 1); i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(width: dashed ? 4.6 : 18, height: 2.5, color: color),
          ],
        ],
      ),
    ),
  );
}

/// Placeholder shown instead of a chart when every value is zero.
class ChartEmpty extends StatelessWidget {
  const ChartEmpty(this.message, {super.key, this.height = 140});
  final String message;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(
      child: Text(message, style: context.text.bodySmall, textAlign: TextAlign.center),
    ),
  );
}

/// Axis labels live in fixed reserved space; past 1.2× they overlapped and
/// were clipped (200% font), so they stop growing there. Values stay readable
/// in the legends/tables, which do scale.
Widget _axisLabel(BuildContext context, TitleMeta meta, String text) => SideTitleWidget(
  meta: meta,
  space: 6,
  child: Text(
    text,
    style: context.text.labelSmall,
    maxLines: 1,
    softWrap: false,
    textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
  ),
);

AxisTitles get _hidden => const AxisTitles(sideTitles: SideTitles(showTitles: false));

/// Cumulative income (solid) vs expense (dashed) through the month.
class CashFlowLineChart extends StatelessWidget {
  const CashFlowLineChart({super.key, required this.points, required this.daysInPeriod, this.height = 170});

  final List<CashFlowPoint> points;
  final int daysInPeriod;
  final double height;

  static const incomeLabel = 'Income';
  static const expenseLabel = 'Expense';

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final incomeColor = fin.accent;
    final expenseColor = fin.chart[1];
    final last = points.isEmpty ? null : points.last;
    if (last == null || (last.income == 0 && last.expense == 0)) {
      return ChartEmpty('Belum ada income atau expense bulan ini.', height: height);
    }
    final maxY = niceAxisMax(math.max(last.income, last.expense));
    List<FlSpot> spots(int Function(CashFlowPoint p) pick) => [
      for (final p in points) FlSpot(p.day.day.toDouble(), pick(p).toDouble()),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minX: 1,
              maxX: daysInPeriod.toDouble(),
              minY: 0,
              maxY: maxY,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: maxY / 4,
                getDrawingHorizontalLine: (_) => FlLine(color: fin.border, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                topTitles: _hidden,
                rightTitles: _hidden,
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: maxY / 2,
                    getTitlesWidget: (v, meta) => _axisLabel(context, meta, formatRupiahCompact(v)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: 1,
                    getTitlesWidget: (v, meta) {
                      final day = v.round();
                      final show = v == day && (day == 1 || day % 7 == 0);
                      return show ? _axisLabel(context, meta, '$day') : const SizedBox.shrink();
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => fin.surface2,
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        '${s.barIndex == 0 ? incomeLabel : expenseLabel} '
                        '${formatRupiahCompact(s.y)}',
                        context.text.labelSmall!.copyWith(color: fin.text),
                      ),
                  ],
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots((p) => p.income),
                  color: incomeColor,
                  barWidth: 2.2,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [incomeColor.withValues(alpha: 0.22), incomeColor.withValues(alpha: 0)],
                    ),
                  ),
                ),
                LineChartBarData(
                  spots: spots((p) => p.expense),
                  color: expenseColor,
                  barWidth: 2.2,
                  dashArray: const [6, 4],
                  dotData: const FlDotData(show: false),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        ChartLegend([
          LegendItem(incomeLabel, incomeColor, value: formatRupiahCompact(last.income)),
          LegendItem(expenseLabel, expenseColor, dashed: true, value: formatRupiahCompact(last.expense)),
        ]),
      ],
    );
  }
}

/// Grouped monthly bars: income (dark) vs expense (light).
class IncomeExpenseBarChart extends StatelessWidget {
  const IncomeExpenseBarChart({super.key, required this.points, this.height = 190});
  final List<MonthPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final incomeColor = fin.accent;
    final expenseColor = fin.chart[1];
    final maxRaw = points.fold<int>(0, (m, p) => math.max(m, math.max(p.income, p.expense)));
    if (maxRaw == 0) return ChartEmpty('Belum ada income atau expense pada rentang ini.', height: height);
    final maxY = niceAxisMax(maxRaw);
    final rodWidth = points.length > 6 ? 5.0 : 9.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: BarChart(
            BarChartData(
              maxY: maxY,
              minY: 0,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: maxY / 4,
                getDrawingHorizontalLine: (_) => FlLine(color: fin.border, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                topTitles: _hidden,
                rightTitles: _hidden,
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: maxY / 2,
                    getTitlesWidget: (v, meta) => _axisLabel(context, meta, formatRupiahCompact(v)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= points.length) return const SizedBox.shrink();
                      return _axisLabel(context, meta, formatMonthShort(points[i].month));
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => fin.surface2,
                  getTooltipItem: (group, _, rod, rodIndex) => BarTooltipItem(
                    '${formatMonth(points[group.x].month)}\n'
                    '${rodIndex == 0 ? 'Income' : 'Expense'} ${formatRupiahCompact(rod.toY)}',
                    context.text.labelSmall!.copyWith(color: fin.text),
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < points.length; i++)
                  BarChartGroupData(
                    x: i,
                    barsSpace: 3,
                    barRods: [
                      BarChartRodData(
                        toY: points[i].income.toDouble(),
                        color: incomeColor,
                        width: rodWidth,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                      ),
                      BarChartRodData(
                        toY: points[i].expense.toDouble(),
                        color: expenseColor,
                        width: rodWidth,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        ChartLegend([LegendItem('Income', incomeColor), LegendItem('Expense', expenseColor)]),
      ],
    );
  }
}

/// Spending composition donut with a legend showing each share.
class SpendingDonut extends StatelessWidget {
  const SpendingDonut({super.key, required this.slices, this.size = 132});
  final List<DonutSlice> slices;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    if (slices.isEmpty) return const ChartEmpty('Belum ada expense pada periode ini.', height: 120);
    final total = slices.fold<int>(0, (s, e) => s + e.amount);
    Color colorAt(int i) => fin.chart[math.min(i, fin.chart.length - 1)];

    return Row(
      children: [
        SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  startDegreeOffset: -90,
                  sectionsSpace: 2,
                  centerSpaceRadius: size * 0.3,
                  pieTouchData: PieTouchData(enabled: false),
                  sections: [
                    for (var i = 0; i < slices.length; i++)
                      PieChartSectionData(
                        value: slices[i].amount.toDouble(),
                        color: colorAt(i),
                        radius: size * 0.18,
                        showTitle: false,
                        borderSide: BorderSide(color: fin.border, width: 0.5),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.all(size * 0.24),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(formatRupiahCompact(total), style: context.text.labelLarge),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < slices.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colorAt(i),
                          shape: BoxShape.circle,
                          border: Border.all(color: fin.border),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          slices[i].label,
                          style: context.text.bodySmall!.copyWith(color: fin.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatPercent(slices[i].share), style: context.text.labelMedium),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Horizontal ranking bars (largest first), scaled to the largest value.
class RankingBars extends StatelessWidget {
  const RankingBars({super.key, required this.items});

  /// (label, amount, share %) triples, already sorted.
  final List<({String label, int amount, double share})> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const ChartEmpty('Belum ada expense pada periode ini.', height: 80);
    final max = items.fold<int>(0, (m, e) => math.max(m, e.amount));
    return Column(
      children: [
        for (final (i, e) in items.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(width: 22, child: Text('${i + 1}', style: context.text.labelMedium)),
                    Expanded(
                      child: Text(
                        e.label,
                        style: context.text.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    AmountText(e.amount, style: context.text.labelLarge),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 40,
                      child: Text(formatPercent(e.share), style: context.text.bodySmall, textAlign: TextAlign.end),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 22),
                  child: FinProgressBar(percent: max == 0 ? 0 : e.amount / max * 100, height: 6),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Budget vs Actual per category: two bars on a shared scale plus text.
class BudgetActualBars extends StatelessWidget {
  const BudgetActualBars({super.key, required this.items});
  final List<BudgetUsageItem> items;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final scale = items.fold<int>(0, (m, e) => math.max(m, math.max(e.budget.amount, e.actual)));
    double pct(int v) => scale == 0 ? 0 : v / scale * 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.category.name,
                        style: context.text.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${formatPercent(item.usage)} · ${item.status.label}',
                      style: context.text.labelMedium!.copyWith(color: item.status.textColor(fin)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _LabeledBar(label: 'Budget', percent: pct(item.budget.amount), color: fin.chart[3]),
                const SizedBox(height: 4),
                _LabeledBar(label: 'Actual', percent: pct(item.actual), color: item.status.color(fin)),
                const SizedBox(height: 4),
                Text(
                  '${formatRupiah(item.actual)} dari ${formatRupiah(item.budget.amount)} · '
                  '${item.variance >= 0 ? 'sisa ${formatRupiah(item.variance)}' : 'lebih ${formatRupiah(-item.variance)}'}',
                  style: context.text.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        ChartLegend([LegendItem('Budget', fin.chart[3]), LegendItem('Actual', fin.accent)]),
      ],
    );
  }
}

class _LabeledBar extends StatelessWidget {
  const _LabeledBar({required this.label, required this.percent, required this.color});
  final String label;
  final double percent;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 52, child: Text(label, style: context.text.labelSmall)),
      Expanded(
        child: FinProgressBar(percent: percent, color: color, height: 6),
      ),
    ],
  );
}
