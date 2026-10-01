import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/goal_repository.dart';
import '../domain/goal_math.dart';
import '../goal_paths.dart';

IconData goalTypeIcon(GoalType t) => switch (t) {
  GoalType.emergency => Icons.health_and_safety_outlined,
  GoalType.savings => Icons.savings_outlined,
  GoalType.development => Icons.trending_up,
  GoalType.custom => Icons.flag_outlined,
};

/// `1,5` — one decimal, Indonesian separator.
String formatMonths(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Target date line: required monthly contribution, reached, or overdue.
String? goalScheduleText(Goal g, DateTime now) {
  final date = g.targetDate;
  if (date == null) return null;
  final required = requiredMonthlyContribution(
    current: g.currentAmount,
    target: g.targetAmount,
    targetDate: date,
    now: now,
  );
  final when = 'Target ${formatDay(date)}';
  if (required == 0) return '$when · target tercapai';
  if (required == null) return '$when · tanggal target terlewati';
  return '$when · perlu ${formatRupiah(required)}/bulan';
}

/// Goal summary card used in the Goals tab.
class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.goal, required this.now});
  final Goal goal;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    final progress = goalProgress(goal.currentAmount, goal.targetAmount);
    final schedule = goalScheduleText(goal, now);
    final priority = goal.priority > 0 ? ' · Prioritas ${goalPriorityLabels[goal.priority]}' : '';
    return FinCard(
      onTap: () => context.push(GoalPaths.goalDetail(goal.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconAvatar(goalTypeIcon(goal.type)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(goal.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      '${goal.type.label}$priority',
                      style: muted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(formatPercent(progress), style: context.text.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${formatRupiah(goal.currentAmount)} / ${formatRupiah(goal.targetAmount)}',
            style: context.text.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          FinProgressBar(percent: progress),
          if (schedule != null) ...[
            const SizedBox(height: 8),
            Text(schedule, style: muted),
          ],
          if (goal.monthlyTarget != null) ...[
            const SizedBox(height: 2),
            Text('Target kontribusi ${formatRupiah(goal.monthlyTarget!)}/bulan', style: muted),
          ],
        ],
      ),
    );
  }
}
