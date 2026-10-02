import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../../shared/widgets/transaction_tile.dart';
import '../../reports/presentation/widgets/report_charts.dart';
import '../data/dashboard_providers.dart';

class TopSpendingCard extends ConsumerWidget {
  const TopSpendingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FinCard(
    child: AsyncView(
      value: ref.watch(homeSpendingProvider),
      builder: (slices) => SpendingDonut(slices: slices, size: 120),
    ),
  );
}

/// Top 3 budgets by usage with status label (never color only).
class BudgetProgressCard extends ConsumerWidget {
  const BudgetProgressCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    return FinCard(
      onTap: () => context.go(Routes.budget),
      child: AsyncView(
        value: ref.watch(homeBudgetsProvider),
        builder: (items) {
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.pie_chart_outline,
              title: 'Belum ada budget bulan ini',
              actionLabel: 'Atur budget',
              onAction: () => context.go(Routes.budget),
            );
          }
          return Column(
            children: [
              for (final (i, b) in items.take(3).indexed) ...[
                if (i > 0) const SizedBox(height: 14),
                Row(
                  children: [
                    IconAvatar(iconFor(b.category.icon), size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.category.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            '${formatRupiah(b.actual)} / ${formatRupiah(b.budget.amount)}',
                            style: context.text.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatPercent(b.usage), style: context.text.labelLarge),
                        Text(b.status.label, style: context.text.labelSmall!.copyWith(color: b.status.textColor(fin))),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FinProgressBar(percent: b.usage, color: b.status.color(fin), height: 6),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// `Terlambat 2 hari`, `Hari ini`, `Besok`, `H-5`.
String dueLabel(DateTime due, DateTime today) {
  final days = dateOnly(due).difference(dateOnly(today)).inDays;
  if (days < 0) return 'Terlambat ${-days} hari';
  if (days == 0) return 'Hari ini';
  if (days == 1) return 'Besok';
  return 'H-$days';
}

/// Open recurring instances due in the next 14 days (and overdue ones).
class UpcomingCard extends ConsumerWidget {
  const UpcomingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider)();
    final categories = ref.watch(categoryMapProvider);
    return FinCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: () => context.push(Routes.recurring),
      child: AsyncView(
        value: ref.watch(upcomingRecurringProvider),
        builder: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.event_repeat_outlined,
              title: 'Tidak ada jadwal',
              message: 'Tidak ada income atau tagihan berulang dalam $upcomingWindowDays hari ke depan.',
            );
          }
          return Column(
            children: [
              for (final item in items) _UpcomingRow(item: item, now: now, category: categories[item.rule.categoryId]),
            ],
          );
        },
      ),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  const _UpcomingRow({required this.item, required this.now, required this.category});
  final UpcomingItem item;
  final DateTime now;
  final Category? category;

  @override
  Widget build(BuildContext context) {
    final income = item.rule.type == TransactionType.income;
    final instance = item.instance;
    final subtitle = [
      formatDayShort(instance.dueDate),
      dueLabel(instance.dueDate, now),
      if (instance.status == RecurringStatus.pending) 'Menunggu konfirmasi',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          IconAvatar(iconFor(category?.icon)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.rule.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(subtitle, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AmountText(
            income ? instance.amount : -instance.amount,
            colorize: income,
            signed: true,
            style: context.text.titleSmall,
          ),
        ],
      ),
    );
  }
}

/// Top 2 active goals with progress.
class GoalsCard extends ConsumerWidget {
  const GoalsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FinCard(
      onTap: () => context.push(Routes.goals),
      child: AsyncView(
        value: ref.watch(homeGoalsProvider),
        builder: (goals) {
          if (goals.isEmpty) {
            return EmptyState(
              icon: Icons.flag_outlined,
              title: 'Belum ada tujuan keuangan',
              actionLabel: 'Buat goal',
              onAction: () => context.push(Routes.goals),
            );
          }
          return Column(
            children: [
              for (final (i, g) in goals.indexed) ...[
                if (i > 0) const SizedBox(height: 14),
                _GoalRow(goal: g),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _GoalRow extends StatelessWidget {
  const _GoalRow({required this.goal});
  final Goal goal;

  @override
  Widget build(BuildContext context) {
    final progress = goalProgress(goal.currentAmount, goal.targetAmount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(goal.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Text(formatPercent(progress), style: context.text.labelLarge),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${goal.type.label} · ${formatRupiah(goal.currentAmount)} / ${formatRupiah(goal.targetAmount)}',
          style: context.text.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        FinProgressBar(percent: progress, height: 6),
      ],
    );
  }
}

class RecentTransactionsCard extends ConsumerWidget {
  const RecentTransactionsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FinCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: AsyncView(
        value: ref.watch(recentTransactionsProvider(5)),
        builder: (txs) {
          if (txs.isEmpty) {
            return EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'Belum ada transaksi',
              message: 'Catat income, expense, atau transfer pertama kamu.',
              actionLabel: 'Tambah transaksi',
              onAction: () => context.push(Routes.transactionNew()),
            );
          }
          return Column(children: [for (final tx in txs) TransactionTile(tx)]);
        },
      ),
    );
  }
}
