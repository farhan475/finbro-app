import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/root.dart';
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

  await NotificationService.instance.init(onEvent: notificationEvents.add);
  runApp(const FinBroRoot());
}
