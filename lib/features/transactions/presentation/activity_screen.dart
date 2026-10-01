import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/transaction_query_repository.dart';
import '../domain/day_groups.dart';
import '../domain/transaction_filter.dart';
import 'filter_sheet.dart';
import 'widgets/transaction_widgets.dart';

/// Bottom-nav tab "Transaksi": type chips, keyword search, filter sheet
/// (FR-TRX-007) and a day-grouped list loaded [transactionPageSize] rows
/// at a time.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  TransactionFilter _filter = const TransactionFilter();
  int _limit = transactionPageSize;

  /// Last loaded page, shown while a bigger page or new filter loads so the
  /// list does not flash empty.
  TransactionPage? _lastPage;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _setFilter(TransactionFilter f) {
    if (f == _filter) return;
    setState(() {
      _filter = f;
      _limit = transactionPageSize;
    });
  }

  void _onKeyword(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _setFilter(_filter.copyWith(keyword: text));
    });
  }

  void _clearKeyword() {
    _debounce?.cancel();
    _search.clear();
    _setFilter(_filter.copyWith(keyword: ''));
  }

  Future<void> _openFilters() async {
    final f = await showTransactionFilterSheet(context, _filter);
    if (f != null && mounted) _setFilter(f);
  }

  void _resetAll() {
    _debounce?.cancel();
    _search.clear();
    _setFilter(const TransactionFilter());
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(transactionPageProvider((filter: _filter, limit: _limit)));
    if (async.hasValue) _lastPage = async.value;
    final page = async.value ?? _lastPage;
    final loading = async.isLoading;
    final sheetCount = _filter.sheetFilterCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaksi'),
        actions: [
          IconButton(
            tooltip: 'Accounts',
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () => context.push(Routes.accounts),
          ),
          IconButton(
            tooltip: 'Filter',
            onPressed: _openFilters,
            icon: Badge(
              isLabelVisible: sheetCount > 0,
              label: Text('$sheetCount'),
              backgroundColor: context.fin.primary,
              textColor: context.fin.onPrimary,
              child: const Icon(Icons.tune),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'activity-add',
        tooltip: 'Tambah transaksi',
        onPressed: () => context.push(Routes.transactionNew(_filter.type)),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                _typeChip('All', null),
                _typeChip('Income', TransactionType.income),
                _typeChip('Expense', TransactionType.expense),
                _typeChip('Transfer', TransactionType.transfer),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: _onKeyword,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Cari catatan, kategori, account',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: ListenableBuilder(
                  listenable: _search,
                  builder: (_, _) => _search.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(tooltip: 'Hapus pencarian', icon: const Icon(Icons.close), onPressed: _clearKeyword),
                ),
              ),
            ),
          ),
          if (sheetCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text('$sheetCount filter aktif', style: context.text.bodySmall),
                  ),
                  TextButton(
                    onPressed: () => _setFilter(_filter.clearSheet()),
                    child: const Text('Reset filter'),
                  ),
                ],
              ),
            ),
          SizedBox(
            height: 2,
            child: loading && page != null ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            child: page == null
                ? AsyncView<TransactionPage>(value: async, builder: (_) => const SizedBox.shrink())
                : _list(context, page, loading),
          ),
        ],
      ),
    );
  }

  Widget _typeChip(String label, TransactionType? type) {
    final selected = _filter.type == type;
    final fin = context.fin;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: context.text.labelMedium!.copyWith(color: selected ? fin.onPrimary : fin.text)),
        selected: selected,
        onSelected: (_) => _setFilter(_filter.copyWith(type: type, categoryIds: _categoriesFor(type))),
      ),
    );
  }

  /// Keeps only selected categories that can match [type].
  Set<String> _categoriesFor(TransactionType? type) {
    if (type == null) return _filter.categoryIds;
    if (type == TransactionType.transfer) return const {};
    final map = ref.read(categoryMapProvider);
    final want = type == TransactionType.income ? CategoryType.income : CategoryType.expense;
    return {
      for (final id in _filter.categoryIds)
        if (map[id]?.type == want) id,
    };
  }

  Widget _list(BuildContext context, TransactionPage page, bool loading) {
    if (page.items.isEmpty) {
      return ListView(
        children: [
          if (_filter.isEmpty)
            EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'Belum ada transaksi',
              message: 'Catat income, expense atau transfer pertama kamu.',
              actionLabel: 'Tambah transaksi',
              onAction: () => context.push(Routes.transactionNew()),
            )
          else
            EmptyState(
              icon: Icons.search_off,
              title: 'Tidak ada transaksi yang cocok',
              message: 'Ubah kata kunci atau filter.',
              actionLabel: 'Reset filter',
              onAction: _resetAll,
            ),
        ],
      );
    }
    final rows = dayGroupWidgets(context, groupByDay(page.items));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: rows.length + (page.hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i < rows.length) return rows[i];
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton(
            onPressed: loading ? null : () => setState(() => _limit += transactionPageSize),
            child: const Text('Muat lebih banyak'),
          ),
        );
      },
    );
  }
}
