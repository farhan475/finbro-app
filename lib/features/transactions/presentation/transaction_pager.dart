import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utilities/app_logger.dart';
import '../data/transaction_query_repository.dart';
import '../domain/transaction_filter.dart';

/// Rows of a lazily loaded transaction list: the reactive first page of
/// [transactionPageProvider] followed by pages appended by "load more",
/// each fetched by cursor (no re-reading of loaded rows).
///
/// When the provider emits a new first page:
/// - for another filter, the list restarts from that page;
/// - for the same filter after "load more", every loaded row is re-read in
///   one query (rounded up to whole pages) and replaces [rows], so an edit
///   or delete keeps the list length and scroll position without showing
///   stale or deleted rows once it lands.
/// Until a new filter's first page arrives the previous rows stay, so the
/// list does not flash empty.
class TransactionPager {
  TransactionPager(this._onChanged);

  /// Called when an async load changes [rows] or [loadingMore]; typically a
  /// `mounted`-guarded `setState`.
  final void Function() _onChanged;

  TransactionFilter? _filter;

  /// Latest first page from the provider.
  TransactionPage? _base;

  /// Every loaded row, newest first.
  final _rows = <LedgerTransaction>[];

  /// Page that loaded the end of [_rows] (its cursor and whether more
  /// exist); null while [_rows] is just [_base].
  TransactionPage? _tail;

  /// Bumped whenever [_rows] is replaced; async loads started under an
  /// older value are dropped.
  int _generation = 0;

  bool _loadingMore = false;
  bool _reloading = false;

  /// Whether a first page has arrived; until then show the [watch] value.
  bool get loaded => _base != null;

  /// Loaded rows, newest first. Do not modify.
  List<LedgerTransaction> get rows => _rows;

  bool get hasMore => (_tail ?? _base)?.hasMore ?? false;

  /// Whether "load more" or a reload of the loaded rows is running.
  bool get loadingMore => _loadingMore || _reloading;

  /// Watches the first page of [filter]; call from `build`.
  AsyncValue<TransactionPage> watch(WidgetRef ref, TransactionFilter filter) {
    final async = ref.watch(transactionPageProvider((filter: filter, limit: transactionPageSize)));
    final first = async.value;
    if (first != null && !identical(first, _base)) {
      final reload = filter == _filter && _tail != null;
      _filter = filter;
      _base = first;
      _generation++;
      _loadingMore = false;
      if (reload) {
        _reload(ref, filter);
      } else {
        _reloading = false;
        _rows
          ..clear()
          ..addAll(first.items);
        _tail = null;
      }
    }
    return async;
  }

  /// Re-reads as many rows as are loaded, keeping the old rows on screen
  /// until the fresh ones land.
  Future<void> _reload(WidgetRef ref, TransactionFilter filter) async {
    final generation = _generation;
    final limit = (_rows.length / transactionPageSize).ceil() * transactionPageSize;
    _reloading = true;
    try {
      final page = await ref.read(transactionQueryRepositoryProvider).page(filter, limit: limit);
      if (generation != _generation) return;
      _rows
        ..clear()
        ..addAll(page.items);
      _tail = page;
    } catch (e, s) {
      AppLogger.error('Reloading transaction list failed', e, s);
      if (generation != _generation) return;
      _rows
        ..clear()
        ..addAll(_base!.items);
      _tail = null;
    }
    _reloading = false;
    _onChanged();
  }

  /// Appends the page after the loaded rows.
  Future<void> loadMore(WidgetRef ref) async {
    final base = _base;
    if (base == null || loadingMore) return;
    final generation = _generation;
    _loadingMore = true;
    _onChanged();
    TransactionPage? next;
    try {
      next = await ref.read(transactionQueryRepositoryProvider).page(_filter!, after: (_tail ?? base).next);
    } finally {
      // A newer first page already replaced the rows; they win.
      if (generation == _generation) {
        if (next != null) {
          _rows.addAll(next.items);
          _tail = next;
        }
        _loadingMore = false;
        _onChanged();
      }
    }
  }
}
