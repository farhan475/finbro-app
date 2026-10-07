import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/shell.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/enums.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../reports/presentation/widgets/report_charts.dart';
import '../../settings/presentation/settings_widgets.dart';
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

/// Dashboard (06-ux §9, layout from the UI reference): balance card with
/// trend and income/expense, top spending, then what is safe to spend and
/// what is coming next.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider)();
    final name = ref.watch(userNameProvider);

    return Scaffold(
      floatingActionButton: AboveNavBar(
        child: FloatingActionButton(
          heroTag: 'home-fab',
          tooltip: 'Tambah transaksi',
          onPressed: () => context.push(Routes.transactionNew()),
          child: const Icon(Icons.add),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, navBarClearance(context, fab: true)),
          children: [
            _Header(greeting: greetingFor(now), name: name),
            const SizedBox(height: 20),
            const ReliabilityBanners(),
            const _OverviewSection(),
            SectionHeader('Top Spending', actionLabel: 'Detail', onAction: () => context.go(Routes.reports)),
            const TopSpendingCard(),
            SectionHeader('Budget', actionLabel: 'Lihat semua', onAction: () => context.go(Routes.budget)),
            const BudgetProgressCard(),
            SectionHeader('Upcoming', actionLabel: 'Lihat semua', onAction: () => context.push(Routes.recurring)),
            const UpcomingCard(),
            SectionHeader('Tujuan Keuangan', actionLabel: 'Lihat semua', onAction: () => context.push(Routes.goals)),
            const GoalsCard(),
            SectionHeader('Akun', actionLabel: 'Kelola', onAction: () => context.push(Routes.accounts)),
            const _AccountsStrip(),
            SectionHeader('Transaksi terbaru', actionLabel: 'Lihat semua', onAction: () => context.go(Routes.activity)),
            const RecentTransactionsCard(),
          ],
        ),
      ),
    );
  }
}

/// Avatar (initial), greeting and a bell that opens pending/upcoming
/// recurring items; a dot marks items waiting for confirmation.
class _Header extends ConsumerWidget {
  const _Header({required this.greeting, required this.name});
  final String greeting;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final pending =
        ref.watch(upcomingRecurringProvider).value?.where((u) => u.instance.status == RecurringStatus.pending).length ??
        0;
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: fin.surface2,
          child: name.isEmpty
              ? const FinBroMark(size: 20)
              : Text(name.characters.first.toUpperCase(), style: context.text.titleMedium),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? greeting : '$greeting,',
                style: name.isEmpty ? context.text.titleLarge : context.text.bodyMedium!.copyWith(color: fin.muted),
              ),
              if (name.isNotEmpty)
                Text(name, style: context.text.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        IconButton(
          tooltip: pending == 0 ? 'Jadwal & pengingat' : 'Jadwal & pengingat, $pending perlu konfirmasi',
          onPressed: () => context.push(Routes.recurring),
          icon: Badge(
            isLabelVisible: pending > 0,
            smallSize: 8,
            backgroundColor: fin.accent,
            child: const Icon(Icons.notifications_none_rounded),
          ),
        ),
      ],
    );
  }
}

/// Balance card, Available to Spend and quick actions.
class _OverviewSection extends ConsumerWidget {
  const _OverviewSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(homeOverviewProvider),
      builder: (o) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          _AvailableToSpend(overview: o),
          const SizedBox(height: 12),
          const _QuickActions(),
        ],
      ),
    );
  }
}

class _BalanceCard extends ConsumerWidget {
  const _BalanceCard({required this.overview});
  final HomeOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final hidden = ref.watch(hideBalanceProvider);
    final path = ref.watch(homeBalancePathProvider).value ?? [overview.totalBalance];
    final start = path.first;
    final change = start > 0 ? percentChange(overview.totalBalance, start) : null;
    String money(int v) => hidden ? 'Rp ••••••' : formatRupiah(v);

    return FinCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Total Balance', style: context.text.bodySmall),
              SizedBox(
                width: 36,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: hidden ? 'Tampilkan saldo' : 'Sembunyikan saldo',
                  color: fin.muted,
                  icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => ref
                      .read(appSettingsRepositoryProvider)
                      .setBool(SettingKeys.hideBalance, !hidden),
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => context.push(Routes.accounts),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Text('${overview.balances.length} account', style: context.text.labelSmall),
                      Icon(Icons.chevron_right, size: 18, color: fin.muted),
                    ],
                  ),
                ),
              ),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              money(overview.totalBalance),
              style: context.text.displaySmall!.copyWith(
                fontSize: 30,
                color: !hidden && overview.totalBalance < 0 ? fin.negative : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (change != null && !hidden) ...[const SizedBox(height: 4), _ChangeLine(change: change)],
          const SizedBox(height: 12),
          if (hidden) const SizedBox(height: 84) else BalanceSparkline(values: path),
          const SizedBox(height: 12),
          Divider(color: fin.border),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _FlowFigure(label: 'Income', value: money(overview.month.income)),
                ),
                VerticalDivider(color: fin.border, width: 24),
                Expanded(
                  child: _FlowFigure(label: 'Expense', value: money(overview.month.expense)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "↑ 12,5% dari bulan lalu": arrow + sign + color, never color alone.
class _ChangeLine extends StatelessWidget {
  const _ChangeLine({required this.change});
  final double change;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final up = change >= 0;
    final color = change.abs() < 0.05 ? fin.muted : (up ? fin.positive : fin.negative);
    return Row(
      children: [
        Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: color),
        const SizedBox(width: 2),
        Text(
          '${formatChange(change)} ',
          style: context.text.labelMedium!.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
        Flexible(
          child: Text(
            'dari bulan lalu',
            style: context.text.labelMedium!.copyWith(color: fin.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _FlowFigure extends StatelessWidget {
  const _FlowFigure({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: context.text.bodySmall),
      const SizedBox(height: 2),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          style: context.text.titleSmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    ],
  );
}

/// Compact Available to Spend row; tap explains the formula (03 §4).
class _AvailableToSpend extends ConsumerWidget {
  const _AvailableToSpend({required this.overview});
  final HomeOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final value = overview.available.value;
    // Follows the Home eye toggle: ATS is derived from the balance it hides.
    final hidden = ref.watch(hideBalanceProvider);
    final shown = hidden ? 'Rp ••••••' : formatRupiah(value);
    // Large font scales: the amount moves under the label instead of squeezing it ("Availabl/e to").
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 13;
    final amount = Text(
      shown,
      maxLines: 1,
      style: context.text.titleMedium!.copyWith(
        color: !hidden && value < 0 ? fin.negative : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final label = Row(
      children: [
        Flexible(child: Text('Available to Spend', style: context.text.bodyMedium, maxLines: 2)),
        const SizedBox(width: 4),
        Icon(Icons.info_outline, size: 14, color: fin.muted),
      ],
    );
    return Semantics(
      button: true,
      label: hidden ? 'Available to Spend disembunyikan. Ketuk untuk rincian.' : 'Available to Spend $shown. Ketuk untuk rincian.',
      excludeSemantics: true,
      child: FinCard(
        onTap: () => showAvailableBreakdownSheet(context, overview.available),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: fin.accentSoft, borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.savings_outlined, size: 20, color: fin.accentText),
            ),
            const SizedBox(width: 12),
            if (stacked)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label,
                    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: amount),
                  ],
                ),
              )
            else ...[
              Expanded(child: label),
              const SizedBox(width: 8),
              amount,
            ],
          ],
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
                  // Large font scales shrink the label rather than cut it
                  // to "Tra…", which made Transaksi/Transfer ambiguous.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(label, style: context.text.labelMedium, maxLines: 1),
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

/// Per-account balances (06-ux §9 "account summary").
class _AccountsStrip extends ConsumerWidget {
  const _AccountsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final hidden = ref.watch(hideBalanceProvider);
    return AsyncView(
      value: ref.watch(homeOverviewProvider),
      builder: (o) => o.balances.isEmpty
          ? const SizedBox.shrink()
          : SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: o.balances.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final b = o.balances[i];
                  final currency = Currency.fromCode(b.account.currency);
                  return SizedBox(
                    width: 160,
                    child: FinCard(
                      onTap: () => context.push(Routes.accounts),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                                // Large balances shrink instead of hiding digits ("Rp 11.808.6…").
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: hidden
                                      ? Text('${currency.symbol} ••••', style: context.text.bodySmall!.copyWith(color: fin.text))
                                      : AmountText(
                                          b.balance,
                                          currency: currency,
                                          alertNegative: true,
                                          style: context.text.bodySmall!.copyWith(color: fin.text),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
