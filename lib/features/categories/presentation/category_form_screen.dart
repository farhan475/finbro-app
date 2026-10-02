import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/category_repository.dart';
import 'categories_screen.dart';
import 'icon_choice.dart';

/// Create (`/categories/new?type=`) or edit (`/categories/:id`) a category:
/// name, type, icon, planning bucket + expense nature (expense only),
/// activate/deactivate, delete (custom and unused only).
class CategoryFormScreen extends ConsumerStatefulWidget {
  const CategoryFormScreen({super.key, this.categoryId, this.initialType = CategoryType.expense});

  final String? categoryId;
  final CategoryType initialType;

  @override
  ConsumerState<CategoryFormScreen> createState() => _CategoryFormScreenState();
}

class _CategoryFormScreenState extends ConsumerState<CategoryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  late CategoryType _type = widget.initialType;
  String? _icon = 'other';
  PlanningBucket? _bucket = PlanningBucket.personal;
  ExpenseNature? _nature = ExpenseNature.discretionary;
  Category? _original;
  bool _loading = true;
  bool _missing = false;
  bool _busy = false;

  bool get _isEdit => widget.categoryId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.categoryId;
    if (id != null) {
      final db = ref.read(databaseProvider);
      final c = await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingleOrNull();
      if (!mounted) return;
      if (c == null) {
        _missing = true;
      } else {
        _original = c;
        _name.text = c.name;
        _type = c.type;
        _icon = c.icon;
        _bucket = c.planningBucket ?? PlanningBucket.personal;
        _nature = c.expenseNature ?? ExpenseNature.discretionary;
      }
    }
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _close(String message) {
    final messenger = ScaffoldMessenger.of(context);
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.categories);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _guard(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on CategoryException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error(failure, e, s);
      if (mounted) showSnack(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final input = CategoryInput(
      name: _name.text,
      type: _type,
      icon: _icon,
      planningBucket: _type == CategoryType.expense ? _bucket : null,
      expenseNature: _type == CategoryType.expense ? _nature : null,
    );
    await _guard(() async {
      final repo = ref.read(categoryRepositoryProvider);
      if (_isEdit) {
        await repo.update(widget.categoryId!, input);
      } else {
        await repo.create(input);
      }
      if (mounted) _close(_isEdit ? 'Kategori diperbarui.' : 'Kategori ditambahkan.');
    }, 'Kategori gagal disimpan.');
  }

  Future<void> _setActive(Category c, bool active) async {
    if (!active) {
      final ok = await confirmDialog(
        context,
        title: 'Nonaktifkan ${c.name}?',
        message: 'Kategori tidak muncul lagi saat mencatat transaksi. Riwayat dan laporan tetap memakai kategori ini.',
        confirmLabel: 'Nonaktifkan',
        destructive: true,
      );
      if (!ok) return;
    }
    await _guard(() async {
      await ref.read(categoryRepositoryProvider).setActive(c.id, active);
      final db = ref.read(databaseProvider);
      final fresh = await (db.select(db.categories)..where((x) => x.id.equals(c.id))).getSingle();
      if (!mounted) return;
      setState(() => _original = fresh);
      showSnack(context, active ? 'Kategori diaktifkan.' : 'Kategori dinonaktifkan.');
    }, 'Gagal mengubah status kategori.');
  }

  Future<void> _delete(Category c) async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus ${c.name}?',
      message: 'Kategori ini belum dipakai dan akan dihapus permanen.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok) return;
    await _guard(() async {
      await ref.read(categoryRepositoryProvider).delete(c.id);
      if (mounted) _close('Kategori dihapus.');
    }, 'Gagal menghapus kategori.');
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? 'Edit kategori' : 'Tambah kategori';
    if (_loading || _missing) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: _missing
              ? const EmptyState(icon: Icons.search_off, title: 'Kategori tidak ditemukan')
              : const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final fin = context.fin;
    final original = _original;
    final isExpense = _type == CategoryType.expense;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (original != null && original.isSystem) ...[
              Text(
                'Kategori bawaan: bisa diubah dan dinonaktifkan, tetapi tidak bisa dihapus.',
                style: context.text.bodySmall,
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _name,
              autofocus: !_isEdit,
              maxLength: CategoryRepository.maxNameLength,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nama kategori'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Nama kategori wajib diisi' : null,
            ),
            const SectionHeader('Jenis'),
            if (_isEdit)
              Text(
                '${isExpense ? 'Expense' : 'Income'} · jenis tidak bisa diubah setelah dibuat.',
                style: context.text.bodyMedium,
              )
            else
              SegmentedButton<CategoryType>(
                segments: const [
                  ButtonSegment(value: CategoryType.expense, label: SegmentLabel('Expense')),
                  ButtonSegment(value: CategoryType.income, label: SegmentLabel('Income')),
                ],
                selected: {_type},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
            if (isExpense) ...[
              const SectionHeader('Planning bucket'),
              DropdownButtonFormField<PlanningBucket>(
                initialValue: _bucket,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Masuk ke alokasi'),
                items: [
                  for (final b in PlanningBucket.values) DropdownMenuItem(value: b, child: Text(b.label)),
                ],
                onChanged: (b) => setState(() => _bucket = b),
                validator: (b) => b == null ? 'Pilih planning bucket' : null,
              ),
              const SectionHeader('Sifat pengeluaran'),
              SegmentedButton<ExpenseNature>(
                segments: [
                  for (final n in ExpenseNature.values) ButtonSegment(value: n, label: SegmentLabel(expenseNatureLabel(n))),
                ],
                selected: {?_nature},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _nature = s.firstOrNull),
              ),
              const SizedBox(height: 6),
              Text(
                'Essential dipakai untuk Essential Expense Ratio dan target Emergency Fund.',
                style: context.text.bodySmall,
              ),
            ],
            const SectionHeader('Ikon'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in iconRegistry.entries)
                  IconChoice(
                    icon: e.value,
                    label: e.key,
                    selected: _icon == e.key,
                    onTap: () => setState(() => _icon = e.key),
                  ),
              ],
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Simpan'),
            ),
            if (original != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : () => _setActive(original, !original.isActive),
                child: Text(original.isActive ? 'Nonaktifkan' : 'Aktifkan kembali'),
              ),
              if (!original.isSystem) ...[
                const SizedBox(height: 12),
                _DeleteButton(
                  category: original,
                  enabled: !_busy,
                  color: fin.negative,
                  onDelete: () => _delete(original),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Delete only while unused; otherwise explains why.
class _DeleteButton extends ConsumerWidget {
  const _DeleteButton({required this.category, required this.enabled, required this.color, required this.onDelete});

  final Category category;
  final bool enabled;
  final Color color;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(categoryUsageProvider(category.id)).value;
    final used = usage != null && usage > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: enabled && usage == 0 ? onDelete : null,
          style: OutlinedButton.styleFrom(foregroundColor: color),
          child: const Text('Hapus kategori'),
        ),
        if (used) ...[
          const SizedBox(height: 6),
          Text(
            'Dipakai oleh $usage transaksi/budget/aturan berulang, jadi tidak bisa dihapus. Nonaktifkan saja.',
            style: context.text.bodySmall,
          ),
        ],
      ],
    );
  }
}
