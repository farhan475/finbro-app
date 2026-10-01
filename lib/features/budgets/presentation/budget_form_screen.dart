import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/budget_repository.dart';

/// Create (`budgetId == null`) or edit a monthly category budget.
class BudgetFormScreen extends ConsumerWidget {
  const BudgetFormScreen({super.key, this.budgetId, this.month});

  final String? budgetId;

  /// Month for a new budget; defaults to the current month.
  final DateTime? month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = budgetId;
    if (id == null) {
      final m = monthStart(month ?? ref.read(clockProvider)());
      return _BudgetForm(month: m);
    }
    final budget = ref.watch(budgetProvider(id));
    return budget.when(
      data: (b) => b == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Budget')),
              body: const EmptyState(
                icon: Icons.pie_chart_outline,
                title: 'Budget tidak ditemukan',
                message: 'Budget ini mungkin sudah dihapus.',
              ),
            )
          : _BudgetForm(month: b.periodStart, existing: b),
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2))),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Budget')),
        body: Padding(padding: const EdgeInsets.all(24), child: Text('Terjadi kesalahan: $e')),
      ),
    );
  }
}

class _BudgetForm extends ConsumerStatefulWidget {
  const _BudgetForm({required this.month, this.existing});
  final DateTime month;
  final Budget? existing;

  @override
  ConsumerState<_BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends ConsumerState<_BudgetForm> {
  final _formKey = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: widget.existing == null ? '' : MoneyField.textFor(widget.existing!.amount),
  );
  late final _attention = TextEditingController(
    text: '${widget.existing?.attentionThreshold ?? defaultAttentionThreshold}',
  );
  late final _warning = TextEditingController(
    text: '${widget.existing?.warningThreshold ?? defaultWarningThreshold}',
  );
  late final _over = TextEditingController(
    text: '${widget.existing?.overThreshold ?? defaultOverThreshold}',
  );
  String? _categoryId;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _amount.dispose();
    _attention.dispose();
    _warning.dispose();
    _over.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(budgetRepositoryProvider);
    final amount = parseRupiah(_amount.text)!;
    final attention = int.parse(_attention.text);
    final warning = int.parse(_warning.text);
    final over = int.parse(_over.text);
    try {
      if (_isEdit) {
        await repo.update(
          widget.existing!.id,
          amount: amount,
          attention: attention,
          warning: warning,
          over: over,
        );
      } else {
        await repo.create(
          categoryId: _categoryId!,
          month: widget.month,
          amount: amount,
          attention: attention,
          warning: warning,
          over: over,
        );
      }
      if (mounted) context.pop();
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus budget?',
      message: 'Budget ini akan dihapus. Transaksi tidak ikut terhapus.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(budgetRepositoryProvider).delete(widget.existing!.id);
    if (mounted) context.pop();
  }

  String? _thresholdValidator(String? text) {
    final v = int.tryParse(text ?? '');
    if (v == null || v < 1 || v > 1000) return '1–1000';
    return null;
  }

  String? _orderValidator() {
    final a = int.tryParse(_attention.text);
    final w = int.tryParse(_warning.text);
    final o = int.tryParse(_over.text);
    if (a == null || w == null || o == null) return null;
    if (!(a < w && w < o)) return 'Ambang harus berurutan: attention < warning < over.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final existing = widget.existing;
    final categories = ref.watch(activeCategoriesProvider(CategoryType.expense));
    final taken = {
      for (final i in ref.watch(budgetUsagesProvider(widget.month)).value ?? const []) i.category.id,
    };
    final choices = [for (final c in categories) if (!taken.contains(c.id)) c];
    final category = existing == null ? null : ref.watch(categoryMapProvider)[existing.categoryId];

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit budget' : 'Buat budget'),
        actions: [
          if (_isEdit)
            IconButton(
              tooltip: 'Hapus',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Periode', style: context.text.bodySmall!.copyWith(color: fin.muted)),
            const SizedBox(height: 4),
            Text(formatMonth(widget.month), style: context.text.titleMedium),
            const SizedBox(height: 16),
            if (existing != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: IconAvatar(iconFor(category?.icon)),
                title: Text(category?.name ?? 'Kategori', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: const Text('Kategori tidak dapat diubah'),
              )
            else if (choices.isEmpty)
              Text(
                categories.isEmpty
                    ? 'Belum ada kategori expense aktif.'
                    : 'Semua kategori expense sudah punya budget di bulan ini.',
                style: context.text.bodyMedium!.copyWith(color: fin.muted),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kategori'),
                items: [
                  for (final c in choices)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          Icon(iconFor(c.icon), size: 18),
                          const SizedBox(width: 10),
                          Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
                validator: (v) => v == null ? 'Pilih kategori' : null,
              ),
            const SizedBox(height: 16),
            MoneyField(controller: _amount, label: 'Nominal budget', large: true, autofocus: !_isEdit),
            const SizedBox(height: 24),
            const SectionHeader('Ambang peringatan'),
            Text(
              'Notifikasi dikirim sekali saat pemakaian melewati tiap ambang.',
              style: context.text.bodySmall!.copyWith(color: fin.muted),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _ThresholdField(controller: _attention, label: 'Attention', validator: _thresholdValidator)),
                const SizedBox(width: 8),
                Expanded(child: _ThresholdField(controller: _warning, label: 'Warning', validator: _thresholdValidator)),
                const SizedBox(width: 8),
                Expanded(child: _ThresholdField(controller: _over, label: 'Over', validator: _thresholdValidator)),
              ],
            ),
            FormField<void>(
              validator: (_) => _orderValidator(),
              builder: (state) => state.hasError
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        state.errorText!,
                        style: context.text.bodySmall!.copyWith(color: fin.negative),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (_isEdit) ...[
              const SizedBox(height: 12),
              Text(
                'Mengubah nominal atau ambang akan mereset status notifikasi budget ini.',
                style: context.text.bodySmall!.copyWith(color: fin.muted),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving || (existing == null && choices.isEmpty) ? null : _save,
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThresholdField extends StatelessWidget {
  const _ThresholdField({required this.controller, required this.label, required this.validator});
  final TextEditingController controller;
  final String label;
  final FormFieldValidator<String> validator;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
    decoration: InputDecoration(labelText: label, suffixText: '%'),
    validator: validator,
  );
}
