import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import 'presentation/scan_screen.dart';

final List<RouteBase> scannerRoutes = [
  GoRoute(path: Routes.scan, builder: (_, _) => const ScanScreen()),
];
