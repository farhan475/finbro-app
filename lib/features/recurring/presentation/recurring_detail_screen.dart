import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/recurring_repository.dart';
import '../domain/due_dates.dart';
import 'instance_widgets.dart';

/// `/recurring/instance/:id`: resolves an instance (notification tap) to its rule.
class RecurringInstanceRedirect extends ConsumerWidget {
  const RecurringInstanceRedirect({super.key, required this.instanceId});
  final String instanceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(instanceViewProvider(instanceId));
    return view.when(
      data: (v) => v == null
          ? Scaffold(
              appBar: AppBar(),
              body: const EmptyState(icon: Icons.event_busy_outlined, title: 'Jadwal tidak ditemukan'),
            )
          : RecurringDetailScreen(ruleId: v.rule.id),
      loading: () => Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
      error: (e, _) => Scaffold(appBar: AppBar(), body: Center(child: Text('Terjadi kesalahan: $e'))),
    );
  }
}

enum _RuleAction { toggle, delete }

/// `/recurring/:id`: rule summary, open instances with actions, history.
class RecurringDetailScreen extends ConsumerWidget {
  const RecurringDetailScreen({super.key, required this.ruleId});
  final String ruleId;

  Future<void> _onAction(BuildContext context, WidgetRef ref, RecurringRule rule, _RuleAction a) async {
    final repo = ref.read(recurringRepositoryProvider);
    switch (a) {
      case _RuleAction.toggle:
        if (rule.active) {
          final ok = await confirmDialog(
            context,
            title: 'Nonaktifkan ${rule.name}?',
            message: 'Jadwal mulai hari ini dihapus dan tidak ada pengingat baru. Riwayat tetap tersimpan.',
            confirmLabel: 'Nonaktifkan',
          );
          if (!ok) return;
        }
        await repo.setActive(rule.id, !rule.active);
        if (context.mounted) showSnack(context, rule.active ? '${rule.name} dinonaktifkan' : '${rule.name} diaktifkan');
      case _RuleAction.delete:
        final ok = await confirmDialog(
          context,
          title: 'Hapus ${rule.name}?',
          message:
              'Jadwal yang belum dikonfirmasi dibatalkan. Transaksi yang sudah dikonfirmasi tetap tersimpan di ledger.',
          confirmLabel: 'Hapus',
          destructive: true,
        );
        if (!ok) return;
        await repo.delete(rule.id);
        if (context.mounted) {
          showSnack(context, '${rule.name} dihapus');
          context.pop();
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(recurringRuleDetailProvider(ruleId));
    final rule = detail.value?.rule;
    return Scaffold(
      appBar: AppBar(
        title: Text(rule?.name ?? 'Transaksi berulang', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (rule != null) ...[
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('${Routes.recurring}/${rule.id}/edit'),
            ),
            PopupMenuButton<_RuleAction>(
              onSelected: (a) => _onAction(context, ref, rule, a),
              itemBuilder: (_) => [
                PopupMenuItem(value: _RuleAction.toggle, child: Text(rule.active ? 'Nonaktifkan' : 'Aktifkan')),
                const PopupMenuItem(value: _RuleAction.delete, child: Text('Hapus')),
              ],
            ),
          ],
        ],
      ),
      body: AsyncView(
        value: detail,
        builder: (d) {
          if (d == null) {
            return const EmptyState(icon: Icons.event_busy_outlined, title: 'Transaksi berulang tidak ditemukan');
          }
          final open = d.instances.where((i) => i.status.isOpen).toList().reversed.toList();
          final history = d.instances.where((i) => !i.status.isOpen).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              _Summary(d.rule),
              const SizedBox(height: 8),
              const SectionHeader('Terjadwal'),
              if (open.isEmpty)
                EmptyState(
                  icon: Icons.event_available_outlined,
                  title: d.rule.active ? 'Tidak ada jadwal terbuka' : 'Aturan nonaktif',
                  message: d.rule.active ? null : 'Aktifkan lagi untuk membuat jadwal mulai hari ini.',
                )
              else
                FinCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < open.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        InstanceTile(InstanceView(open[i], d.rule), expanded: true, showRuleName: false),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              const SectionHeader('Riwayat'),
              if (history.isEmpty)
                const EmptyState(icon: Icons.history, title: 'Belum ada riwayat')
              else
                FinCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < history.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        InstanceTile(InstanceView(history[i], d.rule), showRuleName: false),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Summary extends ConsumerWidget {
  const _Summary(this.rule);
  final RecurringRule rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final isIncome = rule.type == TransactionType.income;
    final account = ref.watch(accountMapProvider)[rule.accountId]?.name ?? '-';
    final category = ref.watch(categoryMapProvider)[rule.categoryId]?.name ?? '-';
    final end = rule.endDate;
    final rows = <(String, String)>[
      ('Jenis', isIncome ? 'Income' : 'Expense'),
      ('Jadwal', RecurrenceSpec.fromRule(rule).describe()),
      ('Mulai', formatDay(rule.startDate)),
      ('Selesai', end == null ? 'Tidak ditentukan' : formatDay(end)),
      (isIncome ? 'Masuk ke' : 'Dari', account),
      ('Kategori', category),
      (
        'Pengingat',
        rule.reminderEnabled ? '${reminderOffsetLabel(rule.reminderOffsetDays)} · ${rule.reminderTime}' : 'Nonaktif',
      ),
      ('Auto-confirm', rule.autoConfirm ? 'Aktif' : 'Nonaktif (konfirmasi manual)'),
      ('Status', rule.active ? 'Aktif' : 'Nonaktif'),
    ];
    return FinCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Nominal per jadwal', style: context.text.bodySmall),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: AmountText(
              isIncome ? rule.amount : -rule.amount,
              colorize: isIncome,
              signed: true,
              style: context.text.headlineSmall,
            ),
          ),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 110, child: Text(label, style: context.text.bodySmall?.copyWith(color: fin.muted))),
                  Expanded(child: Text(value, style: context.text.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
