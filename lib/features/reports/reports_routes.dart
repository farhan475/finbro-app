import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import 'presentation/health_screen.dart';

/// `/reports/health?month=2026-09` opens Financial Health for that month.
String healthLocation(DateTime month) =>
    '${Routes.health}?month=${month.year}-${month.month.toString().padLeft(2, '0')}';

DateTime? _parseMonth(String? raw) {
  final parts = raw?.split('-');
  if (parts == null || parts.length != 2) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (y == null || m == null || m < 1 || m > 12) return null;
  return DateTime(y, m);
}

final List<RouteBase> reportsRoutes = [
  GoRoute(
    path: Routes.health,
    builder: (_, state) => HealthScreen(initialMonth: _parseMonth(state.uri.queryParameters['month'])),
  ),
];
