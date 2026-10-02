import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../providers.dart';

/// Keys of the key/value `app_settings` table.
abstract final class SettingKeys {
  static const themeMode = 'theme_mode'; // system | light | dark
  static const onboardingDone = 'onboarding_done'; // true | false
  static const userName = 'user_name';
  static const dailyCheckEnabled = 'daily_check_enabled'; // true | false
  static const dailyCheckTime = 'daily_check_time'; // HH:mm, default 20:30
  static const monthlyReviewEnabled = 'monthly_review_enabled';
  static const budgetAlertsEnabled = 'budget_alerts_enabled';
  static const exactReminders = 'exact_reminders_enabled'; // true | false, default true
  static const pinHash = 'pin_hash';
  static const pinSalt = 'pin_salt';
  static const biometricEnabled = 'biometric_enabled';
  static const lockTimeoutSeconds = 'lock_timeout_seconds'; // default 60
  static const pinLimiter = 'pin_limiter'; // JSON {failures, until}; device-local
  static const lastBackupAt = 'last_backup_at'; // ISO local
  static const hideBalance = 'hide_balance'; // true | false (Home eye toggle)
  // Encrypted folder backup (device-local: never in backups, kept on restore).
  static const folderBackupUri = 'folder_backup_uri'; // SAF tree URI
  static const folderBackupName = 'folder_backup_name'; // folder display name
  static const folderBackupInterval = 'folder_backup_interval'; // daily | weekly, default daily
  static const folderBackupKeep = 'folder_backup_keep'; // files kept, default 7
  static const folderBackupLastAt = 'folder_backup_last_at'; // ISO local, last success
  static const folderBackupLastError = 'folder_backup_last_error'; // JSON {at, message}
}

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>(
  (ref) => AppSettingsRepository(ref.watch(databaseProvider)),
);

/// Reactive snapshot of all settings.
final appSettingsProvider = StreamProvider<Map<String, String>>(
  (ref) => ref.watch(appSettingsRepositoryProvider).watchAll(),
);

final themeModeProvider = Provider<ThemeMode>((ref) {
  final v = ref.watch(appSettingsProvider.select((s) => s.value?[SettingKeys.themeMode]));
  return switch (v) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
});

/// Trimmed user name ('' when unset). Rebuilds only when the name changes.
final userNameProvider = Provider<String>(
  (ref) => ref.watch(appSettingsProvider.select((s) => s.value?[SettingKeys.userName]))?.trim() ?? '',
);

/// Home eye toggle. Rebuilds only when the flag changes.
final hideBalanceProvider = Provider<bool>(
  (ref) => ref.watch(appSettingsProvider.select((s) => s.value?[SettingKeys.hideBalance] == 'true')),
);

class AppSettingsRepository {
  AppSettingsRepository(this.db);
  final AppDatabase db;

  Stream<Map<String, String>> watchAll() => db
      .select(db.appSettings)
      .watch()
      .map((rows) => {for (final r in rows) r.key: r.value});

  Future<String?> get(String key) async => (await (db.select(db.appSettings)
            ..where((s) => s.key.equals(key)))
          .getSingleOrNull())
      ?.value;

  Future<bool> getBool(String key, {bool fallback = false}) async {
    final v = await get(key);
    return v == null ? fallback : v == 'true';
  }

  Future<int> getInt(String key, {required int fallback}) async =>
      int.tryParse(await get(key) ?? '') ?? fallback;

  /// Upserts [key]; a no-op (no write, no stream/table notification) when
  /// the stored value is already [value].
  Future<void> set(String key, String value) => db.transaction(() async {
    if (await get(key) == value) return;
    await db.into(db.appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: key, value: value, updatedAt: DateTime.now()),
    );
  });

  Future<void> setBool(String key, bool value) => set(key, value.toString());

  Future<void> remove(String key) =>
      (db.delete(db.appSettings)..where((s) => s.key.equals(key))).go();
}

/// Parses `HH:mm`; falls back to [fallback].
TimeOfDay parseTimeOfDay(String? v, {TimeOfDay fallback = const TimeOfDay(hour: 20, minute: 30)}) {
  final parts = v?.split(':');
  if (parts == null || parts.length != 2) return fallback;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h > 23 || m > 59) return fallback;
  return TimeOfDay(hour: h, minute: m);
}

String formatTimeOfDay(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
