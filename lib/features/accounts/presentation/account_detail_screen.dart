import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../transactions/data/transaction_query_repository.dart';
import '../../transactions/domain/day_groups.dart';
import '../../transactions/domain/transaction_filter.dart';
import '../../transactions/ledger_paths.dart';
import '../../transactions/presentation/transaction_pager.dart';
import '../../transactions/presentation/widgets/transaction_widgets.dart';
import '../data/account_repository.dart';
import '../domain/reconciliation.dart';
import 'accounts_screen.dart';

/// `/accounts/:id`: balance, reconciliation (FR-ACC-002), archive/delete
/// (FR-ACC-003) and the account's transactions (incl. transfers in/out).
class AccountDetailScreen extends ConsumerStatefulWidget {
  const AccountDetailScreen({super.key, required this.accountId});
  final String accountId;

  @override
  ConsumerState<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

enum _Action { edit, archive, unarchive, delete }

class _AccountDetailScreenState extends ConsumerState<AccountDetailScreen> {
  final _actual = TextEditingController();
  late final _pager = TransactionPager(() {
    if (mounted) setState(() {});
  });
  bool _busy = false;

  @override
  void dispose() {
    _actual.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AccountException catch (e) {
      if (mounted) showSnack(context, e.message);
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error(failure, e, s);
      if (mounted) showSnack(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onAction(_Action a, Account account) async {
    final repo = ref.read(accountRepositoryProvider);
    switch (a) {
      case _Action.edit:
        context.push(LedgerPaths.accountEdit(account.id));
      case _Action.archive:
        final usage = await repo.usage(account.id);
        if (!mounted) return;
        final ok = await confirmDialog(
          context,
          title: 'Arsipkan ${account.name}?',
          message: 'Riwayat transaksi tetap tersimpan, tetapi account ini tidak menerima transaksi baru '
              'dan tidak dihitung ke Total Balance.'
              '${usage.recurringRules > 0 ? ' ${usage.recurringRules} transaksi berulang memakai account ini dan tidak bisa diposting sampai dipindah.' : ''}',
          confirmLabel: 'Arsipkan',
          destructive: true,
        );
        if (!ok) return;
        await _guard(() async {
          await repo.archive(account.id);
          if (mounted) showSnack(context, 'Account diarsipkan.');
        }, 'Gagal mengarsipkan account.');
      case _Action.unarchive:
        await _guard(() async {
          await repo.unarchive(account.id);
          if (mounted) showSnack(context, 'Account aktif kembali.');
        }, 'Gagal mengaktifkan account.');
      case _Action.delete:
        final usage = await repo.usage(account.id);
        if (!mounted) return;
        if (!usage.canDelete) {
          showSnack(
            context,
            usage.transactions > 0
                ? 'Account punya ${usage.transactions} transaksi dan tidak bisa dihapus. Arsipkan saja.'
                : 'Account dipakai transaksi berulang dan tidak bisa dihapus.',
          );
          return;
        }
        final ok = await confirmDialog(
          context,
          title: 'Hapus ${account.name}?',
          message: 'Account ini belum punya transaksi dan akan dihapus permanen.',
          confirmLabel: 'Hapus',
          destructive: true,
        );
        if (!ok) return;
        await _guard(() async {
          await repo.delete(account.id);
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          if (context.canPop()) {
            context.pop();
          } else {
            context.go(Routes.accounts);
          }
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Account dihapus.')));
        }, 'Gagal menghapus account.');
    }
  }

  Future<void> _postAdjustment(Account account, Reconciliation r) async {
    final draft = r.adjustment(account.id, ref.read(clockProvider)());
    if (draft == null) return;
    final kind = draft.type == TransactionType.income ? 'income (Other Income)' : 'expense (Other)';
    final ok = await confirmDialog(
      context,
      title: 'Buat transaksi penyesuaian?',
      message: 'FinBro akan mencatat $kind sebesar ${formatRupiah(draft.amount)} dengan catatan '
          '"$reconciliationNote" sehingga saldo ${account.name} menjadi ${formatRupiah(r.actual)}.',
      confirmLabel: 'Buat',
    );
    if (!ok) return;
    await _guard(() async {
      await ref.read(ledgerServiceProvider).create(draft);
      if (!mounted) return;
      _actual.clear();
      showSnack(context, 'Penyesuaian saldo tercatat.');
    }, 'Gagal membuat transaksi penyesuaian.');
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountByIdProvider(widget.accountId));
    final account = accountAsync.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(account?.name ?? 'Account', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (account != null)
            PopupMenuButton<_Action>(
              enabled: !_busy,
              onSelected: (a) => _onAction(a, account),
              itemBuilder: (_) => [
                const PopupMenuItem(value: _Action.edit, child: Text('Edit')),
                if (account.isActive)
                  const PopupMenuItem(value: _Action.archive, child: Text('Arsipkan'))
                else
                  const PopupMenuItem(value: _Action.unarchive, child: Text('Aktifkan kembali')),
                const PopupMenuItem(value: _Action.delete, child: Text('Hapus')),
              ],
            ),
        ],
      ),
      body: AsyncView<Account?>(
        value: accountAsync,
        builder: (a) => a == null
            ? const Center(child: EmptyState(icon: Icons.search_off, title: 'Account tidak ditemukan'))
            : _body(context, a),
      ),
    );
  }

  Widget _body(BuildContext context, Account account) {
    final fin = context.fin;
    final balances = ref.watch(accountBalancesProvider(true)).value;
    final balance = balances?.where((b) => b.account.id == account.id).firstOrNull?.balance;
    final pageAsync = _pager.watch(ref, TransactionFilter(accountIds: {account.id}));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        FinCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconAvatar(accountIcon(account), size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(account.name, style: context.text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(account.type.label, style: context.text.bodySmall),
                      ],
                    ),
                  ),
                  if (!account.isActive) StatusBadge('Diarsipkan', color: fin.muted),
                ],
              ),
              const SizedBox(height: 16),
              Text('Calculated Balance', style: context.text.labelMedium!.copyWith(color: fin.muted)),
              const SizedBox(height: 2),
              if (balance == null)
                const SizedBox(height: 40, child: Center(child: LinearProgressIndicator()))
              else
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: AmountText(balance, alertNegative: true, style: context.text.displaySmall),
                ),
              const SizedBox(height: 4),
              Text('Saldo awal ${formatRupiah(account.openingBalance)}', style: context.text.bodySmall),
            ],
          ),
        ),
        if (!account.isActive) ...[
          const SizedBox(height: 12),
          FinCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Account diarsipkan: riwayat tetap ada, tetapi tidak bisa menerima transaksi baru.',
                    style: context.text.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _onAction(_Action.unarchive, account),
                  child: const Text('Aktifkan'),
                ),
              ],
            ),
          ),
        ],
        if (balance != null) ...[
          const SectionHeader('Rekonsiliasi'),
          _ReconciliationCard(
            controller: _actual,
            calculated: balance,
            canAdjust: account.isActive && !_busy,
            onAdjust: (r) => _postAdjustment(account, r),
          ),
        ],
        const SectionHeader('Transaksi'),
        if (!_pager.loaded)
          AsyncView<TransactionPage>(value: pageAsync, builder: (_) => const SizedBox.shrink())
        else if (_pager.rows.isEmpty)
          EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'Belum ada transaksi di account ini',
            actionLabel: account.isActive ? 'Tambah transaksi' : null,
            onAction: account.isActive ? () => context.push(LedgerPaths.transactionNewForAccount(account.id)) : null,
          )
        else ...[
          ...dayGroupWidgets(context, groupByDay(_pager.rows)),
          if (_pager.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton(
                onPressed: pageAsync.isLoading || _pager.loadingMore ? null : () => _pager.loadMore(ref),
                child: const Text('Muat lebih banyak'),
              ),
            ),
        ],
      ],
    );
  }
}

/// FR-ACC-002: actual vs calculated balance, variance, optional adjustment.
class _ReconciliationCard extends StatelessWidget {
  const _ReconciliationCard({
    required this.controller,
    required this.calculated,
    required this.canAdjust,
    required this.onAdjust,
  });

  final TextEditingController controller;
  final int calculated;
  final bool canAdjust;
  final ValueChanged<Reconciliation> onAdjust;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return FinCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Cocokkan dengan saldo sebenarnya di bank/e-wallet/dompet.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 12),
          MoneyField(controller: controller, label: 'Saldo aktual', allowZero: true, validator: (_) => null),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final actual = parseRupiah(controller.text);
              if (actual == null) return const SizedBox.shrink();
              final r = Reconciliation(calculated: calculated, actual: actual);
              final v = r.variance;
              final explanation = r.matches
                  ? 'Saldo sesuai catatan.'
                  : v > 0
                  ? 'Saldo aktual lebih besar dari catatan. Mungkin ada income yang belum dicatat.'
                  : 'Saldo aktual lebih kecil dari catatan. Mungkin ada expense yang belum dicatat.';
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Line('Calculated', AmountText(calculated, style: context.text.bodyMedium)),
                    _Line('Aktual', AmountText(actual, style: context.text.bodyMedium)),
                    _Line(
                      'Selisih',
                      AmountText(v, colorize: true, style: context.text.titleSmall),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      explanation,
                      style: context.text.bodySmall!.copyWith(color: r.matches ? fin.muted : fin.text),
                    ),
                    if (!r.matches) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: canAdjust ? () => onAdjust(r) : null,
                        child: const Text('Buat transaksi penyesuaian'),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label, style: context.text.bodySmall)),
        Flexible(child: Align(alignment: Alignment.centerRight, child: value)),
      ],
    ),
  );
}
