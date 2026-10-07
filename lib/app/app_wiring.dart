import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../core/background/external_writes.dart';
import '../core/database/app_database.dart';
import '../core/ledger/ledger_service.dart';
import '../core/providers.dart';
import '../core/utilities/app_logger.dart';
import '../core/widget/widget_background.dart';
import '../core/widget/widget_service.dart';
import '../features/backup/data/folder_backup_platform.dart';
import '../features/budgets/domain/budget_alert_service.dart';
import '../features/calendar/domain/daily_check_service.dart';
import '../features/recurring/domain/recurring_engine.dart';
import '../features/settings/domain/startup_checks.dart';

/// Tasks run on app start and every resume (05-architecture §4: recurring
/// check on app lifecycle, notification rescheduling, integrity marker).
typedef LifecycleTask = Future<void> Function(DateTime now);

final lifecycleTasksProvider = Provider<List<LifecycleTask>>((ref) => const []);

/// Tasks of the periodic background job ([runBackgroundTasks]): the
/// lifecycle work that must also happen while the app is not opened.
final backgroundTasksProvider = Provider<List<LifecycleTask>>((ref) => const []);

/// Overrides that connect feature services to core extension points.
List<Override> wiringOverrides() => [
  // Post-commit side effects of every ledger write (the background job's
  // auto-confirms included: budget alerts, day states).
  ledgerListenersProvider.overrideWith(
    (ref) => [
      ref.read(budgetAlertServiceProvider).onLedgerChange,
      ref.read(dailyCheckServiceProvider).onLedgerChange,
    ],
  ),
  // Order matters: first pick up commits of other connections (background
  // job, notification actions), then integrity, then recurring (may
  // auto-confirm and mark days active), then daily-check scheduling based
  // on the final day states.
  lifecycleTasksProvider.overrideWith(
    (ref) => [
      ref.read(externalWritesProvider).check,
      ref.read(startupChecksProvider).run,
      ref.read(recurringEngineProvider).sync,
      ref.read(dailyCheckServiceProvider).reschedule,
      // Home-screen widget: resync after recurring auto-posts; reading the
      // provider also starts its table listener (no-op off Android).
      ref.read(widgetSyncProvider).refresh,
      // Last, after recurring auto-posts; starts in the background and returns.
      ref.read(folderBackupServiceProvider).onLifecycle,
    ],
  ),
  // Same order on the background job's own connection, without the session
  // integrity marker (app sessions only).
  backgroundTasksProvider.overrideWith(
    (ref) => [
      ref.read(recurringEngineProvider).sync,
      ref.read(dailyCheckServiceProvider).reschedule,
      (now) async => renderWidget(await computeWidgetSnapshot(ref.read(databaseProvider), now: now)),
      // Awaited: the job ends when its tasks return.
      ref.read(folderBackupServiceProvider).runIfDue,
    ],
  ),
];

/// Body of the periodic background job (`runBackgroundSync`): runs
/// [backgroundTasksProvider] against [db] with the app's wiring. A failing
/// task is logged and does not stop the others.
Future<void> runBackgroundTasks(AppDatabase db, DateTime now) async {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db), ...wiringOverrides()],
  );
  try {
    for (final task in container.read(backgroundTasksProvider)) {
      try {
        await task(now);
      } catch (e, s) {
        AppLogger.error('Tugas latar belakang gagal', e, s);
      }
    }
  } finally {
    container.dispose();
  }
}
