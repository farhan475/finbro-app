import '../../core/database/app_database.dart';

/// Feature-internal paths of the goal routes (registered in
/// `lib/features/budgets/budgets_routes.dart`).
abstract final class GoalPaths {
  static const newGoal = '/goal/new';
  static const detail = '/goal/:id';
  static const edit = '/goal/:id/edit';

  /// Create form, optionally preset to [type] (`?type=emergency`).
  static String create([GoalType? type]) =>
      type == null ? newGoal : '$newGoal?type=${type.db}';
  static String goalDetail(String id) => '/goal/$id';
  static String editGoal(String id) => '/goal/$id/edit';
}
