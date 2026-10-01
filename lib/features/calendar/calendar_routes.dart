import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import 'presentation/calendar_screen.dart';

final List<RouteBase> calendarRoutes = [
  GoRoute(path: Routes.calendar, builder: (_, _) => const CalendarScreen()),
];
