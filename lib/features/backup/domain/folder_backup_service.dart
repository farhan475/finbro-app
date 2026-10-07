import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../core/utilities/ids.dart';
import 'backup_service.dart';
import 'encrypted_backup.dart';

/// Where the derived backup key lives (Android Keystore-backed storage in
/// the app). Never part of a backup.
abstract interface class BackupKeyStore {
  Future<BackupKey?> read();
  Future<void> write(BackupKey key);
  Future<void> delete();
}

/// A file inside the backup folder.
class FolderEntry {
  const FolderEntry({required this.uri, required this.name});
  final String uri;
  final String name;
}

/// The user-chosen folder (Android SAF tree with persisted permission).
abstract interface class BackupFolderAccess {
  /// Opens the system folder picker and persists read/write permission.
  /// Null when the user cancelled.
  Future<({String uri, String name})?> pick();

  /// Whether the persisted read/write permission for [treeUri] still exists.
  Future<bool> canWrite(String treeUri);

  Future<List<FolderEntry>> list(String treeUri);

  /// Copies [source] into the folder as [fileName]; returns the stored name.
  Future<String> write(String treeUri, String fileName, File source);

  Future<void> delete(String uri);

  Future<void> release(String treeUri);
}

enum BackupInterval {
  daily('daily', 'Harian'),
  weekly('weekly', 'Mingguan');

  const BackupInterval(this.id, this.label);
  final String id;
  final String label;

  static BackupInterval parse(String? v) => v == weekly.id ? weekly : daily;
}

/// Folder backup settings and outcome, read from `app_settings`.
class FolderBackupStatus {
  const FolderBackupStatus({
    this.folderUri,
    this.folderName,
    this.interval = BackupInterval.daily,
    this.keep = FolderBackupService.defaultKeep,
    this.lastSuccessAt,
    this.lastErrorAt,
    this.lastError,
  });

  factory FolderBackupStatus.fromSettings(Map<String, String> s) {
    DateTime? errorAt;
    String? error;
    final rawError = s[SettingKeys.folderBackupLastError];
    if (rawError != null) {
      try {
        final j = jsonDecode(rawError) as Map<String, dynamic>;
        errorAt = DateTime.parse(j['at'] as String);
        error = j['message'] as String;
      } catch (_) {}
    }
    final keep = int.tryParse(s[SettingKeys.folderBackupKeep] ?? '');
    return FolderBackupStatus(
      folderUri: s[SettingKeys.folderBackupUri],
      folderName: s[SettingKeys.folderBackupName],
      interval: BackupInterval.parse(s[SettingKeys.folderBackupInterval]),
      keep: keep != null && keep >= 1 ? keep : FolderBackupService.defaultKeep,
      lastSuccessAt: DateTime.tryParse(s[SettingKeys.folderBackupLastAt] ?? ''),
      lastErrorAt: errorAt,
      lastError: error,
    );
  }

  final String? folderUri;
  final String? folderName;
  final BackupInterval interval;
  final int keep;
  final DateTime? lastSuccessAt;
  final DateTime? lastErrorAt;
  final String? lastError;

  bool get hasFolder => folderUri != null;

  /// The last attempt failed (error newer than the last success).
  bool get failing =>
      lastErrorAt != null && (lastSuccessAt == null || lastErrorAt!.isAfter(lastSuccessAt!));
}

/// Encrypted backups written to the user's folder: automatically from the
/// lifecycle task when due, or on demand. Only files named
/// `finbro-YYYYMMDD-HHmmss.finbro` are ever pruned.
class FolderBackupService {
  FolderBackupService({
    required this.db,
    required this.backups,
    required this.keys,
    required this.folder,
    required this.workDir,
  });

  final AppDatabase db;
  final BackupService backups;
  final BackupKeyStore keys;
  final BackupFolderAccess folder;
  final Future<Directory> Function() workDir;

  static const defaultKeep = 7;
  static const keepChoices = [3, 5, 7, 14, 30];

  /// After a failed automatic attempt, wait this long before trying again on
  /// resume (a full backup is too costly to repeat on every resume).
  static const retryAfterFailure = Duration(hours: 1);

  static const permissionLostMessage =
      'Izin akses folder backup hilang. Pilih ulang folder di Backup & Restore.';
  static const noKeyMessage =
      'Passphrase backup belum diatur di perangkat ini. Atur passphrase di Backup & Restore.';
  static const noFolderMessage = 'Folder backup belum dipilih.';

  static final fileNamePattern = RegExp(r'^finbro-\d{8}-\d{6}\.finbro$');

  /// Suffix of a backup still being copied into the folder; leftovers of an
  /// interrupted copy are removed by the next successful backup.
  static const partialSuffix = '.partial';
  static final partialNamePattern = RegExp(r'^finbro-\d{8}-\d{6}\.finbro\.partial$');

  /// `finbro-YYYYMMDD-HHmmss.finbro` in local time.
  static String fileNameFor(DateTime t) {
    final l = t.isUtc ? t.toLocal() : t;
    String two(int v) => v.toString().padLeft(2, '0');
    return 'finbro-${l.year.toString().padLeft(4, '0')}${two(l.month)}${two(l.day)}'
        '-${two(l.hour)}${two(l.minute)}${two(l.second)}${EncryptedBackup.extension}';
  }

  /// Whether a backup is due at [now]: never backed up, daily and not yet
  /// today, weekly and at least 7 calendar days since, or the last backup
  /// lies in the future (clock was changed).
  static bool isDue(DateTime? last, DateTime now, BackupInterval interval) {
    if (last == null || last.isAfter(now)) return true;
    // Calendar days in UTC arithmetic, so DST shifts never skew the count.
    final days = DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(last.year, last.month, last.day))
        .inDays;
    return switch (interval) {
      BackupInterval.daily => days >= 1,
      BackupInterval.weekly => days >= 7,
    };
  }

  /// Names to delete so that the newest [keep] FinBro backups remain. Only
  /// names matching [fileNamePattern] are considered; [justWritten] is
  /// always kept (it counts towards [keep]).
  static List<String> retentionVictims(Iterable<String> names, int keep, {String? justWritten}) {
    final ours = names.where(fileNamePattern.hasMatch).toSet().toList()
      ..sort((a, b) => b.compareTo(a)); // the timestamp sorts lexically
    final kept = <String>{if (justWritten != null && ours.contains(justWritten)) justWritten};
    for (final n in ours) {
      if (kept.length >= keep) break;
      kept.add(n);
    }
    return [for (final n in ours) if (!kept.contains(n)) n];
  }

  AppSettingsRepository get _settings => AppSettingsRepository(db);

  Future<FolderBackupStatus> status() async {
    final rows = await db.select(db.appSettings).get();
    return FolderBackupStatus.fromSettings({for (final r in rows) r.key: r.value});
  }

  Future<void> setFolder(String uri, String name) async {
    final old = (await status()).folderUri;
    await _settings.set(SettingKeys.folderBackupUri, uri);
    await _settings.set(SettingKeys.folderBackupName, name);
    await _settings.remove(SettingKeys.folderBackupLastError);
    if (old != null && old != uri) await _release(old);
  }

  /// Stops folder backups; files already in the folder stay.
  Future<void> clearFolder() async {
    final old = (await status()).folderUri;
    for (final k in [SettingKeys.folderBackupUri, SettingKeys.folderBackupName, SettingKeys.folderBackupLastError]) {
      await _settings.remove(k);
    }
    if (old != null) await _release(old);
  }

  Future<void> setInterval(BackupInterval interval) =>
      _settings.set(SettingKeys.folderBackupInterval, interval.id);

  Future<void> setKeep(int keep) => _settings.set(SettingKeys.folderBackupKeep, '$keep');

  /// Stores the key for future backups (a new passphrase); a recorded
  /// failure (e.g. [noKeyMessage]) no longer applies.
  Future<void> setKey(BackupKey key) async {
    await keys.write(key);
    await _settings.remove(SettingKeys.folderBackupLastError);
  }

  /// Turns folder backups off: releases the folder and deletes the key from
  /// this device. Files already in the folder stay (still openable with
  /// their passphrase).
  Future<void> disable() async {
    await clearFolder();
    await keys.delete();
  }

  Future<String>? _inFlight;

  /// Lifecycle task: starts [runIfDue] without waiting for it, so app start
  /// and resume are never held up by a backup.
  Future<void> onLifecycle(DateTime now) async {
    unawaited(runIfDue(now).catchError((Object e, StackTrace s) {
      AppLogger.error('Backup folder otomatis gagal', e, s);
      return null;
    }));
  }

  /// Writes a backup when a folder is chosen and the interval has passed.
  /// Returns the written file name, or null when nothing was due.
  Future<String?> runIfDue(DateTime now) async {
    if (_inFlight != null) return null;
    final s = await status();
    if (!s.hasFolder || !isDue(s.lastSuccessAt, now, s.interval)) return null;
    final errorAt = s.lastErrorAt;
    if (s.failing && errorAt != null && !errorAt.isAfter(now) && now.difference(errorAt) < retryAfterFailure) {
      return null;
    }
    try {
      return await backupNow(now);
    } on BackupException {
      return null; // recorded in the status
    }
  }

  /// Builds, encrypts and writes a backup to the folder, then prunes old
  /// FinBro files. Concurrent calls share one run. Failures are recorded in
  /// the status and rethrown as [BackupException].
  Future<String> backupNow(DateTime now) => _inFlight ??= _backup(now).whenComplete(() => _inFlight = null);

  Future<String> _backup(DateTime now) async {
    try {
      final s = await status();
      final uri = s.folderUri;
      if (uri == null) throw const BackupException(noFolderMessage);
      final key = await keys.read();
      if (key == null) throw const BackupException(noKeyMessage);
      if (!await folder.canWrite(uri)) throw const BackupException(permissionLostMessage);

      final package = await backups.buildPackage(now);
      final String written;
      try {
        final name = fileNameFor(now);
        final work = await (await workDir()).createTemp('finbro-folder-');
        try {
          final file = File(p.join(work.path, name));
          await EncryptedBackup.encrypt(package.file, file, key);
          written = await folder.write(uri, name, file);
        } finally {
          try {
            await work.delete(recursive: true);
          } catch (_) {}
        }
      } finally {
        await package.dispose();
      }
      await _prune(uri, s.keep, written);

      await _settings.set(SettingKeys.folderBackupLastAt, isoLocal(now));
      await _settings.remove(SettingKeys.folderBackupLastError);
      await _settings.set(SettingKeys.lastBackupAt, isoLocal(now));
      await db.into(db.backups).insert(
        BackupsCompanion.insert(
          id: newId(),
          fileName: written,
          schemaVersion: '${package.manifest.schemaVersion}',
          createdAt: now,
          note: const Value('folder'),
        ),
      );
      AppLogger.info('Backup terenkripsi ditulis ke folder: $written');
      return written;
    } catch (e, s) {
      final message = e is BackupException ? e.message : 'Menulis backup ke folder gagal';
      AppLogger.error('Backup folder gagal', e, s);
      try {
        await _settings.set(
          SettingKeys.folderBackupLastError,
          jsonEncode({'at': isoLocal(now), 'message': message}),
        );
      } catch (e2, s2) {
        AppLogger.error('Mencatat status backup folder gagal', e2, s2);
      }
      throw BackupException(message);
    }
  }

  /// Deletes FinBro files beyond [keep]; a failed delete is logged only (the
  /// backup itself succeeded).
  Future<void> _prune(String uri, int keep, String written) async {
    try {
      final entries = await folder.list(uri);
      final victims = retentionVictims(entries.map((e) => e.name), keep, justWritten: written).toSet();
      for (final e in entries) {
        if (!victims.contains(e.name) && !partialNamePattern.hasMatch(e.name)) continue;
        try {
          await folder.delete(e.uri);
        } catch (err, s) {
          AppLogger.error('Menghapus backup lama ${e.name} gagal', err, s);
        }
      }
    } catch (e, s) {
      AppLogger.error('Membaca isi folder backup gagal', e, s);
    }
  }

  Future<void> _release(String uri) async {
    try {
      await folder.release(uri);
    } catch (e, s) {
      AppLogger.error('Melepas izin folder lama gagal', e, s);
    }
  }
}
