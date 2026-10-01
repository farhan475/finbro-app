import '../../core/database/enums.dart';

/// Feature-internal paths of the transactions/accounts/categories screens
/// (cross-feature entry points live in `Routes`).
abstract final class LedgerPaths {
  static String transactionEdit(String id) => '/transaction/$id/edit';

  /// New transaction with [accountId] preselected.
  static String transactionNewForAccount(String accountId) =>
      '/transaction/new?account=${Uri.encodeQueryComponent(accountId)}';

  static const accountNew = '/accounts/new';
  static String accountDetail(String id) => '/accounts/$id';
  static String accountEdit(String id) => '/accounts/$id/edit';

  static String categoryNew(CategoryType type) => '/categories/new?type=${type.db}';
  static String categoryEdit(String id) => '/categories/$id';
}
