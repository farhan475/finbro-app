import '../../core/database/app_database.dart';

/// Feature-internal paths of the budget routes (registered in
/// `budgets_routes.dart`).
abstract final class BudgetPaths {
  static const newBudget = '/budgets/new';
  static const edit = '/budgets/:id';

  /// Create form for the month of [month] (`?month=yyyy-MM`).
  static String create(DateTime month) =>
      '$newBudget?month=${isoDate(month).substring(0, 7)}';

  static String editBudget(String id) => '/budgets/$id';

  /// Parses `yyyy-MM` back to the first day of that month.
  static DateTime? parseMonth(String? raw) {
    final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(raw ?? '');
    if (m == null) return null;
    final month = int.parse(m.group(2)!);
    if (month < 1 || month > 12) return null;
    return DateTime(int.parse(m.group(1)!), month);
  }
}

