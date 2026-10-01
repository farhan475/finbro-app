import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/recurring_repository.dart';
import '../domain/due_dates.dart';
import 'instance_widgets.dart';

/// `/recurring`: rules with next due + status, and instances awaiting
/// confirmation.
class RecurringListScreen extends ConsumerWidget {
  const RecurringListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(recurringRulesProvider);
    final pending = [
      for (final v in ref.watch(openInstancesProvider).value ?? const <InstanceView>[])
        if (v.instance.status == RecurringStatus.pending) v,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaksi Berulang'),
        actions: [
          IconButton(
            tooltip: 'Kalender',
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: () => context.push(Routes.calendar),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('${Routes.recurring}/new'),
        icon: const Icon(Icons.add),
        label: const Text('Tambah'),
      ),
      body: AsyncView(
        value: rules,
        builder: (list) {
          if (list.isEmpty) {
            return Center(
              child: EmptyState(
                icon: Icons.event_repeat,
                title: 'Belum ada transaksi berulang',
                message: 'Catat salary, tagihan, dan langganan agar jadwalnya muncul di kalender dan diingatkan.',
                actionLabel: 'Tambah Salary',
                onAction: () => context.push('${Routes.recurring}/new?preset=salary'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
            children: [
              if (pending.isNotEmpty) ...[
                const SectionHeader('Perlu konfirmasi'),
                FinCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < pending.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        InstanceTile(pending[i], expanded: true),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SectionHeader('Jadwal'),
              for (final o in list) _RuleCard(o),
            ],
          );
        },
      ),
    );
  }
}

class _RuleCard extends ConsumerWidget {
  const _RuleCard(this.overview);
  final RuleOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final rule = overview.rule;
    final category = ref.watch(categoryMapProvider)[rule.categoryId];
    final account = ref.watch(accountMapProvider)[rule.accountId]?.name ?? '-';
    final isIncome = rule.type == TransactionType.income;
    final next = overview.next;
    final nextText = !rule.active
        ? 'Nonaktif'
        : next == null
        ? 'Tidak ada jadwal berikutnya'
        : 'Berikutnya ${formatDayShort(next.dueDate)}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FinCard(
        onTap: () => context.push('${Routes.recurring}/${rule.id}'),
        child: Row(
          children: [
            IconAvatar(iconFor(category?.icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rule.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '${RecurrenceSpec.fromRule(rule).describe()} · $account',
                    style: context.text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      StatusPill(nextText),
                      if (overview.pendingCount > 0)
                        StatusPill('Perlu konfirmasi (${overview.pendingCount})', color: fin.warning),
                      if (rule.autoConfirm && rule.active) const StatusPill('Auto-confirm'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AmountText(
              isIncome ? rule.amount : -rule.amount,
              colorize: isIncome,
              signed: true,
              style: context.text.titleSmall?.copyWith(color: rule.active ? null : fin.muted),
            ),
          ],
        ),
      ),
    );
  }
}
