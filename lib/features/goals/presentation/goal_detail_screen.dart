import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/goal_repository.dart';
import '../goal_paths.dart';
import 'goal_widgets.dart';

enum _GoalMenu { edit, archive, restore, delete }

/// Goal detail: progress, movement actions and history (FR-GOA-002/003).
class GoalDetailScreen extends ConsumerWidget {
  const GoalDetailScreen({super.key, required this.goalId});
  final String goalId;

  Future<void> _onMenu(BuildContext context, WidgetRef ref, Goal goal, _GoalMenu action) async {
    final repo = ref.read(goalRepositoryProvider);
    switch (action) {
      case _GoalMenu.edit:
        await context.push(GoalPaths.editGoal(goal.id));
      case _GoalMenu.archive:
        final ok = await confirmDialog(
          context,
          title: 'Arsipkan tujuan?',
          message: 'Tujuan tidak lagi dihitung sebagai reserved money atau Emergency Fund. '
              'Riwayat tetap tersimpan dan dapat diaktifkan kembali.',
          confirmLabel: 'Arsipkan',
        );
        if (ok) await repo.setActive(goal.id, false);
      case _GoalMenu.restore:
        final ok = await confirmDialog(
          context,
          title: 'Aktifkan kembali?',
          message: 'Saldo tujuan akan kembali dihitung sebagai reserved money.',
          confirmLabel: 'Aktifkan',
        );
        if (ok) await repo.setActive(goal.id, true);
      case _GoalMenu.delete:
        final ok = await confirmDialog(
          context,
          title: 'Hapus tujuan?',
          message: 'Tujuan "${goal.name}" dan seluruh riwayatnya akan dihapus permanen. '
              'Transaksi dan saldo account tidak berubah.',
          confirmLabel: 'Hapus',
          destructive: true,
        );
        if (!ok) return;
        await repo.delete(goal.id);
        if (context.mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(goalProvider(goalId));
    return goal.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2))),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Padding(padding: const EdgeInsets.all(24), child: Text('Terjadi kesalahan: $e')),
      ),
      data: (g) {
        if (g == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.flag_outlined,
              title: 'Tujuan tidak ditemukan',
              message: 'Tujuan ini mungkin sudah dihapus.',
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              PopupMenuButton<_GoalMenu>(
                onSelected: (a) => _onMenu(context, ref, g, a),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: _GoalMenu.edit, child: Text('Edit')),
                  if (g.isActive)
                    const PopupMenuItem(value: _GoalMenu.archive, child: Text('Arsipkan'))
                  else
                    const PopupMenuItem(value: _GoalMenu.restore, child: Text('Aktifkan kembali')),
                  const PopupMenuItem(value: _GoalMenu.delete, child: Text('Hapus')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _GoalHeader(goal: g, now: ref.watch(clockProvider)()),
              const SizedBox(height: 12),
              if (g.isActive)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => showMovementSheet(context, g, MovementType.contribution),
                        child: const Text('Tambah dana', maxLines: 1),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: g.currentAmount > 0
                            ? () => showMovementSheet(context, g, MovementType.withdrawal)
                            : null,
                        child: const Text('Tarik dana', maxLines: 1),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => showMovementSheet(context, g, MovementType.adjustment),
                        child: const FittedBox(child: Text('Penyesuaian')),
                      ),
                    ),
                  ],
                )
              else
                Text(
                  'Tujuan ini diarsipkan. Aktifkan kembali untuk mencatat dana.',
                  style: context.text.bodySmall!.copyWith(color: context.fin.muted),
                ),
              const SizedBox(height: 16),
              const SectionHeader('Riwayat'),
              _MovementHistory(goalId: g.id),
            ],
          ),
        );
      },
    );
  }
}

class _GoalHeader extends StatelessWidget {
  const _GoalHeader({required this.goal, required this.now});
  final Goal goal;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    final progress = goalProgress(goal.currentAmount, goal.targetAmount);
    final schedule = goalScheduleText(goal, now);
    return FinCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconAvatar(goalTypeIcon(goal.type)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${goal.type.label} · Prioritas ${goalPriorityLabels[goal.priority] ?? '-'}'
                  '${goal.isActive ? '' : ' · Diarsipkan'}',
                  style: muted,
                  maxLines: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: AmountText(goal.currentAmount, style: context.text.headlineSmall),
          ),
          Text('dari target ${formatRupiah(goal.targetAmount)}', style: muted),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: FinProgressBar(percent: progress)),
              const SizedBox(width: 12),
              Text(formatPercent(progress), style: context.text.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            goal.currentAmount >= goal.targetAmount
                ? 'Target tercapai'
                : 'Kurang ${formatRupiah(goal.targetAmount - goal.currentAmount)}',
            style: context.text.bodySmall,
          ),
          if (schedule != null) Text(schedule, style: muted),
          if (goal.monthlyTarget != null)
            Text('Target kontribusi ${formatRupiah(goal.monthlyTarget!)}/bulan', style: muted),
          const SizedBox(height: 8),
          Text('Dana tetap berada di account Anda; FinBro mencatat alokasinya.', style: muted),
        ],
      ),
    );
  }
}

IconData _movementIcon(MovementType t) => switch (t) {
  MovementType.contribution => Icons.add,
  MovementType.withdrawal => Icons.remove,
  MovementType.adjustment => Icons.tune,
};

class _MovementHistory extends ConsumerWidget {
  const _MovementHistory({required this.goalId});
  final String goalId;

  Future<void> _delete(BuildContext context, WidgetRef ref, GoalMovement m) async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus catatan?',
      message: '${m.movementType.label} ${formatRupiah(m.amount.abs())} pada '
          '${formatDay(m.movementAt)} akan dihapus dan saldo tujuan dihitung ulang.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(goalRepositoryProvider).deleteMovement(m.id);
    } on LedgerValidationException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = context.text.bodySmall!.copyWith(color: context.fin.muted);
    return AsyncView(
      value: ref.watch(goalMovementsProvider(goalId)),
      builder: (List<GoalMovement> items) => items.isEmpty
          ? const EmptyState(
              icon: Icons.history,
              title: 'Belum ada riwayat',
              message: 'Catat dana yang Anda sisihkan untuk tujuan ini.',
            )
          : Column(
              children: [
                for (final m in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: IconAvatar(_movementIcon(m.movementType)),
                    title: Text(m.movementType.label),
                    subtitle: Text(
                      [formatDay(m.movementAt), ?m.note].join(' · '),
                      style: muted,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AmountText(m.amount, signed: true),
                        IconButton(
                          tooltip: 'Hapus',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _delete(context, ref, m),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Bottom sheet to record a contribution, withdrawal or adjustment.
Future<void> showMovementSheet(BuildContext context, Goal goal, MovementType type) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _MovementSheet(goal: goal, type: type),
    );

class _MovementSheet extends ConsumerStatefulWidget {
  const _MovementSheet({required this.goal, required this.type});
  final Goal goal;
  final MovementType type;

  @override
  ConsumerState<_MovementSheet> createState() => _MovementSheetState();
}

class _MovementSheetState extends ConsumerState<_MovementSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  late DateTime _date = dateOnly(ref.read(clockProvider)());
  bool _decrease = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = dateOnly(ref.read(clockProvider)());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final now = ref.read(clockProvider)();
    final at = isSameDay(_date, now) ? now : DateTime(_date.year, _date.month, _date.day, 12);
    try {
      await ref.read(goalRepositoryProvider).addMovement(
        goalId: widget.goal.id,
        type: widget.type,
        amount: parseRupiah(_amount.text)!,
        decrease: _decrease,
        at: at,
        note: _note.text,
      );
      if (mounted) Navigator.of(context).pop();
    } on LedgerValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    final isAdjustment = widget.type == MovementType.adjustment;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.type.label, style: context.text.titleMedium),
            Text(
              '${widget.goal.name} · saldo ${formatRupiah(widget.goal.currentAmount)}',
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            if (isAdjustment) ...[
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Tambah')),
                  ButtonSegment(value: true, label: Text('Kurangi')),
                ],
                selected: {_decrease},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _decrease = s.first),
              ),
              const SizedBox(height: 4),
              Text('Untuk mengoreksi saldo tujuan tanpa dihitung sebagai tabungan.', style: muted),
              const SizedBox(height: 12),
            ],
            MoneyField(controller: _amount, autofocus: true, large: true),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: const Text('Tanggal'),
              trailing: Text(formatDay(_date)),
              onTap: _pickDate,
            ),
            TextField(
              controller: _note,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Catatan (opsional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(_error!, style: context.text.bodySmall!.copyWith(color: fin.negative)),
            ],
            const SizedBox(height: 12),
            FilledButton(onPressed: _saving ? null : _save, child: const Text('Simpan')),
          ],
        ),
      ),
    );
  }
}
