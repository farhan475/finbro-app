import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../database/app_database.dart';
import '../settings/app_settings_repository.dart';
import '../utilities/app_logger.dart';

/// Payload kinds carried by notifications (JSON `{"kind": ..., ...}`).
abstract final class NotificationKind {
  static const dailyCheck = 'daily_check';
  static const budget = 'budget';
  static const recurring = 'recurring';
  static const monthlyReview = 'monthly_review';
}

/// Action ids (08-notification-calendar §2).
abstract final class NotificationAction {
  static const addTransaction = 'add_tx';
  static const noTransaction = 'no_tx';
  static const remindLater = 'remind_later';
}

/// Parsed tap/action from a notification.
class NotificationEvent {
  const NotificationEvent(this.kind, this.data, this.actionId);
  final String kind;
  final Map<String, dynamic> data;
  final String? actionId;

  /// Whether the notification was scheduled as an exact alarm (`exact` key).
  bool get exact => data['exact'] == true;

  static NotificationEvent? fromResponse(NotificationResponse r) {
    final p = r.payload;
    if (p == null || p.isEmpty) return null;
    try {
      final m = jsonDecode(p) as Map<String, dynamic>;
      return NotificationEvent(m['kind'] as String, m, r.actionId);
    } catch (_) {
      return null;
    }
  }
}

/// Stable notification ids. Android ids are 32-bit ints.
abstract final class NotificationIds {
  /// Daily check for a date: yyyyMMdd (e.g. 20260930).
  static int dailyCheck(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  /// One-shot "remind later" for a date.
  static int dailyCheckLater(DateTime d) => 100000000 + dailyCheck(d);

  /// Monthly review for a month: 30000000 + yyyyMM.
  static int monthlyReview(DateTime m) => 30000000 + m.year * 100 + m.month;

  /// Recurring instance reminder in [1_000_000, 9_999_999].
  static int recurring(String instanceId) => 1000000 + _hash(instanceId) % 9000000;

  /// Whether [id] is in the [recurring] range.
  static bool isRecurring(int id) => id >= 1000000 && id < 10000000;

  /// Budget alert in [100, 999_999].
  static int budget(String budgetId) => 100 + _hash(budgetId) % 999000;

  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}

// Private: on a secure lock screen Android shows only the generic system
// version ("FinBro", content hidden), never amounts or account names.
const _channelReminders = AndroidNotificationDetails(
  'finbro_reminders',
  'Pengingat',
  channelDescription: 'Daily check, recurring, dan monthly review',
  importance: Importance.defaultImportance,
  priority: Priority.defaultPriority,
  icon: 'ic_stat_finbro',
  visibility: NotificationVisibility.private,
);

const _channelAlerts = AndroidNotificationDetails(
  'finbro_budget',
  'Budget alert',
  channelDescription: 'Peringatan ambang budget',
  importance: Importance.high,
  priority: Priority.high,
  icon: 'ic_stat_finbro',
  visibility: NotificationVisibility.private,
);

const dailyCheckTitle = 'Daily check-in';
const dailyCheckBody =
    'Belum ada transaksi yang tercatat hari ini. Apakah memang tidak ada aktivitas keuangan?';

/// Payload of the daily check for [day] at [hour]:[minute]. The time and the
/// delivery mode are part of the payload so a pending request identifies its
/// schedule exactly.
Map<String, dynamic> dailyCheckPayload(
  DateTime day, {
  required int hour,
  required int minute,
  required bool exact,
}) => {
  'kind': NotificationKind.dailyCheck,
  'date': isoDate(day),
  'time': '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
  'exact': exact,
};

/// Whether reminders are scheduled as exact alarms: the "Pengingat tepat
/// waktu" setting is on (default) and Android currently allows exact alarms
/// (`SCHEDULE_EXACT_ALARM`). Otherwise they fall back to inexact alarms.
Future<bool> exactRemindersActive(AppSettingsRepository settings, NotificationService notifications) async =>
    await settings.getBool(SettingKeys.exactReminders, fallback: true) &&
    await notifications.canScheduleExact();

AndroidScheduleMode _scheduleMode(bool exact) =>
    exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;

/// Local notifications only (offline). Scheduling is a no-op on platforms
/// without zoned scheduling support (desktop dev builds).
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  final _initialized = Completer<void>();
  NotificationEvent? _launchEvent;

  bool get _canSchedule => !kIsWeb && Platform.isAndroid;

  /// Completes once [init] has finished (successfully or not). Schedule,
  /// cancel and launch-event reads are only meaningful afterwards.
  Future<void> get initialized => _initialized.future;

  Future<void> init({required void Function(NotificationEvent) onEvent}) async {
    try {
      await _init(onEvent);
    } finally {
      _initialized.complete();
    }
  }

  Future<void> _init(void Function(NotificationEvent) onEvent) async {
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (e) {
      AppLogger.error('Timezone lokal tidak terdeteksi, pakai UTC', e);
    }
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_finbro'),
          linux: LinuxInitializationSettings(defaultActionName: 'Buka'),
        ),
        onDidReceiveNotificationResponse: (r) {
          final e = NotificationEvent.fromResponse(r);
          if (e != null) onEvent(e);
        },
        onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
      );
      _ready = true;
      if (_canSchedule) {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp ?? false) {
          final r = launch!.notificationResponse;
          if (r != null) _launchEvent = NotificationEvent.fromResponse(r);
        }
      }
    } catch (e, s) {
      AppLogger.error('Inisialisasi notifikasi gagal', e, s);
    }
  }

  /// Event that cold-started the app, consumed once.
  NotificationEvent? takeLaunchEvent() {
    final e = _launchEvent;
    _launchEvent = null;
    return e;
  }

  Future<bool> requestPermission() async {
    if (!_canSchedule) return false;
    return await _android?.requestNotificationsPermission() ?? false;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Whether Android currently allows exact alarms (always true below
  /// Android 12; user-granted "Alarm & pengingat" from Android 14). False
  /// where scheduling is unavailable.
  Future<bool> canScheduleExact() async {
    if (!_ready || !_canSchedule) return false;
    try {
      return await _android?.canScheduleExactNotifications() ?? false;
    } catch (e, s) {
      AppLogger.error('Gagal membaca izin alarm tepat waktu', e, s);
      return false;
    }
  }

  /// Opens the system "Alarm & pengingat" screen for FinBro when exact
  /// alarms are not allowed yet; resolves to the resulting permission.
  Future<bool> requestExactPermission() async {
    if (!_ready || !_canSchedule) return false;
    try {
      return await _android?.requestExactAlarmsPermission() ?? false;
    } catch (e, s) {
      AppLogger.error('Gagal meminta izin alarm tepat waktu', e, s);
      return false;
    }
  }

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required Map<String, dynamic> payload,
    bool alert = false,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: jsonEncode(payload),
        notificationDetails: NotificationDetails(
          android: alert ? _channelAlerts : _channelReminders,
        ),
      );
    } catch (e, s) {
      AppLogger.error('Gagal menampilkan notifikasi', e, s);
    }
  }

  /// Schedules a one-shot notification at local [at]. Past times are ignored.
  /// [exact] uses an exact alarm (caller checked [canScheduleExact]).
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required Map<String, dynamic> payload,
    required bool exact,
    List<AndroidNotificationAction> actions = const [],
  }) async {
    if (!_ready || !_canSchedule || !at.isAfter(DateTime.now())) return;
    try {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        title: title,
        body: body,
        payload: jsonEncode(payload),
        androidScheduleMode: _scheduleMode(exact),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelReminders.channelId,
            _channelReminders.channelName,
            channelDescription: _channelReminders.channelDescription,
            icon: _channelReminders.icon,
            visibility: _channelReminders.visibility,
            styleInformation: BigTextStyleInformation(body),
            actions: actions,
          ),
        ),
      );
    } catch (e, s) {
      AppLogger.error('Gagal menjadwalkan notifikasi $id', e, s);
    }
  }

  /// Daily check for [day] at [time] with the three §2 actions.
  Future<void> scheduleDailyCheck(
    DateTime day, {
    required int hour,
    required int minute,
    required bool exact,
  }) => schedule(
    id: NotificationIds.dailyCheck(day),
    at: DateTime(day.year, day.month, day.day, hour, minute),
    title: dailyCheckTitle,
    body: dailyCheckBody,
    payload: dailyCheckPayload(day, hour: hour, minute: minute, exact: exact),
    exact: exact,
    actions: dailyCheckActions,
  );

  /// Cancels the daily check and any pending "remind later" for [day].
  Future<void> cancelDailyCheck(DateTime day) async {
    await cancel(NotificationIds.dailyCheck(day));
    await cancel(NotificationIds.dailyCheckLater(day));
  }

  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } catch (e, s) {
      AppLogger.error('Gagal membatalkan notifikasi $id', e, s);
    }
  }

  /// Pending scheduled notifications: id → encoded payload. One plugin call;
  /// empty where scheduling is unavailable.
  Future<Map<int, String?>> pendingPayloads() async {
    if (!_ready || !_canSchedule) return const {};
    try {
      return {for (final r in await _plugin.pendingNotificationRequests()) r.id: r.payload};
    } catch (e, s) {
      AppLogger.error('Gagal membaca notifikasi terjadwal', e, s);
      return const {};
    }
  }
}

const dailyCheckActions = [
  AndroidNotificationAction(
    NotificationAction.addTransaction,
    'Catat',
    showsUserInterface: true,
  ),
  AndroidNotificationAction(NotificationAction.noTransaction, 'Tidak ada'),
  AndroidNotificationAction(NotificationAction.remindLater, 'Nanti'),
];

/// Background isolate handler for actions that must not open the app:
/// "No transaction today" writes NO_ACTIVITY; "Remind later" schedules one
/// extra notification one hour later (only one, per test plan §3), exact
/// when the daily check itself was.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(NotificationResponse r) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    final e = NotificationEvent.fromResponse(r);
    if (e == null || e.kind != NotificationKind.dailyCheck) return;
    final day = DateTime.parse(e.data['date'] as String);
    if (e.actionId == NotificationAction.noTransaction) {
      final db = await openDeviceDatabase();
      try {
        await markNoActivity(db, day);
      } finally {
        await db.close();
      }
    } else if (e.actionId == NotificationAction.remindLater) {
      await scheduleRemindLater(day, exact: e.exact);
    }
  } catch (e, s) {
    // This isolate has no file logger; log into the app's log file directly.
    await AppLogger.init(await getApplicationSupportDirectory());
    AppLogger.error('Aksi notifikasi di latar belakang gagal', e, s);
  }
}

/// Writes NO_ACTIVITY for [day] unless it already has confirmed activity.
Future<void> markNoActivity(AppDatabase db, DateTime day) async {
  final existing = await (db.select(db.dailyActivity)
        ..where((d) => d.date.equalsValue(day)))
      .getSingleOrNull();
  if (existing?.status == ActivityStatus.active) return;
  await db.into(db.dailyActivity).insertOnConflictUpdate(
    DailyActivityCompanion.insert(
      date: day,
      status: ActivityStatus.noActivity,
      checkedAt: Value(DateTime.now()),
    ),
  );
}

/// Schedules the single "remind later" notification (+1 hour) for [day].
/// [exact] (the daily check's mode) is honoured only while Android still
/// allows exact alarms.
Future<void> scheduleRemindLater(DateTime day, {required bool exact}) async {
  tzdata.initializeTimeZones();
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(info.identifier));
  } catch (_) {}
  final plugin = FlutterLocalNotificationsPlugin();
  final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  final useExact = exact && (await android?.canScheduleExactNotifications() ?? false);
  final at = tz.TZDateTime.now(tz.local).add(const Duration(hours: 1));
  await plugin.zonedSchedule(
    id: NotificationIds.dailyCheckLater(day),
    scheduledDate: at,
    title: dailyCheckTitle,
    body: dailyCheckBody,
    payload: jsonEncode({'kind': NotificationKind.dailyCheck, 'date': isoDate(day)}),
    androidScheduleMode: _scheduleMode(useExact),
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'finbro_reminders',
        'Pengingat',
        icon: 'ic_stat_finbro',
        visibility: NotificationVisibility.private,
        // No "remind later" action here: remind later schedules only once.
        actions: [
          AndroidNotificationAction(
            NotificationAction.addTransaction,
            'Catat',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(NotificationAction.noTransaction, 'Tidak ada'),
        ],
      ),
    ),
  );
}
