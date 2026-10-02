import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../../backup/domain/integrity_check.dart';

final startupChecksProvider = Provider<StartupChecks>(
  (ref) => StartupChecks(
    db: ref.watch(databaseProvider),
    settings: ref.watch(appSettingsRepositoryProvider),
    attachmentsDir: AttachmentStorage.directory,
    sessionMarker: sessionMarkerFile,
  ),
);

/// Exists while a session is open; deleted on a clean pause/detach. Kept
/// outside the database so the per-resume/pause marker writes never notify
/// reactive queries.
Future<File> sessionMarkerFile() async =>
    File(p.join((await getApplicationSupportDirectory()).path, 'session_open'));

/// Integrity marker + checks after abnormal termination (09-security §8).
///
/// [run] is a lifecycle task (start + every resume): the first call of a
/// session runs the checks when the previous session never reached
/// [markCleanShutdown]; every call marks the session as open again.
class StartupChecks {
  StartupChecks({
    required this.db,
    required this.settings,
    required this.attachmentsDir,
    required this.sessionMarker,
  });

  final AppDatabase db;
  final AppSettingsRepository settings;
  final Future<Directory> Function() attachmentsDir;
  final Future<File> Function() sessionMarker;
  bool _checked = false;

  Future<void> run(DateTime now) async {
    final marker = await sessionMarker();
    final open = await marker.exists();
    if (!_checked) {
      _checked = true;
      if (open) {
        AppLogger.info('Sesi sebelumnya tidak ditutup normal; menjalankan integrity check');
        await checkNow(now, trigger: 'startup');
      }
    }
    if (!open) await marker.create(recursive: true);
  }

  /// Called when the app goes to paused/detached.
  Future<void> markCleanShutdown() async {
    final marker = await sessionMarker();
    if (await marker.exists()) await marker.delete();
  }

  /// Runs all checks now and stores the report for banners/log screen.
  Future<IntegrityReport> checkNow(DateTime now, {String trigger = 'manual'}) async {
    final report = await runIntegrityCheck(db, await attachmentsDir(), now: now, trigger: trigger);
    await saveIntegrityReport(settings, report);
    return report;
  }

  /// Hides the stored report (user acknowledged it).
  Future<void> dismissReport() => settings.remove(integrityReportKey);
}

const backupReminderDays = 30;

/// True when onboarding is done and the last backup is older than
/// [backupReminderDays] days (or there is none).
bool needsBackupReminder(Map<String, String> settings, DateTime now) {
  if (settings[SettingKeys.onboardingDone] != 'true') return false;
  final last = DateTime.tryParse(settings[SettingKeys.lastBackupAt] ?? '');
  return last == null || now.difference(last) > const Duration(days: backupReminderDays);
}

final backupReminderProvider = Provider<bool>(
  (ref) => needsBackupReminder(
    ref.watch(appSettingsProvider).value ?? const {},
    ref.watch(clockProvider)(),
  ),
);
