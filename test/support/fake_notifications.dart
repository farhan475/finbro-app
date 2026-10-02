import 'dart:convert';

import 'package:finbro_app/core/notifications/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// In-memory stand-in for the plugin-backed [NotificationService]: tracks the
/// pending schedule (id → encoded payload, id → exact alarm) and counts
/// plugin-level calls. [exactAllowed] plays Android's exact-alarm permission.
class FakeNotifications implements NotificationService {
  final pending = <int, String?>{};
  final exact = <int, bool>{};
  final scheduled = <int>[];
  final cancelled = <int>[];
  bool exactAllowed = true;

  int get pluginCalls => scheduled.length + cancelled.length;

  void resetCalls() {
    scheduled.clear();
    cancelled.clear();
  }

  @override
  Future<Map<int, String?>> pendingPayloads() async => Map.of(pending);

  @override
  Future<bool> canScheduleExact() async => exactAllowed;

  @override
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required Map<String, dynamic> payload,
    required bool exact,
    List<AndroidNotificationAction> actions = const [],
  }) async {
    scheduled.add(id);
    pending[id] = jsonEncode(payload);
    this.exact[id] = exact;
  }

  @override
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
  );

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    pending.remove(id);
    exact.remove(id);
  }

  @override
  Future<void> cancelDailyCheck(DateTime day) async {
    await cancel(NotificationIds.dailyCheck(day));
    await cancel(NotificationIds.dailyCheckLater(day));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
