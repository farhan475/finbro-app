import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/goal_repository.dart';
import '../goal_paths.dart';
import 'goal_widgets.dart';

enum _GoalFilter {
  all('Semua'),
  active('Aktif'),
  done('Selesai');

  const _GoalFilter(this.label);
  final String label;
}

/// "Tujuan Keuangan": Semua / Aktif / Selesai filter (reference), Emergency
/// Fund first, then other goals. Selesai = reached 100%.
class GoalsScreen extends ConsumerStatefulWidget {
  const GoalsScreen({super.key});

  @override
  ConsumerState<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends ConsumerState<GoalsScreen> {
  _GoalFilter _filter = _GoalFilter.all;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final goals = ref.watch(goalsProvider);
    final now = ref.watch(clockProvider)();
    bool reached(GoalProgress p) => p.reached;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tujuan Keuangan'),
            Text('Goals', style: context.text.bodySmall!.copyWith(color: fin.muted)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Financial planning',
            icon: const Icon(Icons.tune),
            onPressed: () => context.push(Routes.planning),
          ),
          IconButton(
            tooltip: 'Tambah Tujuan',
            icon: const Icon(Icons.add),
            onPressed: () => context.push(GoalPaths.create()),
          ),
        ],
      ),
      body: AsyncView(
        value: goals,
        builder: (all) {
          final emergency = [
            for (final p in all)
              if (p.goal.isActive && p.goal.type == GoalType.emergency) p,
          ];
          final others = [
            for (final p in all)
              if (p.goal.isActive && p.goal.type != GoalType.emergency)
                if (_filter == _GoalFilter.all || (_filter == _GoalFilter.active) != reached(p)) p,
          ];
          final done = [
            for (final p in all)
              if (p.goal.isActive && reached(p)) p,
          ];
          final archived = [
            for (final p in all)
              if (!p.goal.isActive) p,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final f in _GoalFilter.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (_filter == _GoalFilter.done) ...[
                if (done.isEmpty)
                  const EmptyState(
                    icon: Icons.emoji_events_outlined,
                    title: 'Belum ada tujuan yang tercapai',
                    message: 'Tujuan yang mencapai 100% muncul di sini.',
                  )
                else
                  for (final g in done) ...[GoalCard(progress: g, now: now), const SizedBox(height: 8)],
              ] else ...[
                _EmergencyCard(goals: emergency),
                const SizedBox(height: 8),
                const SectionHeader('Tujuan lainnya'),
                if (others.isEmpty)
                  const EmptyState(
                    icon: Icons.flag_outlined,
                    title: 'Belum ada tujuan lain',
                    message: 'Contoh: laptop baru, liburan, atau dana pendidikan.',
                  )
                else
                  for (final g in others) ...[GoalCard(progress: g, now: now), const SizedBox(height: 8)],
              ],
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: () => context.push(GoalPaths.create()),
                icon: const Icon(Icons.add),
                label: const Text('Tambah Tujuan'),
                style: OutlinedButton.styleFrom(backgroundColor: fin.surface2, side: BorderSide.none),
              ),
              if (archived.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text('Diarsipkan (${archived.length})', style: context.text.titleSmall),
                  children: [
                    for (final g in archived) ...[GoalCard(progress: g, now: now), const SizedBox(height: 8)],
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// §14 Emergency Fund: coverage months vs target, target = average essential
/// expense × target months (not the goal's own target amount).
class _EmergencyCard extends ConsumerWidget {
  const _EmergencyCard({required this.goals});

  /// Active emergency-type goals (their progress sum is the Emergency Fund Balance).
  final List<GoalProgress> goals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    return AsyncView(
      value: ref.watch(emergencyStatusProvider),
      builder: (EmergencyStatus s) {
        final target = s.targetAmount;
        final progress = target > 0 ? goalProgress(s.balance, target) : null;
        final coverage = s.coverageMonths;
        return FinCard(
          onTap: goals.length == 1 ? () => context.push(GoalPaths.goalDetail(goals.single.goal.id)) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const GoalIcon(GoalType.emergency),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Emergency Fund', style: context.text.titleSmall)),
                  Text(formatPercent(progress), style: context.text.titleSmall),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${formatRupiah(s.balance)} / ${target > 0 ? formatRupiah(target) : 'N/A'}',
                style: context.text.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              FinProgressBar(percent: progress ?? 0),
              const SizedBox(height: 8),
              Text(
                'Coverage ${coverage == null ? 'N/A' : '${formatMonths(coverage)} bulan'} '
                'dari target ${s.targetMonths} bulan',
                style: context.text.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                s.avgEssentialMonthly > 0
                    ? 'Rata-rata essential expense ${s.lookbackMonths} bulan terakhir: '
                          '${formatRupiah(s.avgEssentialMonthly.round())}/bulan × ${s.targetMonths} bulan'
                    : 'Rata-rata essential expense ${s.lookbackMonths} bulan terakhir belum ada, '
                          'target belum bisa dihitung.',
                style: muted,
              ),
              if (goals.isEmpty) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => context.push(GoalPaths.create(GoalType.emergency)),
                  icon: const Icon(Icons.add),
                  label: const Text('Buat Emergency Fund'),
                ),
              ] else if (goals.length > 1) ...[
                const Divider(height: 24),
                for (final g in goals)
                  InkWell(
                    onTap: () => context.push(GoalPaths.goalDetail(g.goal.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text(g.goal.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 8),
                          AmountText(g.saved),
                          Icon(Icons.chevron_right, size: 18, color: fin.muted),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
