import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/transaction_query_repository.dart';
import '../ledger_paths.dart';
import 'widgets/transaction_widgets.dart';

/// `/transaction/:id`: all fields, attachments, Edit / Duplikat / Hapus and
/// Confirm for drafts.
class TransactionDetailScreen extends ConsumerStatefulWidget {
  const TransactionDetailScreen({super.key, required this.transactionId});

  final String transactionId;

  @override
  ConsumerState<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

enum _Action { duplicate, delete }

class _TransactionDetailScreenState extends ConsumerState<TransactionDetailScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error(failure, e, s);
      if (mounted) showSnack(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _duplicate() => _run(() async {
    final id = await ref.read(ledgerServiceProvider).duplicate(widget.transactionId);
    if (!mounted) return;
    showSnack(context, 'Transaksi diduplikasi dengan tanggal sekarang.');
    context.pushReplacement(Routes.transactionDetail(id));
  }, 'Gagal menduplikasi transaksi.');

  Currency _currencyOf(LedgerTransaction tx) =>
      Currency.fromCode(ref.read(accountMapProvider)[tx.accountId]?.currency ?? 'IDR');

  Future<void> _delete(LedgerTransaction tx) async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus transaksi?',
      message: 'Transaksi ${formatMoney(tx.amount, _currencyOf(tx))} beserta lampirannya akan dihapus permanen. '
          'Saldo account dihitung ulang.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await ref.read(ledgerServiceProvider).delete(tx.id);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.activity);
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Transaksi dihapus.')));
    }, 'Gagal menghapus transaksi.');
  }

  Future<void> _confirm() => _run(() async {
    await ref.read(ledgerServiceProvider).confirm(widget.transactionId);
    if (mounted) showSnack(context, 'Transaksi dikonfirmasi dan dihitung ke saldo.');
  }, 'Gagal mengonfirmasi transaksi.');

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(transactionByIdProvider(widget.transactionId));
    final tx = async.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detail transaksi'),
        actions: [
          if (tx != null) ...[
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : () => context.push(LedgerPaths.transactionEdit(tx.id)),
            ),
            PopupMenuButton<_Action>(
              enabled: !_busy,
              onSelected: (a) => switch (a) {
                _Action.duplicate => _duplicate(),
                _Action.delete => _delete(tx),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: _Action.duplicate, child: Text('Duplikat')),
                PopupMenuItem(value: _Action.delete, child: Text('Hapus')),
              ],
            ),
          ],
        ],
      ),
      body: AsyncView<LedgerTransaction?>(
        value: async,
        builder: (tx) => tx == null
            ? const Center(
                child: EmptyState(icon: Icons.search_off, title: 'Transaksi tidak ditemukan', message: 'Mungkin sudah dihapus.'),
              )
            : _body(context, tx),
      ),
    );
  }

  Widget _body(BuildContext context, LedgerTransaction tx) {
    final fin = context.fin;
    final categories = ref.watch(categoryMapProvider);
    final accounts = ref.watch(accountMapProvider);
    final attachments = ref.watch(transactionAttachmentsProvider(tx.id)).value ?? const <Attachment>[];

    final isTransfer = tx.type == TransactionType.transfer;
    final category = categories[tx.categoryId];
    final title = isTransfer ? 'Transfer' : (category?.name ?? 'Tanpa kategori');
    final signed = switch (tx.type) {
      TransactionType.income => tx.amount,
      TransactionType.expense => -tx.amount,
      TransactionType.transfer => tx.amount,
    };
    final currency = Currency.fromCode(accounts[tx.accountId]?.currency ?? 'IDR');
    final rates = ref.watch(exchangeRateMapProvider).value ?? const <String, double>{};
    String accountName(String? id) {
      final a = accounts[id];
      if (a == null) return '-';
      return a.isActive ? a.name : '${a.name} (arsip)';
    }

    final status = statusLabel(tx.status);
    final fields = <(String, String)>[
      if (isTransfer) ...[
        ('Dari account', accountName(tx.accountId)),
        ('Ke account', accountName(tx.transferToAccountId)),
      ] else ...[
        ('Kategori', category == null ? '-' : (category.isActive ? category.name : '${category.name} (nonaktif)')),
        ('Account', accountName(tx.accountId)),
      ],
      ('Tanggal', '${formatWeekday(tx.transactionAt)} ${tx.transactionAt.year}, ${formatTime(tx.transactionAt)}'),
      ('Catatan', tx.note ?? '-'),
      ('Sumber', sourceLabel(tx.sourceType)),
      ('Status', status ?? 'Confirmed'),
      ('Dibuat', '${formatDay(tx.createdAt)} ${formatTime(tx.createdAt)}'),
      if (tx.updatedAt != tx.createdAt) ('Diubah', '${formatDay(tx.updatedAt)} ${formatTime(tx.updatedAt)}'),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        FinCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconAvatar(isTransfer ? Icons.swap_horiz : iconFor(category?.icon), size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(tx.type.label, style: context.text.bodySmall),
                      ],
                    ),
                  ),
                  if (status != null) StatusBadge(status, color: fin.warning),
                ],
              ),
              const SizedBox(height: 16),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AmountText(
                  signed,
                  colorize: tx.type == TransactionType.income,
                  signed: !isTransfer,
                  currency: currency,
                  style: context.text.displaySmall,
                ),
              ),
              if (currency != Currency.idr)
                Text(
                  '${currency.code} · ≈ ${formatRupiah(toIdr(tx.amount, currency, rates[currency.code]))}',
                  style: context.text.bodySmall!.copyWith(color: fin.muted),
                ),
            ],
          ),
        ),
        if (tx.status == TransactionStatus.draft) ...[
          const SizedBox(height: 12),
          FinCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Draft belum dihitung ke saldo', style: context.text.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Periksa nominal, kategori dan account, lalu konfirmasi agar masuk ke saldo, budget dan laporan.',
                  style: context.text.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _busy ? null : _confirm, child: const Text('Konfirmasi')),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        FinCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              for (final (i, f) in fields.indexed) _Field(f.$1, f.$2, last: i == fields.length - 1),
            ],
          ),
        ),
        const SectionHeader('Lampiran'),
        if (attachments.isEmpty)
          Text('Tidak ada lampiran.', style: context.text.bodySmall)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in attachments)
                AttachmentThumb(
                  key: ValueKey(a.id),
                  path: a.localPath,
                  mimeType: a.mimeType,
                  size: 96,
                  onTap: isImageMime(a.mimeType) ? () => showAttachmentViewer(context, a.localPath) : null,
                ),
            ],
          ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _duplicate,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('Duplikat'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _delete(tx),
                style: OutlinedButton.styleFrom(foregroundColor: fin.negative),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Hapus'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.last = false});

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: context.fin.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: context.text.bodySmall)),
          Expanded(child: Text(value, style: context.text.bodyMedium)),
        ],
      ),
    );
  }
}
