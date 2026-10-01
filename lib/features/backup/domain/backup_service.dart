import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../core/utilities/ids.dart';
import 'backup_manifest.dart';

export 'backup_manifest.dart';

/// `<app documents>/backups`, where every backup and safety snapshot is kept.
Future<Directory> defaultBackupsDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'backups'));
  await dir.create(recursive: true);
  return dir;
}

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    db: ref.watch(databaseProvider),
    attachmentsDir: AttachmentStorage.directory,
    backupsDir: defaultBackupsDirectory,
    workDir: getTemporaryDirectory,
  ),
);

/// Zip produced by [BackupService.buildPackage].
class BackupPackage {
  const BackupPackage({required this.fileName, required this.bytes, required this.manifest});
  final String fileName;
  final Uint8List bytes;
  final BackupManifest manifest;
}

/// A zip that passed [BackupService.validate]: manifest checked, sqlite hash
/// verified, every listed attachment present.
class ValidatedBackup {
  const ValidatedBackup({required this.manifest, required this.sqlite, required this.files});
  final BackupManifest manifest;
  final Uint8List sqlite;

  /// Zip entry name (`attachments/x.jpg`) → bytes.
  final Map<String, Uint8List> files;
}

/// Replaces the live database file; in the app this is
/// `(fn) => FinBroRoot.replaceDatabase(context, fn)`.
typedef DatabaseReplacer = Future<void> Function(Future<void> Function(File dbFile) replace);

/// Backup packaging, validation and restore (09-security §5–6). Directory
/// lookups are injected so the logic runs against temp dirs in tests.
class BackupService {
  BackupService({
    required this.db,
    required this.attachmentsDir,
    required this.backupsDir,
    required this.workDir,
  });

  final AppDatabase db;
  final Future<Directory> Function() attachmentsDir;
  final Future<Directory> Function() backupsDir;
  final Future<Directory> Function() workDir;

  static const backupPrefix = 'finbro-backup';
  static const safetyPrefix = 'safety-finbro-backup';
  static const _sqliteMagic = 'SQLite format 3\u0000';

  /// `finbro-backup-YYYY-MM-DD-HHmm.zip`.
  static String fileNameFor(DateTime t, {String prefix = backupPrefix}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix-${isoDate(t)}-${two(t.hour)}${two(t.minute)}.zip';
  }

  /// Consistent copy of the live DB (`VACUUM INTO`) + attachments + manifest.
  Future<BackupPackage> buildPackage(DateTime now, {String prefix = backupPrefix}) async {
    final work = await (await workDir()).createTemp('finbro-export-');
    try {
      final copy = File(p.join(work.path, BackupManifest.sqliteEntry));
      await db.customStatement('VACUUM INTO ?', [copy.path]);

      // Counts and attachment rows come from the copy so they match it exactly.
      final snapshot = _openSecondary(copy);
      late final int transactions;
      late final int accounts;
      late final List<Attachment> rows;
      try {
        transactions = await _count(snapshot, 'transactions');
        accounts = await _count(snapshot, 'accounts');
        rows = await snapshot.select(snapshot.attachments).get();
      } finally {
        await snapshot.close();
      }
      final sqlite = await copy.readAsBytes();

      final archive = Archive();
      final entryForPath = <String, String>{};
      final usedNames = <String>{};
      final attachmentFiles = <String, String>{};
      for (final row in rows) {
        final existing = entryForPath[row.localPath];
        if (existing != null) {
          attachmentFiles[row.id] = existing;
          continue;
        }
        final file = File(row.localPath);
        if (!await file.exists()) {
          AppLogger.error('Backup: file lampiran ${row.id} tidak ditemukan (${row.localPath})');
          continue;
        }
        var name = p.basename(row.localPath);
        if (!usedNames.add(name)) {
          name = '${row.id}_$name';
          usedNames.add(name);
        }
        final entry = '${BackupManifest.attachmentsFolder}/$name';
        archive.add(ArchiveFile.bytes(entry, await file.readAsBytes()));
        entryForPath[row.localPath] = entry;
        attachmentFiles[row.id] = entry;
      }

      final manifest = BackupManifest(
        schemaVersion: AppDatabase.currentSchemaVersion,
        createdAt: now,
        transactions: transactions,
        accounts: accounts,
        attachments: rows.length,
        sha256: crypto.sha256.convert(sqlite).toString(),
        attachmentFiles: attachmentFiles,
      );
      archive
        ..add(ArchiveFile.bytes(BackupManifest.sqliteEntry, sqlite))
        ..add(ArchiveFile.bytes(
          BackupManifest.entryName,
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson())),
        ));
      return BackupPackage(
        fileName: fileNameFor(now, prefix: prefix),
        bytes: ZipEncoder().encodeBytes(archive),
        manifest: manifest,
      );
    } finally {
      await _deleteQuietly(work);
    }
  }

  /// Builds a backup, keeps it in `backups/`, records it in the `backups`
  /// table and updates [SettingKeys.lastBackupAt].
  Future<({BackupPackage package, File file})> createBackup(DateTime now) async {
    final package = await buildPackage(now);
    final file = await _writeToBackups(package);
    await db.into(db.backups).insert(
      BackupsCompanion.insert(
        id: newId(),
        fileName: package.fileName,
        schemaVersion: '${package.manifest.schemaVersion}',
        createdAt: now,
        note: const Value('manual'),
      ),
    );
    await AppSettingsRepository(db).set(SettingKeys.lastBackupAt, isoLocal(now));
    AppLogger.info('Backup dibuat: ${package.fileName}');
    return (package: package, file: file);
  }

  /// Backup of the current data written to `backups/safety-…zip` right before
  /// a restore replaces it.
  Future<File> createSafetySnapshot(DateTime now) async {
    final package = await buildPackage(now, prefix: safetyPrefix);
    final file = await _writeToBackups(package);
    AppLogger.info('Safety snapshot dibuat: ${package.fileName}');
    return file;
  }

  /// Local backups and safety snapshots, newest first.
  Future<List<File>> localBackups() async {
    final dir = await backupsDir();
    if (!await dir.exists()) return const [];
    final files = [
      await for (final e in dir.list())
        if (e is File && e.path.toLowerCase().endsWith('.zip')) e,
    ];
    final stamps = {for (final f in files) f.path: await f.lastModified()};
    files.sort((a, b) => stamps[b.path]!.compareTo(stamps[a.path]!));
    return files;
  }

  /// Full restore flow after the user confirmed: safety snapshot first, then
  /// the database swap. Returns the snapshot file.
  Future<File> restore(
    ValidatedBackup backup, {
    required DateTime now,
    required DatabaseReplacer replaceDatabase,
  }) async {
    final snapshot = await createSafetySnapshot(now);
    // Resolve directories while the live DB is still open.
    final attachments = await attachmentsDir();
    final work = await workDir();
    await replaceDatabase(
      (dbFile) => installBackup(backup, dbFile: dbFile, attachmentsDir: attachments, workDir: work),
    );
    return snapshot;
  }

  /// Checks a backup zip. Throws [BackupException] with a user-facing reason
  /// for corrupted, foreign, tampered or newer-schema backups.
  static ValidatedBackup validate(
    Uint8List zipBytes, {
    int currentSchemaVersion = AppDatabase.currentSchemaVersion,
  }) {
    const corrupted = BackupException('File backup rusak atau bukan file ZIP FinBro.');
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    } catch (_) {
      throw corrupted;
    }
    Uint8List? read(String name) {
      final f = archive.findFile(name);
      if (f == null || !f.isFile) return null;
      try {
        return f.readBytes();
      } catch (_) {
        throw corrupted;
      }
    }

    final manifestBytes = read(BackupManifest.entryName);
    if (manifestBytes == null) {
      throw const BackupException('manifest.json tidak ditemukan. File ini bukan backup FinBro.');
    }
    final BackupManifest manifest;
    try {
      manifest = BackupManifest.fromJson(
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const BackupException('manifest.json rusak atau tidak lengkap.');
    }
    if (manifest.app != BackupManifest.appId) {
      throw const BackupException('File ini bukan backup FinBro.');
    }
    if (manifest.format != BackupManifest.currentFormat) {
      throw BackupException('Format backup ${manifest.format} tidak didukung versi aplikasi ini.');
    }
    if (manifest.schemaVersion < 1) {
      throw const BackupException('Versi skema pada backup tidak valid.');
    }
    if (manifest.schemaVersion > currentSchemaVersion) {
      throw BackupException(
        'Backup dibuat oleh versi FinBro yang lebih baru (skema ${manifest.schemaVersion}, '
        'aplikasi ini skema $currentSchemaVersion). Perbarui aplikasi sebelum restore.',
      );
    }
    final sqlite = read(BackupManifest.sqliteEntry);
    if (sqlite == null) {
      throw const BackupException('Database tidak ditemukan di dalam backup.');
    }
    if (crypto.sha256.convert(sqlite).toString() != manifest.sha256.toLowerCase()) {
      throw const BackupException('Checksum database tidak cocok. File backup rusak atau telah diubah.');
    }
    if (sqlite.length < 100 || String.fromCharCodes(sqlite.sublist(0, 16)) != _sqliteMagic) {
      throw const BackupException('Database di dalam backup bukan file SQLite yang valid.');
    }
    final files = <String, Uint8List>{};
    for (final entry in manifest.attachmentFiles.values.toSet()) {
      if (!_isSafeAttachmentEntry(entry)) {
        throw BackupException('Nama lampiran tidak valid: $entry');
      }
      final bytes = read(entry);
      if (bytes == null) {
        throw BackupException('Lampiran $entry hilang dari backup. File backup tidak lengkap.');
      }
      files[entry] = bytes;
    }
    return ValidatedBackup(manifest: manifest, sqlite: sqlite, files: files);
  }

  /// Swaps [dbFile] (which must be closed) for the backup database:
  /// 1. stage the sqlite in [workDir] and open it with [AppDatabase] so older
  ///    schemas migrate and `attachments.local_path` is rewritten to files
  ///    restored into [attachmentsDir];
  /// 2. reject a staged DB that fails `PRAGMA integrity_check`;
  /// 3. atomically replace [dbFile] and prune attachment files no restored
  ///    row references (the safety snapshot still holds the old ones).
  static Future<void> installBackup(
    ValidatedBackup backup, {
    required File dbFile,
    required Directory attachmentsDir,
    required Directory workDir,
  }) async {
    final stageDir = await workDir.createTemp('finbro-restore-');
    final created = <File>[];
    var swapped = false;
    try {
      final staged = File(p.join(stageDir.path, BackupManifest.sqliteEntry));
      await staged.writeAsBytes(backup.sqlite, flush: true);

      await attachmentsDir.create(recursive: true);
      final pathForEntry = <String, String>{};
      for (final e in backup.files.entries) {
        final target = File(p.join(attachmentsDir.path, p.basename(e.key)));
        if (!await target.exists()) created.add(target);
        await target.writeAsBytes(e.value, flush: true);
        pathForEntry[e.key] = target.path;
      }

      final referenced = <String>{};
      final stagedDb = _openSecondary(staged);
      try {
        final problems = await stagedDb.integrityProblems();
        final structural = problems.where((x) => x.startsWith('integrity:')).toList();
        if (structural.isNotEmpty) {
          throw BackupException('Database di dalam backup rusak: ${structural.first}');
        }
        await stagedDb.transaction(() async {
          for (final e in backup.manifest.attachmentFiles.entries) {
            final path = pathForEntry[e.value];
            if (path == null) continue;
            await (stagedDb.update(stagedDb.attachments)..where((a) => a.id.equals(e.key)))
                .write(AttachmentsCompanion(localPath: Value(path)));
          }
        });
        for (final a in await stagedDb.select(stagedDb.attachments).get()) {
          referenced.add(p.normalize(a.localPath));
        }
      } finally {
        await stagedDb.close();
      }

      for (final suffix in const ['-wal', '-shm', '-journal']) {
        await _deleteQuietly(File('${dbFile.path}$suffix'));
      }
      await dbFile.parent.create(recursive: true);
      final incoming = await staged.copy('${dbFile.path}.restoring');
      await incoming.rename(dbFile.path);
      swapped = true;

      await for (final e in attachmentsDir.list()) {
        if (e is File && !referenced.contains(p.normalize(e.path))) {
          await _deleteQuietly(e);
        }
      }
      AppLogger.info('Restore selesai dari backup ${isoLocal(backup.manifest.createdAt)}');
    } finally {
      if (!swapped) {
        // The old database stays; drop files this attempt added.
        for (final f in created) {
          await _deleteQuietly(f);
        }
      }
      await _deleteQuietly(stageDir);
    }
  }

  Future<File> _writeToBackups(BackupPackage package) async {
    final dir = await backupsDir();
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, package.fileName));
    return file.writeAsBytes(package.bytes, flush: true);
  }

  /// Opens a standalone file (export copy / restore stage) next to the live
  /// DB. Different files, so drift's "multiple instances" warning does not
  /// apply and is muted just for this construction.
  static AppDatabase _openSecondary(File file) {
    final previous = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    try {
      return AppDatabase(NativeDatabase(file));
    } finally {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = previous;
    }
  }

  static bool _isSafeAttachmentEntry(String entry) {
    if (!entry.startsWith('${BackupManifest.attachmentsFolder}/')) return false;
    final name = entry.substring(BackupManifest.attachmentsFolder.length + 1);
    return name.isNotEmpty && !name.contains('/') && !name.contains('\\') && name != '..' && name != '.';
  }

  static Future<int> _count(AppDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle()).read<int>('c');

  static Future<void> _deleteQuietly(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } catch (_) {}
  }
}
