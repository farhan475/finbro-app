import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';
import '../../core/formatting/dates.dart';
import '../providers/lookups.dart';
import 'category_icon.dart';
import 'fin_widgets.dart';

/// One ledger row: icon, title (category or "Transfer"), subtitle
/// (account · date), signed amount. Tapping opens the detail/edit screen.
class TransactionTile extends ConsumerWidget {
  const TransactionTile(this.tx, {super.key, this.showDate = true, this.onTap});

  final LedgerTransaction tx;
  final bool showDate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoryMapProvider);
    final accounts = ref.watch(accountMapProvider);
    final fin = context.fin;

    final isTransfer = tx.type == TransactionType.transfer;
    final category = categories[tx.categoryId];
    final title = isTransfer ? 'Transfer' : (category?.name ?? 'Tanpa kategori');
    final from = accounts[tx.accountId]?.name ?? '-';
    final account = isTransfer ? '$from → ${accounts[tx.transferToAccountId]?.name ?? '-'}' : from;
    final note = tx.note;
    final subtitle = [
      ?note,
      account,
      if (showDate) formatDayShort(tx.transactionAt),
    ].join(' · ');

    final signed = switch (tx.type) {
      TransactionType.income => tx.amount,
      TransactionType.expense => -tx.amount,
      TransactionType.transfer => tx.amount,
    };

    return InkWell(
      onTap: onTap ?? () => context.push(Routes.transactionDetail(tx.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            IconAvatar(isTransfer ? Icons.swap_horiz : iconFor(category?.icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isTransfer)
              AmountText(tx.amount, style: context.text.titleSmall!.copyWith(color: fin.muted))
            else
              AmountText(signed, colorize: tx.type == TransactionType.income, signed: true, style: context.text.titleSmall),
          ],
        ),
      ),
    );
  }
}
