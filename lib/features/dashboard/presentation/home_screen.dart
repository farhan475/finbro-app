import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/enums.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../reports/domain/report_shaping.dart';
import '../data/dashboard_providers.dart';
import 'available_breakdown_sheet.dart';
import 'home_sections.dart';

/// `Good Morning` (04–11), `Good Afternoon` (11–18), `Good Evening` otherwise.
String greetingFor(DateTime now) {
  final h = now.hour;
  if (h >= 4 && h < 11) return 'Good Morning';
  if (h >= 11 && h < 18) return 'Good Afternoon';
  return 'Good Evening';
}

/// Dashboard (06-ux §9): answers "how much money, where, what came in/out,
/// what is safe to spend, what is coming next".
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider)();
    final name = ref.watch(appSettingsProvider).value?[SettingKeys.userName]?.trim() ?? '';

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        heroTag: 'home-fab',
        tooltip: 'Tambah transaksi',
        onPressed: () => context.push(Routes.transactionNew()),
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            _Header(greeting: greetingFor(now), name: name),
            const SizedBox(height: 20),
            const _OverviewSection(),
            SectionHeader(
              'Cash Flow',
              actionLabel: 'Laporan',
              onAction: () => context.push(Routes.reports),
            ),
            const CashFlowCard(),
            SectionHeader(
              'Top Spending',
              actionLabel: 'Detail',
              onAction: () => context.push(Routes.reports),
            ),
            const TopSpendingCard(),
            SectionHeader('Budget', actionLabel: 'Lihat semua', onAction: () => context.go(Routes.budget)),
            const BudgetProgressCard(),
            SectionHeader(
              'Upcoming',
              actionLabel: 'Lihat semua',
              onAction: () => context.push(Routes.recurring),
            ),
            const UpcomingCard(),
            SectionHeader('Tujuan Keuangan', actionLabel: 'Lihat semua', onAction: () => context.go(Routes.goals)),
            const GoalsCard(),
            SectionHeader(
              'Transaksi terbaru',
              actionLabel: 'Lihat semua',
              onAction: () => context.go(Routes.activity),
            ),
            const RecentTransactionsCard(),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.greeting, required this.name});
  final String greeting;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const FinBroMark(size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? greeting : '$greeting,',
                style: name.isEmpty ? context.text.titleLarge : context.text.bodyMedium!.copyWith(color: context.fin.muted),
              ),
              if (name.isNotEmpty)
                Text(name, style: context.text.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Laporan',
          icon: const Icon(Icons.insights_outlined),
          onPressed: () => context.push(Routes.reports),
        ),
      ],
    );
  }
}

/// Available to Spend, quick actions, balance + accounts, income/expense.
class _OverviewSection extends ConsumerWidget {
  const _OverviewSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(homeOverviewProvider),
      builder: (o) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AvailableToSpend(overview: o),
          const SizedBox(height: 16),
          const _QuickActions(),
          const SizedBox(height: 16),
          if (o.balances.isEmpty)
            FinCard(
              child: EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Belum ada account',
                message: 'Tambahkan account (bank, e-wallet, cash) untuk mulai mencatat.',
                actionLabel: 'Tambah account',
                onAction: () => context.push(Routes.accounts),
              ),
            )
          else
            _BalanceCard(overview: o),
          const SizedBox(height: 12),
          _IncomeExpenseRow(overview: o),
        ],
      ),
    );
  }
}

class _AvailableToSpend extends StatelessWidget {
  const _AvailableToSpend({required this.overview});
  final HomeOverview overview;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final value = overview.available.value;
    return Semantics(
      button: true,
      label: 'Available to Spend ${formatRupiah(value)}. Ketuk untuk rincian.',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => showAvailableBreakdownSheet(context, overview.available),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  formatRupiah(value),
                  style: context.text.displaySmall!.copyWith(
                    color: value < 0 ? fin.negative : null,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('Available to Spend', style: context.text.bodySmall),
                  const SizedBox(width: 4),
                  Icon(Icons.info_outline, size: 14, color: fin.muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final actions = [
      (Icons.add, 'Transaksi', () => context.push(Routes.transactionNew())),
      (Icons.document_scanner_outlined, 'Scan', () => context.push(Routes.scan)),
      (Icons.swap_horiz, 'Transfer', () => context.push(Routes.transactionNew(TransactionType.transfer))),
      (Icons.calendar_month_outlined, 'Kalender', () => context.push(Routes.calendar)),
    ];
    return Row(
      children: [
        for (final (i, (icon, label, onTap)) in actions.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: FinCard(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              onTap: onTap,
              child: Column(
                children: [
                  Icon(icon, size: 22),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: context.text.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.overview});
  final HomeOverview overview;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return FinCard(
      onTap: () => context.push(Routes.accounts),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Total Balance', style: context.text.bodySmall)),
              Text('${overview.balances.length} account', style: context.text.labelSmall),
              Icon(Icons.chevron_right, size: 18, color: fin.muted),
            ],
          ),
          const SizedBox(height: 2),
          AmountText(overview.totalBalance, style: context.text.headlineSmall),
          const SizedBox(height: 12),
          SizedBox(
            height: 58,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: overview.balances.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final b = overview.balances[i];
                return Container(
                  width: 150,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: fin.surface2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        b.account.icon == null ? accountTypeIcon(b.account.type) : iconFor(b.account.icon),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              b.account.name,
                              style: context.text.labelMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            AmountText(b.balance, style: context.text.bodySmall!.copyWith(color: fin.text)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _IncomeExpenseRow extends StatelessWidget {
  const _IncomeExpenseRow({required this.overview});
  final HomeOverview overview;

  @override
  Widget build(BuildContext context) {
    final prev = overview.previousPeriod;
    final last = DateTime(prev.end.year, prev.end.month, prev.end.day - 1);
    final caption = overview.partial
        ? 'vs ${formatDayShort(prev.start)}–${formatDayShort(last)}'
        : 'vs ${formatMonth(prev.start)}';
    return Row(
      children: [
        Expanded(
          child: _FlowCard(
            label: 'Income',
            amount: overview.month.income,
            change: formatChange(percentChange(overview.month.income, overview.previous.income)),
            caption: caption,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _FlowCard(
            label: 'Expense',
            amount: overview.month.expense,
            change: formatChange(percentChange(overview.month.expense, overview.previous.expense)),
            caption: caption,
          ),
        ),
      ],
    );
  }
}

class _FlowCard extends StatelessWidget {
  const _FlowCard({required this.label, required this.amount, required this.change, required this.caption});
  final String label;
  final int amount;
  final String change;
  final String caption;

  @override
  Widget build(BuildContext context) => FinCard(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label bulan ini', style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: AmountText(amount, style: context.text.titleMedium),
        ),
        const SizedBox(height: 4),
        Text(change, style: context.text.labelMedium),
        Text(caption, style: context.text.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    ),
  );
}
