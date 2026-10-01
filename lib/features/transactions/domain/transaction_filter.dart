import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';

const _unset = Object();
const _setEq = SetEquality<String>();

/// FR-TRX-007 filter: type, inclusive date range, categories, accounts,
/// inclusive amount range and keyword (note, category or account name).
@immutable
class TransactionFilter {
  const TransactionFilter({
    this.type,
    this.from,
    this.to,
    this.categoryIds = const {},
    this.accountIds = const {},
    this.minAmount,
    this.maxAmount,
    this.keyword = '',
  });

  final TransactionType? type;

  /// First day included (time ignored).
  final DateTime? from;

  /// Last day included (time ignored).
  final DateTime? to;
  final Set<String> categoryIds;

  /// Matches the source account or the transfer destination.
  final Set<String> accountIds;
  final int? minAmount;
  final int? maxAmount;
  final String keyword;

  String get trimmedKeyword => keyword.trim();

  /// Number of filters set in the filter sheet (type and keyword excluded).
  int get sheetFilterCount =>
      (from != null || to != null ? 1 : 0) +
      (categoryIds.isNotEmpty ? 1 : 0) +
      (accountIds.isNotEmpty ? 1 : 0) +
      (minAmount != null || maxAmount != null ? 1 : 0);

  bool get isEmpty => type == null && sheetFilterCount == 0 && trimmedKeyword.isEmpty;

  /// Inclusive lower bound on transaction_at.
  DateTime? get startAt => from == null ? null : dateOnly(from!);

  /// Exclusive upper bound on transaction_at (start of the day after [to]).
  DateTime? get endBefore => to == null ? null : DateTime(to!.year, to!.month, to!.day + 1);

  TransactionFilter copyWith({
    Object? type = _unset,
    Object? from = _unset,
    Object? to = _unset,
    Set<String>? categoryIds,
    Set<String>? accountIds,
    Object? minAmount = _unset,
    Object? maxAmount = _unset,
    String? keyword,
  }) => TransactionFilter(
    type: identical(type, _unset) ? this.type : type as TransactionType?,
    from: identical(from, _unset) ? this.from : from as DateTime?,
    to: identical(to, _unset) ? this.to : to as DateTime?,
    categoryIds: categoryIds ?? this.categoryIds,
    accountIds: accountIds ?? this.accountIds,
    minAmount: identical(minAmount, _unset) ? this.minAmount : minAmount as int?,
    maxAmount: identical(maxAmount, _unset) ? this.maxAmount : maxAmount as int?,
    keyword: keyword ?? this.keyword,
  );

  /// Keeps type and keyword, clears everything from the filter sheet.
  TransactionFilter clearSheet() => TransactionFilter(type: type, keyword: keyword);

  @override
  bool operator ==(Object other) =>
      other is TransactionFilter &&
      other.type == type &&
      other.from == from &&
      other.to == to &&
      _setEq.equals(other.categoryIds, categoryIds) &&
      _setEq.equals(other.accountIds, accountIds) &&
      other.minAmount == minAmount &&
      other.maxAmount == maxAmount &&
      other.trimmedKeyword == trimmedKeyword;

  @override
  int get hashCode => Object.hash(
    type,
    from,
    to,
    _setEq.hash(categoryIds),
    _setEq.hash(accountIds),
    minAmount,
    maxAmount,
    trimmedKeyword,
  );
}
