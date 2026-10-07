import '../core/database/enums.dart';

/// Cross-feature route paths. Feature-internal sub-routes stay inside each
/// feature's `*_routes.dart` under that feature's own prefix.
abstract final class Routes {
  // Bottom navigation: Home | Transaksi | Budget | Analitik (reports) | Lainnya (more)
  static const home = '/';
  static const activity = '/activity';
  static const budget = '/budget';
  static const goals = '/goals';
  static const more = '/more';

  static const onboarding = '/onboarding';

  // Transactions / accounts / categories
  static String transactionNew([TransactionType? type]) =>
      type == null ? '/transaction/new' : '/transaction/new?type=${type.db}';
  static String transactionDetail(String id) => '/transaction/$id';
  static const accounts = '/accounts';
  static const categories = '/categories';

  // Budget & goals & planning
  static const planning = '/settings/planning';

  // Recurring & calendar
  static const recurring = '/recurring';
  static const calendar = '/calendar';
  static const notificationSettings = '/settings/notifications';

  // Reports
  static const reports = '/reports';
  static const health = '/reports/health';

  // Scan
  static const scan = '/scan';
  static const statementImport = '/import';

  // Settings / reliability
  static const backup = '/settings/backup';
  static const security = '/settings/security';
  static const log = '/settings/log';
  static const rates = '/settings/rates';
}
