import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../formatting/dates.dart';
import '../notifications/notification_service.dart';
import '../settings/app_settings_repository.dart';
import '../utilities/app_logger.dart';

/// Method channel between `BackgroundSyncWorker` (Kotlin) and its headless
/// Dart isolate. Dart→Kotlin `done` (argument: whether the job ran without
/// an uncaught error) ends the work; Kotlin then destroys the engine.
const backgroundSyncChannel = MethodChannel('id.finbro.app/background');

/// What the periodic background job does with the live database.
typedef BackgroundSyncBody = Future<void> Function(AppDatabase db, DateTime now);

/// Runs one pass of the periodic background job (Android WorkManager, see
/// `BackgroundSyncWorker.kt`) in its headless isolate, then reports `done`
/// — always, so the worker never waits for its timeout.
///
/// Never creates the database: does nothing when the file does not exist
/// yet or onboarding is not done. Otherwise opens it like every isolate
/// ([openDeviceDatabase]), initializes the notification plugin (scheduling
/// and pending-request diffs need it) and runs [body].
Future<void> runBackgroundSync(BackgroundSyncBody body) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  var ok = false;
  try {
    await initializeDateFormatting(appLocale);
    await AppLogger.init(await getApplicationSupportDirectory());
    await _run(body);
    ok = true;
  } catch (e, s) {
    AppLogger.error('Sinkronisasi latar belakang gagal', e, s);
  } finally {
    try {
      await backgroundSyncChannel.invokeMethod<void>('done', ok);
    } on MissingPluginException {
      // Not started by the worker (no handler): nothing waits for it.
    }
  }
}

Future<void> _run(BackgroundSyncBody body) async {
  if (!await (await databaseFile()).exists()) return;
  final db = await openDeviceDatabase();
  try {
    if (!await AppSettingsRepository(db).getBool(SettingKeys.onboardingDone)) return;
    await NotificationService.instance.init(onEvent: (_) {});
    await body(db, DateTime.now());
  } finally {
    await db.close();
  }
}
