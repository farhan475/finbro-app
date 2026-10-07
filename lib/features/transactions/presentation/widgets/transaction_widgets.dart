import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/finance/finance_service.dart';
import '../../../../core/formatting/dates.dart';
import '../../../../core/formatting/money.dart';
import '../../../../shared/providers/lookups.dart';
import '../../../../shared/widgets/transaction_tile.dart';
import '../../domain/day_groups.dart';

/// Live row → rupiah converter for [groupByDay] day totals.
int Function(LedgerTransaction) watchIdrConverter(WidgetRef ref) =>
    idrConverter(ref.watch(accountMapProvider), ref.watch(exchangeRateMapProvider).value ?? const {});

String sourceLabel(SourceType s) => switch (s) {
  SourceType.manual => 'Manual',
    SourceType.receiptOcr => 'Scan struk',
    SourceType.screenshot => 'Screenshot',
    SourceType.recurring => 'Transaksi berulang',
    SourceType.statementImport => 'Impor mutasi',
};

/// Label for non-confirmed rows; null for confirmed.
String? statusLabel(TransactionStatus s) => switch (s) {
  TransactionStatus.confirmed => null,
  TransactionStatus.draft => 'Draft',
  TransactionStatus.voided => 'Void',
};

/// Small outlined text badge (state is always written, never color only).
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.fin.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: context.text.labelSmall!.copyWith(color: c)),
    );
  }
}

/// Day header with confirmed income/expense totals, followed by its rows.
/// Returned flat so callers can feed a lazy `ListView.builder`.
List<Widget> dayGroupWidgets(BuildContext context, List<DayGroup> groups) {
  final out = <Widget>[];
  for (final g in groups) {
    out.add(DayHeader(g));
    for (final t in g.items) {
      out.add(LedgerRow(t, key: ValueKey(t.id)));
    }
  }
  return out;
}

class DayHeader extends StatelessWidget {
  const DayHeader(this.group, {super.key});
  final DayGroup group;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final today = dateOnly(DateTime.now());
    final label = group.day == today
        ? 'Hari ini'
        : group.day == today.subtract(const Duration(days: 1))
        ? 'Kemarin'
        : formatWeekday(group.day);
    final totals = [
      if (group.income > 0) formatRupiah(group.income, signed: true),
      if (group.expense > 0) formatRupiah(-group.expense),
    ].join('  ');
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              group.day.year == today.year ? label : '$label ${group.day.year}',
              style: context.text.labelMedium!.copyWith(color: fin.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (totals.isNotEmpty)
            Flexible(
              fit: FlexFit.tight,
              child: Text(
                totals,
                style: context.text.labelMedium!.copyWith(
                  color: fin.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
            ),
        ],
      ),
    );
  }
}

/// [TransactionTile] plus a status badge for drafts/voided rows, which are
/// listed but never counted in balances or totals.
class LedgerRow extends StatelessWidget {
  const LedgerRow(this.tx, {super.key});
  final LedgerTransaction tx;

  @override
  Widget build(BuildContext context) {
    final label = statusLabel(tx.status);
    if (label == null) return TransactionTile(tx);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TransactionTile(tx),
        Padding(
          padding: const EdgeInsets.only(left: 52, bottom: 8),
          child: Row(
            children: [
              StatusBadge(label, color: context.fin.warning),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Belum dihitung ke saldo',
                  style: context.text.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

bool isImageMime(String mime) => mime.startsWith('image/');

/// Square preview of a local attachment file.
class AttachmentThumb extends StatelessWidget {
  const AttachmentThumb({super.key, required this.path, required this.mimeType, this.onTap, this.onRemove, this.size = 84});

  final String path;
  final String mimeType;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final placeholder = Container(
      color: fin.surface2,
      alignment: Alignment.center,
      child: Icon(isImageMime(mimeType) ? Icons.broken_image_outlined : Icons.description_outlined, color: fin.muted),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Material(
                color: fin.surface2,
                child: InkWell(
                  onTap: onTap,
                  child: isImageMime(mimeType)
                      ? Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          cacheWidth: (size * 3).round(),
                          errorBuilder: (_, _, _) => placeholder,
                        )
                      : placeholder,
                ),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 2,
              right: 2,
              child: Material(
                color: fin.surface,
                shape: CircleBorder(side: BorderSide(color: fin.border)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onRemove,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16, color: fin.text, semanticLabel: 'Hapus lampiran'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-screen zoomable image viewer.
Future<void> showAttachmentViewer(BuildContext context, String path) {
  return showDialog<void>(
    context: context,
    useSafeArea: false,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: context.fin.background,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Text(
                    'File lampiran tidak ditemukan.',
                    style: TextStyle(color: context.fin.text),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: 'Tutup',
                icon: Icon(Icons.close, color: context.fin.text),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
