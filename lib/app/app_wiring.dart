import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../core/ledger/ledger_service.dart';
import '../features/backup/data/folder_backup_platform.dart';
import '../features/budgets/domain/budget_alert_service.dart';
import '../features/calendar/domain/daily_check_service.dart';
import '../features/recurring/domain/recurring_engine.dart';
import '../features/settings/domain/startup_checks.dart';

/// Tasks run on app start and every resume (05-architecture §4: recurring
/// check on app lifecycle, notification rescheduling, integrity marker).
typedef LifecycleTask = Future<void> Function(DateTime now);

final lifecycleTasksProvider = Provider<List<LifecycleTask>>((ref) => const []);

/// Overrides that connect feature services to core extension points.
List<Override> wiringOverrides() => [
  // Post-commit side effects of every ledger write.
  ledgerListenersProvider.overrideWith(
    (ref) => [
      ref.read(budgetAlertServiceProvider).onLedgerChange,
      ref.read(dailyCheckServiceProvider).onLedgerChange,
    ],
  ),
  // Order matters: integrity first, then recurring (may auto-confirm and mark
  // days active), then daily-check scheduling based on the final day states.
  lifecycleTasksProvider.overrideWith(
    (ref) => [
      ref.read(startupChecksProvider).run,
      ref.read(recurringEngineProvider).sync,
      ref.read(dailyCheckServiceProvider).reschedule,
      // Last, after recurring auto-posts; starts in the background and returns.
      ref.read(folderBackupServiceProvider).onLifecycle,
    ],
  ),
];
