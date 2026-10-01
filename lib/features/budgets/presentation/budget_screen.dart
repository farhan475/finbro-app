import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../budget_paths.dart';
import '../data/budget_repository.dart';

/// Budget tab (FR-BUD-002): monthly budgets per category with actuals.
class BudgetScreen extends ConsumerStatefulWidget {
  const BudgetScreen({super.key});

  @override
  ConsumerState<BudgetScreen> createState() => _BudgetScreenState();
}

enum _MenuAction { copy, planning }

class _BudgetScreenState extends ConsumerState<BudgetScreen> {
  late DateTime _month = monthStart(ref.read(clockProvider)());

  Future<void> _copyPrevious() async {
    final n = await ref.read(budgetRepositoryProvider).copyFromPreviousMonth(_month);
    if (!mounted) return;
    final prev = formatMonth(DateTime(_month.year, _month.month - 1));
    showSnack(
      context,
      n == 0 ? 'Tidak ada budget baru dari $prev untuk disalin.' : '$n budget disalin dari $prev.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final usages = ref.watch(budgetUsagesProvider(_month));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Budget'),
        actions: [
          IconButton(
            tooltip: 'Tambah budget',
            icon: const Icon(Icons.add),
            onPressed: () => context.push(BudgetPaths.create(_month)),
          ),
          PopupMenuButton<_MenuAction>(
            onSelected: (a) => switch (a) {
              _MenuAction.copy => _copyPrevious(),
              _MenuAction.planning => context.push(Routes.planning),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: _MenuAction.copy, child: Text('Salin budget bulan lalu')),
              PopupMenuItem(value: _MenuAction.planning, child: Text('Financial planning')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: MonthSwitcher(
              month: _month,
              label: formatMonth(_month),
              onChanged: (m) => setState(() => _month = monthStart(m)),
            ),
          ),
          AsyncView(
            value: usages,
            builder: (items) => items.isEmpty
                ? Column(
                    children: [
                      EmptyState(
                        icon: Icons.pie_chart_outline,
                        title: 'Belum ada budget di ${formatMonth(_month)}',
                        message: 'Tetapkan batas pengeluaran per kategori untuk bulan ini.',
                        actionLabel: 'Buat budget',
                        onAction: () => context.push(BudgetPaths.create(_month)),
                      ),
                      TextButton.icon(
                        onPressed: _copyPrevious,
                        icon: const Icon(Icons.content_copy_outlined, size: 18),
                        label: const Text('Salin budget bulan lalu'),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _BudgetSummary(items),
                      const SizedBox(height: 8),
                      const SectionHeader('Per kategori'),
                      for (final item in items) ...[
                        _BudgetTile(item),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// "Sisa Rp X" / "Lebih Rp X" — sign in words, color only as a supplement.
class _VarianceText extends StatelessWidget {
  const _VarianceText(this.variance);
  final int variance;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final over = variance < 0;
    return Text(
      over ? 'Lebih ${formatRupiah(-variance)}' : 'Sisa ${formatRupiah(variance)}',
      style: context.text.bodySmall!.copyWith(color: over ? fin.negative : fin.muted),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _BudgetSummary extends StatelessWidget {
  const _BudgetSummary(this.items);
  final List<BudgetUsageItem> items;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final total = items.fold<int>(0, (s, i) => s + i.budget.amount);
    final used = items.fold<int>(0, (s, i) => s + i.actual);
    final usage = budgetUsage(used, total);
    final status = budgetStatus(usage);
    return FinCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Total budget', style: context.text.bodySmall!.copyWith(color: fin.muted)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: AmountText(total, style: context.text.headlineSmall),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${formatPercent(usage)} terpakai · ${status.label}',
                  style: context.text.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${formatRupiah(used)} used',
                style: context.text.bodySmall!.copyWith(color: fin.muted),
                maxLines: 1,
              ),
            ],
          ),
          const SizedBox(height: 8),
          FinProgressBar(percent: usage, color: status.color(fin)),
          const SizedBox(height: 8),
          _VarianceText(budgetVariance(total, used)),
        ],
      ),
    );
  }
}

class _BudgetTile extends StatelessWidget {
  const _BudgetTile(this.item);
  final BudgetUsageItem item;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final status = item.status;
    final color = status.color(fin);
    return FinCard(
      onTap: () => context.push(BudgetPaths.editBudget(item.budget.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconAvatar(iconFor(item.category.icon)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.category.name,
                      style: context.text.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatRupiah(item.actual)} / ${formatRupiah(item.budget.amount)}',
                      style: context.text.bodySmall!.copyWith(color: fin.muted),
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
                  Text(formatPercent(item.usage), style: context.text.titleSmall),
                  const SizedBox(height: 2),
                  Text(status.label, style: context.text.labelSmall!.copyWith(color: color)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          FinProgressBar(percent: item.usage, color: color),
          const SizedBox(height: 6),
          _VarianceText(item.variance),
        ],
      ),
    );
  }
}
