import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/goal_repository.dart';
import '../goal_paths.dart';

/// Create (`goalId == null`) or edit a goal (FR-GOA-001).
class GoalFormScreen extends ConsumerWidget {
  const GoalFormScreen({super.key, this.goalId, this.initialType});
  final String? goalId;
  final GoalType? initialType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = goalId;
    if (id == null) return _GoalForm(initialType: initialType ?? GoalType.savings);
    return ref.watch(goalProvider(id)).when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2))),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Edit tujuan')),
        body: Padding(padding: const EdgeInsets.all(24), child: Text('Terjadi kesalahan: $e')),
      ),
      data: (g) => g == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Edit tujuan')),
              body: const EmptyState(icon: Icons.flag_outlined, title: 'Tujuan tidak ditemukan'),
            )
          : _GoalForm(initialType: g.type, existing: g),
    );
  }
}

class _GoalForm extends ConsumerStatefulWidget {
  const _GoalForm({required this.initialType, this.existing});
  final GoalType initialType;
  final Goal? existing;

  @override
  ConsumerState<_GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends ConsumerState<_GoalForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.existing?.name ??
        (widget.initialType == GoalType.emergency ? GoalType.emergency.label : ''),
  );
  late final _target = TextEditingController(
    text: widget.existing == null ? '' : MoneyField.textFor(widget.existing!.targetAmount),
  );
  late final _monthly = TextEditingController(
    text: widget.existing?.monthlyTarget == null ? '' : MoneyField.textFor(widget.existing!.monthlyTarget!),
  );
  late GoalType _type = widget.initialType;
  late DateTime? _targetDate = widget.existing?.targetDate;
  late int _priority = widget.existing?.priority ?? 0;
  EmergencyStatus? _emergency;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)();
    ref.read(financeServiceProvider).emergencyStatus(now).then((s) {
      if (!mounted) return;
      setState(() => _emergency = s);
      if (!_isEdit && _type == GoalType.emergency && _target.text.isEmpty && s.targetAmount > 0) {
        _target.text = MoneyField.textFor(s.targetAmount);
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _monthly.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = dateOnly(ref.read(clockProvider)());
    final picked = await showDatePicker(
      context: context,
      initialDate: _targetDate ?? DateTime(today.year + 1, today.month, today.day),
      firstDate: _targetDate != null && _targetDate!.isBefore(today) ? _targetDate! : today,
      lastDate: DateTime(today.year + 50),
    );
    if (picked != null) setState(() => _targetDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(goalRepositoryProvider);
    final target = parseRupiah(_target.text)!;
    final monthly = parseRupiah(_monthly.text);
    try {
      if (_isEdit) {
        await repo.update(
          widget.existing!.id,
          name: _name.text,
          type: _type,
          targetAmount: target,
          targetDate: _targetDate,
          monthlyTarget: monthly,
          priority: _priority,
        );
        if (mounted) context.pop();
      } else {
        final id = await repo.create(
          name: _name.text,
          type: _type,
          targetAmount: target,
          targetDate: _targetDate,
          monthlyTarget: monthly,
          priority: _priority,
        );
        if (mounted) context.pushReplacement(GoalPaths.goalDetail(id));
      }
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    final suggestion = _emergency;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit tujuan' : 'Tambah Tujuan')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nama tujuan', hintText: 'Contoh: Laptop baru'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Nama wajib diisi' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<GoalType>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Jenis'),
              items: [
                for (final t in GoalType.values) DropdownMenuItem(value: t, child: Text(t.label)),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            if (_type == GoalType.emergency) ...[
              const SizedBox(height: 4),
              Text('Saldo semua tujuan Emergency Fund aktif menjadi Emergency Fund Balance.', style: muted),
            ],
            const SizedBox(height: 12),
            MoneyField(controller: _target, label: 'Target dana', large: true),
            if (_type == GoalType.emergency && suggestion != null && suggestion.targetAmount > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _target.text = MoneyField.textFor(suggestion.targetAmount)),
                  style: TextButton.styleFrom(foregroundColor: fin.text),
                  child: Text(
                    'Pakai saran ${formatRupiah(suggestion.targetAmount)} '
                    '(essential ${suggestion.lookbackMonths} bln × ${suggestion.targetMonths} bln)',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: const Text('Tanggal target (opsional)'),
              subtitle: Text(_targetDate == null ? 'Tidak ditentukan' : formatDay(_targetDate!)),
              onTap: _pickDate,
              trailing: _targetDate == null
                  ? null
                  : IconButton(
                      tooltip: 'Hapus tanggal',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _targetDate = null),
                    ),
            ),
            const SizedBox(height: 8),
            MoneyField(
              controller: _monthly,
              label: 'Target kontribusi bulanan (opsional)',
              validator: (v) => v != null && v <= 0 ? 'Masukkan nominal atau kosongkan' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _priority,
              decoration: const InputDecoration(labelText: 'Prioritas'),
              items: [
                for (final e in goalPriorityLabels.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _priority = v ?? _priority),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _saving ? null : _save, child: const Text('Simpan')),
          ],
        ),
      ),
    );
  }
}
