import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/recurring_repository.dart';
import '../domain/recurring_engine.dart';

String instanceStatusLabel(RecurringStatus s) => switch (s) {
  RecurringStatus.scheduled => 'Terjadwal',
  RecurringStatus.pending => 'Menunggu konfirmasi',
  RecurringStatus.confirmed => 'Dikonfirmasi',
  RecurringStatus.skipped => 'Dilewati',
  RecurringStatus.cancelled => 'Dibatalkan',
};

/// Small bordered label (state is always text, never color only).
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final c = color ?? fin.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color ?? fin.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: context.text.labelSmall?.copyWith(color: c), maxLines: 1),
    );
  }
}

/// Calendar-style date badge: day number over short month.
class DueDateBadge extends StatelessWidget {
  const DueDateBadge(this.date, {super.key});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: fin.surface2, borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${date.day}', style: context.text.titleSmall?.copyWith(height: 1.1)),
          Text(formatMonthShort(date), style: context.text.labelSmall?.copyWith(color: fin.muted, height: 1.1)),
        ],
      ),
    );
  }
}

/// One recurring instance. Open instances get actions: inline buttons when
/// [expanded], otherwise an overflow menu.
class InstanceTile extends ConsumerWidget {
  const InstanceTile(this.view, {super.key, this.expanded = false, this.showRuleName = true, this.onTap});

  final InstanceView view;
  final bool expanded;
  final bool showRuleName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final inst = view.instance;
    final rule = view.rule;
    final account = ref.watch(accountMapProvider)[rule.accountId]?.name ?? '-';
    final open = inst.status.isOpen;
    final today = dateOnly(ref.watch(clockProvider)());
    final overdue = inst.status == RecurringStatus.pending && inst.dueDate.isBefore(today);
    final isIncome = rule.type == TransactionType.income;
    final subtitle = [
      if (showRuleName) (isIncome ? 'Income' : 'Expense') else formatDay(inst.dueDate),
      account,
    ].join(' · ');

    final txId = inst.transactionId;
    final VoidCallback? tap =
        onTap ??
        (txId != null
            ? () => context.push(Routes.transactionDetail(txId))
            : showRuleName
            ? () => context.push('${Routes.recurring}/${rule.id}')
            : null);

    return InkWell(
      onTap: tap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DueDateBadge(inst.dueDate),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isIncome ? Icons.arrow_upward : Icons.arrow_downward,
                            size: 14,
                            color: isIncome ? fin.positive : fin.negative,
                            semanticLabel: isIncome ? 'Income' : 'Expense',
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              showRuleName ? rule.name : instanceStatusLabel(inst.status),
                              style: context.text.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AmountText(view.signedAmount, colorize: isIncome, signed: true, style: context.text.titleSmall),
                    const SizedBox(height: 4),
                    if (showRuleName || overdue)
                      StatusPill(
                        overdue ? 'Terlambat' : instanceStatusLabel(inst.status),
                        color: overdue ? fin.warning : null,
                      ),
                  ],
                ),
                if (open && !expanded) _InstanceMenu(view),
              ],
            ),
            if (open && expanded)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 56),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => confirmInstanceFlow(context, view),
                      child: const Text('Konfirmasi'),
                    ),
                    OutlinedButton(
                      onPressed: () => skipInstanceFlow(context, ref, view),
                      child: const Text('Lewati'),
                    ),
                    TextButton(
                      onPressed: () => cancelInstanceFlow(context, ref, view),
                      style: TextButton.styleFrom(foregroundColor: fin.muted),
                      child: const Text('Batalkan'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Action { confirm, skip, cancel }

class _InstanceMenu extends ConsumerWidget {
  const _InstanceMenu(this.view);
  final InstanceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<_Action>(
    tooltip: 'Aksi',
    icon: const Icon(Icons.more_vert, size: 20),
    onSelected: (a) => switch (a) {
      _Action.confirm => confirmInstanceFlow(context, view),
      _Action.skip => skipInstanceFlow(context, ref, view),
      _Action.cancel => cancelInstanceFlow(context, ref, view),
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: _Action.confirm, child: Text('Konfirmasi')),
      PopupMenuItem(value: _Action.skip, child: Text('Lewati')),
      PopupMenuItem(value: _Action.cancel, child: Text('Batalkan')),
    ],
  );
}

/// Opens the confirm sheet (adjust amount/date/account) and posts exactly one
/// transaction.
Future<void> confirmInstanceFlow(BuildContext context, InstanceView view) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ConfirmInstanceSheet(view: view),
  );
  if (ok == true && context.mounted) showSnack(context, '${view.rule.name} dikonfirmasi');
}

Future<void> skipInstanceFlow(BuildContext context, WidgetRef ref, InstanceView view) async {
  final ok = await ref.read(recurringEngineProvider).skip(view.instance.id);
  if (context.mounted) {
    showSnack(context, ok ? '${view.rule.name} dilewati, tidak ada transaksi dicatat' : 'Jadwal ini sudah ditutup');
  }
}

Future<void> cancelInstanceFlow(BuildContext context, WidgetRef ref, InstanceView view) async {
  final sure = await confirmDialog(
    context,
    title: 'Batalkan jadwal?',
    message: '${view.rule.name} tanggal ${formatDay(view.instance.dueDate)} dibatalkan dan tidak akan diingatkan lagi.',
    confirmLabel: 'Batalkan jadwal',
    destructive: true,
  );
  if (!sure) return;
  final ok = await ref.read(recurringEngineProvider).cancel(view.instance.id);
  if (context.mounted) showSnack(context, ok ? 'Jadwal dibatalkan' : 'Jadwal ini sudah ditutup');
}

class ConfirmInstanceSheet extends ConsumerStatefulWidget {
  const ConfirmInstanceSheet({super.key, required this.view});
  final InstanceView view;

  @override
  ConsumerState<ConfirmInstanceSheet> createState() => _ConfirmInstanceSheetState();
}

class _ConfirmInstanceSheetState extends ConsumerState<ConfirmInstanceSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late DateTime _date;
  String? _accountId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final inst = widget.view.instance;
    _amount = TextEditingController(text: MoneyField.textFor(inst.amount))..addListener(() => setState(() {}));
    final today = dateOnly(ref.read(clockProvider)());
    _date = inst.dueDate.isAfter(today) ? today : inst.dueDate;
    _accountId = widget.view.rule.accountId;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = dateOnly(ref.read(clockProvider)());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(today.year - 5),
      lastDate: today,
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final id = await ref.read(recurringEngineProvider).confirm(
        widget.view.instance.id,
        amount: parseRupiah(_amount.text),
        date: _date,
        accountId: _accountId,
      );
      if (!mounted) return;
      if (id == null) showSnack(context, 'Jadwal ini sudah dikonfirmasi atau ditutup');
      Navigator.of(context).pop(id != null);
    } on LedgerValidationException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rule = widget.view.rule;
    final accounts = ref.watch(activeAccountsProvider);
    final hasAccount = accounts.any((a) => a.id == _accountId);
    final isIncome = rule.type == TransactionType.income;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Konfirmasi ${rule.name}', style: context.text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              '${isIncome ? 'Income' : 'Expense'} · jadwal ${formatDay(widget.view.instance.dueDate)}. '
              'Satu transaksi akan dicatat.',
              style: context.text.bodySmall,
            ),
            const SizedBox(height: 16),
            MoneyField(controller: _amount, large: true),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(AppRadius.input),
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Tanggal', suffixIcon: Icon(Icons.calendar_today_outlined)),
                child: Text(formatDay(_date)),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: hasAccount ? _accountId : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Account'),
              items: [
                for (final a in accounts)
                  DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _accountId = v),
              validator: (v) => v == null ? 'Pilih account' : null,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Konfirmasi'),
            ),
            if (_amount.text.isNotEmpty && parseRupiah(_amount.text) != widget.view.instance.amount)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Jadwal: ${formatRupiah(widget.view.instance.amount)}',
                  style: context.text.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
