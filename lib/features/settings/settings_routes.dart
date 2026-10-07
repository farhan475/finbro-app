import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../backup/presentation/backup_screen.dart';
import '../onboarding/presentation/onboarding_screen.dart';
import '../security/presentation/security_screen.dart';
import 'presentation/about_screen.dart';
import 'presentation/exchange_rates_screen.dart';
import 'presentation/help_screen.dart';
import 'presentation/log_screen.dart';
import 'presentation/settings_screen.dart';
import 'presentation/settings_widgets.dart';

/// Settings, reliability and onboarding routes (all top-level, absolute).
final List<RouteBase> settingsRoutes = [
  GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
  GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
  GoRoute(path: Routes.backup, builder: (_, _) => const BackupScreen()),
  GoRoute(path: Routes.security, builder: (_, _) => const SecurityScreen()),
  GoRoute(path: Routes.log, builder: (_, _) => const LogScreen()),
  GoRoute(path: Routes.rates, builder: (_, _) => const ExchangeRatesScreen()),
  GoRoute(path: SettingsPaths.appearance, builder: (_, _) => const AppearanceScreen()),
  GoRoute(path: SettingsPaths.about, builder: (_, _) => const AboutScreen()),
  GoRoute(path: SettingsPaths.help, builder: (_, _) => const HelpScreen()),
];
