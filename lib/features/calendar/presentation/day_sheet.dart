import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../../shared/widgets/transaction_tile.dart';
import '../../recurring/presentation/instance_widgets.dart';
import '../data/calendar_repository.dart';
import '../domain/daily_check_service.dart';
import 'calendar_widgets.dart';

Future<void> showCalendarDaySheet(BuildContext context, DateTime day) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 0.92,
    builder: (context, controller) => _DaySheet(day: dateOnly(day), controller: controller),
  ),
);

class _DaySheet extends ConsumerStatefulWidget {
  const _DaySheet({required this.day, required this.controller});
  final DateTime day;
  final ScrollController controller;

  @override
  ConsumerState<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<_DaySheet> {
  bool _busy = false;

  Future<void> _markNoActivity() async {
    setState(() => _busy = true);
    await ref.read(dailyCheckServiceProvider).markNoActivity(widget.day);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, 'Ditandai: tidak ada aktivitas pada ${formatDayShort(widget.day)}');
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final day = widget.day;
    final today = dateOnly(ref.watch(clockProvider)());
    final future = day.isAfter(today);
    final info = ref.watch(calendarMonthProvider(monthStart(day))).value?.day(day);
    final txs = ref.watch(dayTransactionsProvider(day));
    final status = info?.status ?? ActivityStatus.unknown;
    final instances = info?.instances ?? const [];

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text(formatWeekday(day), style: context.text.titleLarge),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(width: 12, child: Center(child: ActivityMarker(status))),
            const SizedBox(width: 8),
            Text(activityLabel(status, future: future), style: context.text.bodyMedium?.copyWith(color: fin.muted)),
          ],
        ),
        const SizedBox(height: 8),
        const SectionHeader('Transaksi'),
        AsyncView(
          value: txs,
          builder: (list) => list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Belum ada transaksi tercatat.', style: context.text.bodySmall),
                )
              : Column(children: [for (final t in list) TransactionTile(t, showDate: false)]),
        ),
        if (instances.isNotEmpty) ...[
          const SizedBox(height: 8),
          const SectionHeader('Terjadwal'),
          for (final v in instances) InstanceTile(v, expanded: true),
        ],
        const SizedBox(height: 16),
        if (!future && status == ActivityStatus.unknown) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _markNoActivity,
            icon: const Icon(Icons.remove),
            label: const Text('Tidak ada transaksi hari ini'),
          ),
          const SizedBox(height: 8),
        ],
        FilledButton.icon(
          onPressed: () {
            final router = GoRouter.of(context);
            Navigator.of(context).pop();
            router.push(Routes.transactionNew());
          },
          icon: const Icon(Icons.add),
          label: const Text('Tambah transaksi'),
        ),
      ],
    );
  }
}
