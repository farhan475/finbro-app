import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_service.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../transactions/ledger_paths.dart';
import '../data/account_repository.dart';

IconData accountIcon(Account a) => a.icon != null ? iconFor(a.icon) : accountTypeIcon(a.type);

/// `/accounts`: calculated balance per account (03 §2) and Total Balance of
/// active accounts (03 §3); archived accounts listed separately on demand.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(accountBalancesProvider(true));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        actions: [
          IconButton(
            tooltip: 'Tambah account',
            icon: const Icon(Icons.add),
            onPressed: () => context.push(LedgerPaths.accountNew),
          ),
        ],
      ),
      body: AsyncView<List<AccountBalance>>(
        value: async,
        builder: (all) {
          if (all.isEmpty) {
            return Center(
              child: EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Belum ada account',
                message: 'Tambahkan tempat menyimpan uang: bank, e-wallet, atau cash.',
                actionLabel: 'Tambah account',
                onAction: () => context.push(LedgerPaths.accountNew),
              ),
            );
          }
          final active = [for (final b in all) if (b.account.isActive) b];
          final archived = [for (final b in all) if (!b.account.isActive) b];
          final total = active.fold<int>(0, (s, b) => s + b.balance);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              FinCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total Balance', style: context.text.labelMedium!.copyWith(color: context.fin.muted)),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: AmountText(total, style: context.text.displaySmall),
                    ),
                    const SizedBox(height: 4),
                    Text('${active.length} account aktif', style: context.text.bodySmall),
                  ],
                ),
              ),
              const SectionHeader('Account aktif'),
              if (active.isEmpty)
                Text('Semua account sudah diarsipkan.', style: context.text.bodySmall)
              else
                _AccountList(active),
              if (archived.isNotEmpty) ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Tampilkan account diarsipkan (${archived.length})', style: context.text.titleSmall),
                  subtitle: Text('Tidak dihitung ke Total Balance.', style: context.text.bodySmall),
                  value: _showArchived,
                  onChanged: (v) => setState(() => _showArchived = v),
                ),
                if (_showArchived) _AccountList(archived),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _AccountList extends StatelessWidget {
  const _AccountList(this.items);
  final List<AccountBalance> items;

  @override
  Widget build(BuildContext context) {
    return FinCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          for (final (i, b) in items.indexed) ...[
            if (i > 0) const Divider(),
            AccountRow(b),
          ],
        ],
      ),
    );
  }
}

class AccountRow extends StatelessWidget {
  const AccountRow(this.item, {super.key});
  final AccountBalance item;

  @override
  Widget build(BuildContext context) {
    final a = item.account;
    return InkWell(
      onTap: () => context.push(LedgerPaths.accountDetail(a.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            IconAvatar(accountIcon(a)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    a.isActive ? a.type.label : '${a.type.label} · Diarsipkan',
                    style: context.text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: AmountText(item.balance, alertNegative: true, style: context.text.titleSmall),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
