import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings/app_settings_repository.dart';
import '../features/budgets/budgets_routes.dart';
import '../features/budgets/presentation/budget_screen.dart';
import '../features/calendar/calendar_routes.dart';
import '../features/dashboard/presentation/home_screen.dart';
import '../features/goals/presentation/goals_screen.dart';
import '../features/recurring/recurring_routes.dart';
import '../features/reports/reports_routes.dart';
import '../features/scanner/scanner_routes.dart';
import '../features/settings/presentation/more_screen.dart';
import '../features/settings/settings_routes.dart';
import '../features/transactions/presentation/activity_screen.dart';
import '../features/transactions/transactions_routes.dart';
import 'routes.dart';
import 'shell.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Notifies go_router when onboarding state changes.
class _SettingsListenable extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _SettingsListenable();
  ref.listen(appSettingsProvider, (_, _) => listenable.ping());
  ref.onDispose(listenable.dispose);

  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: Routes.home,
    refreshListenable: listenable,
    redirect: (context, state) {
      final settings = ref.read(appSettingsProvider);
      if (!settings.hasValue) return null;
      final done = settings.value![SettingKeys.onboardingDone] == 'true';
      final atOnboarding = state.matchedLocation == Routes.onboarding;
      if (!done && !atOnboarding) return Routes.onboarding;
      if (done && atOnboarding) return Routes.home;
      return null;
    },
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: Routes.activity, builder: (_, _) => const ActivityScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: Routes.budget, builder: (_, _) => const BudgetScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: Routes.goals, builder: (_, _) => const GoalsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: Routes.more, builder: (_, _) => const MoreScreen())]),
        ],
      ),
      ...transactionsRoutes,
      ...budgetsRoutes,
      ...recurringRoutes,
      ...calendarRoutes,
      ...reportsRoutes,
      ...scannerRoutes,
      ...settingsRoutes,
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
