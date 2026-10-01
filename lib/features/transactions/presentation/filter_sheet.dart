import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../domain/transaction_filter.dart';

/// Filter sheet (FR-TRX-007): date range, categories, accounts, amount
/// range. Returns the new filter, or null when dismissed.
Future<TransactionFilter?> showTransactionFilterSheet(BuildContext context, TransactionFilter current) {
  return showModalBottomSheet<TransactionFilter>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _FilterSheet(initial: current),
  );
}

class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.initial});
  final TransactionFilter initial;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  final _formKey = GlobalKey<FormState>();
  late DateTime? _from = widget.initial.from;
  late DateTime? _to = widget.initial.to;
  late final Set<String> _categories = {...widget.initial.categoryIds};
  late final Set<String> _accounts = {...widget.initial.accountIds};
  late final _min = TextEditingController(
    text: widget.initial.minAmount == null ? '' : MoneyField.textFor(widget.initial.minAmount!),
  );
  late final _max = TextEditingController(
    text: widget.initial.maxAmount == null ? '' : MoneyField.textFor(widget.initial.maxAmount!),
  );

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _setRange(DateTime? from, DateTime? to) => setState(() {
    _from = from;
    _to = to;
  });

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
      initialDateRange: _from != null && _to != null ? DateTimeRange(start: _from!, end: _to!) : null,
    );
    if (r != null) _setRange(dateOnly(r.start), dateOnly(r.end));
  }

  void _apply() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      widget.initial.copyWith(
        from: _from,
        to: _to,
        categoryIds: Set.unmodifiable(_categories),
        accountIds: Set.unmodifiable(_accounts),
        minAmount: parseRupiah(_min.text),
        maxAmount: parseRupiah(_max.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final now = DateTime.now();
    final today = dateOnly(now);
    final type = widget.initial.type;
    final categories = [
      for (final c in ref.watch(allCategoriesProvider).value ?? const <Category>[])
        if (type == null ||
            (type == TransactionType.income && c.type == CategoryType.income) ||
            (type == TransactionType.expense && c.type == CategoryType.expense))
          c,
    ];
    final accounts = ref.watch(allAccountsProvider).value ?? const <Account>[];
    final rangeLabel = _from == null && _to == null
        ? 'Semua tanggal'
        : '${_from == null ? '…' : formatDay(_from!)} – ${_to == null ? '…' : formatDay(_to!)}';

    Widget chip(String label, bool selected, VoidCallback onTap) => FilterChip(
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.labelMedium!.copyWith(color: selected ? fin.onPrimary : fin.text),
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('Filter transaksi', style: context.text.titleLarge),
            const SectionHeader('Tanggal'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                chip('Hari ini', _from == today && _to == today, () => _setRange(today, today)),
                chip(
                  '7 hari terakhir',
                  _from == today.subtract(const Duration(days: 6)) && _to == today,
                  () => _setRange(today.subtract(const Duration(days: 6)), today),
                ),
                chip(
                  'Bulan ini',
                  _from == monthStart(now) && _to == monthEnd(now),
                  () => _setRange(monthStart(now), monthEnd(now)),
                ),
                chip(
                  'Bulan lalu',
                  _from == DateTime(now.year, now.month - 1) && _to == monthEnd(DateTime(now.year, now.month - 1)),
                  () => _setRange(DateTime(now.year, now.month - 1), monthEnd(DateTime(now.year, now.month - 1))),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickRange,
              icon: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(rangeLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (_from != null || _to != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => _setRange(null, null), child: const Text('Hapus rentang tanggal')),
              ),
            if (type != TransactionType.transfer) ...[
              const SectionHeader('Kategori'),
              if (categories.isEmpty)
                Text('Belum ada kategori.', style: context.text.bodySmall)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in categories)
                      chip(
                        type == null ? '${c.name} · ${c.type == CategoryType.income ? 'Income' : 'Expense'}' : c.name,
                        _categories.contains(c.id),
                        () => setState(() => _categories.contains(c.id) ? _categories.remove(c.id) : _categories.add(c.id)),
                      ),
                  ],
                ),
            ],
            const SectionHeader('Account'),
            if (accounts.isEmpty)
              Text('Belum ada account.', style: context.text.bodySmall)
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in accounts)
                    chip(
                      a.isActive ? a.name : '${a.name} (arsip)',
                      _accounts.contains(a.id),
                      () => setState(() => _accounts.contains(a.id) ? _accounts.remove(a.id) : _accounts.add(a.id)),
                    ),
                ],
              ),
            const SectionHeader('Nominal'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: MoneyField(controller: _min, label: 'Minimal', validator: (_) => null)),
                const SizedBox(width: 12),
                Expanded(
                  child: MoneyField(
                    controller: _max,
                    label: 'Maksimal',
                    validator: (max) {
                      final min = parseRupiah(_min.text);
                      if (min != null && max != null && max < min) return 'Harus ≥ minimal';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(widget.initial.clearSheet()),
                    child: const Text('Reset'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(onPressed: _apply, child: const Text('Terapkan'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
