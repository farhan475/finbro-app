import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/database/app_database.dart';
import '../goals/goal_paths.dart';
import '../goals/presentation/goal_detail_screen.dart';
import '../goals/presentation/goal_form_screen.dart';
import '../planning/presentation/planning_settings_screen.dart';
import 'budget_paths.dart';
import 'presentation/budget_form_screen.dart';

/// Full-screen routes of the budgets, goals and planning features.
final List<RouteBase> budgetsRoutes = [
  GoRoute(
    path: BudgetPaths.newBudget,
    builder: (_, state) => BudgetFormScreen(
      month: BudgetPaths.parseMonth(state.uri.queryParameters['month']),
    ),
  ),
  GoRoute(
    path: BudgetPaths.edit,
    builder: (_, state) => BudgetFormScreen(budgetId: state.pathParameters['id']),
  ),
  GoRoute(
    path: GoalPaths.newGoal,
    builder: (_, state) {
      final raw = state.uri.queryParameters['type'];
      final type = GoalType.values.where((t) => t.db == raw).firstOrNull;
      return GoalFormScreen(initialType: type);
    },
  ),
  GoRoute(
    path: GoalPaths.edit,
    builder: (_, state) => GoalFormScreen(goalId: state.pathParameters['id']),
  ),
  GoRoute(
    path: GoalPaths.detail,
    builder: (_, state) => GoalDetailScreen(goalId: state.pathParameters['id']!),
  ),
  GoRoute(path: Routes.planning, builder: (_, _) => const PlanningSettingsScreen()),
];
