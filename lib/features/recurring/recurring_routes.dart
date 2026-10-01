import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import 'presentation/notification_settings_screen.dart';
import 'presentation/recurring_detail_screen.dart';
import 'presentation/recurring_form_screen.dart';
import 'presentation/recurring_list_screen.dart';

/// Path opened from a recurring reminder notification
/// (payload `{'kind': 'recurring', 'instanceId': id}`).
String recurringInstancePath(String instanceId) => '${Routes.recurring}/instance/$instanceId';

final List<RouteBase> recurringRoutes = [
  GoRoute(path: Routes.recurring, builder: (_, _) => const RecurringListScreen()),
  GoRoute(
    path: '${Routes.recurring}/new',
    builder: (_, state) => RecurringFormScreen(salaryPreset: state.uri.queryParameters['preset'] == 'salary'),
  ),
  GoRoute(
    path: '${Routes.recurring}/instance/:instanceId',
    builder: (_, state) => RecurringInstanceRedirect(instanceId: state.pathParameters['instanceId']!),
  ),
  GoRoute(
    path: '${Routes.recurring}/:id/edit',
    builder: (_, state) => RecurringEditScreen(ruleId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '${Routes.recurring}/:id',
    builder: (_, state) => RecurringDetailScreen(ruleId: state.pathParameters['id']!),
  ),
  GoRoute(path: Routes.notificationSettings, builder: (_, _) => const NotificationSettingsScreen()),
];
