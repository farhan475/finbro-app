import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/app_wiring.dart';
import 'app/root.dart';
import 'core/background/background_sync.dart';
import 'core/formatting/dates.dart';
import 'core/notifications/notification_service.dart';
import 'core/utilities/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting(appLocale);
  await AppLogger.init(await getApplicationSupportDirectory());

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLogger.error('FlutterError', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error('Uncaught', error, stack);
    return true;
  };

  runApp(const FinBroRoot());
  // Timezone data decoding and plugin channel calls stay off the first frame;
  // consumers wait on NotificationService.initialized.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => NotificationService.instance.init(onEvent: notificationEvents.add),
  );
}

/// Headless entrypoint of the periodic background job, run by
/// `BackgroundSyncWorker` (Kotlin, Android WorkManager) on its own engine.
/// Looked up by name in this library, like `main`.
@pragma('vm:entry-point')
Future<void> backgroundSyncMain() => runBackgroundSync(runBackgroundTasks);
