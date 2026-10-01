import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../transactions/ledger_paths.dart';
import '../data/category_repository.dart';

String expenseNatureLabel(ExpenseNature n) => switch (n) {
  ExpenseNature.essential => 'Essential',
  ExpenseNature.discretionary => 'Discretionary',
};

/// `/categories`: Expense and Income tabs, active first; toggle active,
/// tap to edit, + to create.
class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);

  static const _types = [CategoryType.expense, CategoryType.income];

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final async = ref.watch(allCategoriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kategori'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: fin.text,
          unselectedLabelColor: fin.muted,
          indicatorColor: fin.primary,
          dividerColor: fin.border,
          tabs: const [Tab(text: 'Expense'), Tab(text: 'Income')],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'categories-add',
        tooltip: 'Tambah kategori',
        onPressed: () => context.push(LedgerPaths.categoryNew(_types[_tabs.index])),
        child: const Icon(Icons.add),
      ),
      body: AsyncView<List<Category>>(
        value: async,
        builder: (all) => TabBarView(
          controller: _tabs,
          children: [
            for (final t in _types) _CategoryList(categories: [for (final c in all) if (c.type == t) c], type: t),
          ],
        ),
      ),
    );
  }
}

class _CategoryList extends ConsumerWidget {
  const _CategoryList({required this.categories, required this.type});
  final List<Category> categories;
  final CategoryType type;

  Future<void> _toggle(BuildContext context, WidgetRef ref, Category c, bool active) async {
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
    try {
      await ref.read(categoryRepositoryProvider).setActive(c.id, active);
    } on CategoryException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error('Gagal mengubah status kategori', e, s);
      if (context.mounted) showSnack(context, 'Gagal mengubah status kategori.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (categories.isEmpty) {
      return Center(
        child: EmptyState(
          icon: Icons.category_outlined,
          title: 'Belum ada kategori ${type == CategoryType.income ? 'income' : 'expense'}',
          actionLabel: 'Tambah kategori',
          onAction: () => context.push(LedgerPaths.categoryNew(type)),
        ),
      );
    }
    final active = [for (final c in categories) if (c.isActive) c];
    final inactive = [for (final c in categories) if (!c.isActive) c];
    Widget section(List<Category> items) => FinCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          for (final (i, c) in items.indexed) ...[
            if (i > 0) const Divider(),
            _CategoryRow(category: c, onToggle: (v) => _toggle(context, ref, c, v)),
          ],
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        if (active.isEmpty)
          Text('Semua kategori nonaktif.', style: context.text.bodySmall)
        else
          section(active),
        if (inactive.isNotEmpty) ...[
          SectionHeader('Nonaktif (${inactive.length})'),
          section(inactive),
        ],
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, required this.onToggle});
  final Category category;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = category;
    final subtitle = [
      if (c.planningBucket != null) c.planningBucket!.label,
      if (c.expenseNature != null) expenseNatureLabel(c.expenseNature!),
      c.isSystem ? 'Bawaan' : 'Custom',
      if (!c.isActive) 'Nonaktif',
    ].join(' · ');
    return InkWell(
      onTap: () => context.push(LedgerPaths.categoryEdit(c.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            IconAvatar(iconFor(c.icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(subtitle, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Switch(
              value: c.isActive,
              onChanged: onToggle,
            ),
          ],
        ),
      ),
    );
  }
}
