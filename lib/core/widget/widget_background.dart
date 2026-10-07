import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../database/app_database.dart';
import '../finance/finance_service.dart';
import '../formatting/dates.dart';
import '../formatting/money.dart';
import '../settings/app_settings_repository.dart';

/// Method channel between the Android home-screen widget (Kotlin) and Dart.
/// Dart→Kotlin `render`: store the snapshot and update every placed widget
/// (handled by `WidgetChannel` on both the app engine and the headless
/// widget engine). Kotlin→Dart `refresh` (headless engine only): compute a
/// fresh snapshot from disk and `render` it.
const widgetChannel = MethodChannel('id.finbro.app/widget');

/// Placeholder shown instead of an amount.
const widgetMaskedBalance = '••••••';

/// What the widget shows for one compute.
@immutable
class WidgetSnapshot {
  const WidgetSnapshot({
    required this.balanceText,
    required this.masked,
    required this.updatedText,
  });

  /// Before onboarding (or before the app ever created its database): there
  /// is no balance to show yet.
  static const notSetUp = WidgetSnapshot(
    balanceText: 'Rp –',
    masked: false,
    updatedText: 'Buka FinBro untuk mulai',
  );

  /// The database could not be read; never leave an amount on screen.
  static const unavailable = WidgetSnapshot(
    balanceText: widgetMaskedBalance,
    masked: true,
    updatedText: 'Buka FinBro untuk memperbarui',
  );

  /// `Rp 1.234.567` when [masked] is false, [widgetMaskedBalance] otherwise.
  final String balanceText;
  final bool masked;

  /// `Diperbarui 3 Okt 09:05`, `Terkunci` (PIN set) or `Saldo disembunyikan`.
  final String updatedText;

  Map<String, String> toArguments() => {'balanceText': balanceText, 'updatedText': updatedText};

  @override
  bool operator ==(Object other) =>
      other is WidgetSnapshot &&
      other.balanceText == balanceText &&
      other.masked == masked &&
      other.updatedText == updatedText;

  @override
  int get hashCode => Object.hash(balanceText, masked, updatedText);
}

/// Computes what the widget must display from [db].
///
/// Owner decision: while an app-lock PIN is set the widget is ALWAYS masked
/// (`••••••` + `Terkunci`), without exception — the user can disable the lock
/// to see amounts. The in-app hide-balance toggle masks as well
/// (`Saldo disembunyikan`). The caption carries the date so a widget that
/// has not been refreshed for days does not look current. Pure data logic
/// (no platform calls), unit-testable on Linux; needs Indonesian date
/// symbols (`initializeDateFormatting(appLocale)`).
Future<WidgetSnapshot> computeWidgetSnapshot(AppDatabase db, {DateTime? now}) async {
  final settings = AppSettingsRepository(db);
  final pinHash = await settings.get(SettingKeys.pinHash);
  final pinSalt = await settings.get(SettingKeys.pinSalt);
  if ((pinHash?.isNotEmpty ?? false) && (pinSalt?.isNotEmpty ?? false)) {
    return const WidgetSnapshot(balanceText: widgetMaskedBalance, masked: true, updatedText: 'Terkunci');
  }
  if (await settings.getBool(SettingKeys.hideBalance)) {
    return const WidgetSnapshot(balanceText: widgetMaskedBalance, masked: true, updatedText: 'Saldo disembunyikan');
  }
  if (!await settings.getBool(SettingKeys.onboardingDone)) return WidgetSnapshot.notSetUp;

  final clock = now ?? DateTime.now();
  final total = await FinanceService(db, clock: () => clock).totalBalance();
  return WidgetSnapshot(
    balanceText: formatRupiah(total),
    masked: false,
    updatedText: 'Diperbarui ${formatDayShort(clock)} ${formatTime(clock)}',
  );
}

/// Sends [snapshot] to the Android side (`WidgetChannel.render`).
Future<void> renderWidget(WidgetSnapshot snapshot) =>
    widgetChannel.invokeMethod<void>('render', snapshot.toArguments());

/// Headless Dart entrypoint executed by `WidgetCompute` (Kotlin) for
/// system-triggered updates (widget placed, periodic update) when the app
/// itself may not be running. Registers the `refresh` handler, then computes
/// one snapshot immediately. While the app runs, `WidgetSync` renders from
/// the app's own connection instead.
@pragma('vm:entry-point')
Future<void> widgetBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await initializeDateFormatting(appLocale);
  widgetChannel.setMethodCallHandler((call) async {
    if (call.method == 'refresh') await _enqueueDiskRender();
    return null;
  });
  await _enqueueDiskRender();
}

Future<void> _diskQueue = Future.value();

/// Serializes headless computes so overlapping `refresh` calls never open
/// the database twice at once.
Future<void> _enqueueDiskRender() => _diskQueue = _diskQueue.then((_) => _renderFromDisk());

/// Opens the database file (never creates it), computes the snapshot and
/// hands it to Kotlin. Same DB-open pattern as `notificationBackgroundHandler`.
Future<void> _renderFromDisk() async {
  WidgetSnapshot snapshot;
  try {
    if (!await (await databaseFile()).exists()) {
      // Widget placed before the first app launch: opening would create and
      // seed a database outside the app's own startup.
      snapshot = WidgetSnapshot.notSetUp;
    } else {
      final db = await openDeviceDatabase();
      try {
        snapshot = await computeWidgetSnapshot(db);
      } finally {
        await db.close();
      }
    }
  } catch (_) {
    snapshot = WidgetSnapshot.unavailable;
  }
  try {
    await renderWidget(snapshot);
  } on PlatformException {
    // Kotlin side rejected the snapshot; it keeps its last masked state.
  } on MissingPluginException {
    // `render` handler missing on this engine; nothing else to do here.
  }
}
