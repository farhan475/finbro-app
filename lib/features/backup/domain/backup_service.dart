import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/backends.dart' show QueryExecutor, QueryExecutorUser;
import 'package:drift/drift.dart' show OpeningDetails, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
 
import '../../../core/database/app_database.dart';
import '../../../core/database/database_cipher.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../core/utilities/ids.dart';
import 'backup_manifest.dart';
import 'integrity_check.dart' show integrityReportKey;

export 'backup_manifest.dart';

/// Settings that describe this device, not the data: stripped from every
/// backup and kept as they are on the device when a backup is restored.
const deviceLocalSettingKeys = <String>[
  SettingKeys.pinHash,
  SettingKeys.pinSalt,
  SettingKeys.biometricEnabled,
  SettingKeys.lockTimeoutSeconds,
  SettingKeys.pinLimiter,
  integrityReportKey,
  // The folder permission and its backup history belong to this device.
  SettingKeys.folderBackupUri,
  SettingKeys.folderBackupName,
  SettingKeys.folderBackupInterval,
  SettingKeys.folderBackupKeep,
  SettingKeys.folderBackupLastAt,
  SettingKeys.folderBackupLastError,
];

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

/// Zip produced by [BackupService.buildPackage]; file-backed, never held in
/// memory as a whole.
class BackupPackage {
  const BackupPackage({required this.fileName, required this.file, required this.manifest});
  final String fileName;
  final File file;
  final BackupManifest manifest;

  Future<void> dispose() async { try { await file.delete(); } catch (_) {} }
}

/// A file-backed ZIP that passed [BackupService.validateFile].
class ValidatedBackup {
  const ValidatedBackup({required this.manifest, required this.sqliteFile, required this.files, this.ownedDirectory});
  final BackupManifest manifest;
  final File sqliteFile;
  final Map<String, File> files;
  final Directory? ownedDirectory;

  Future<void> dispose() async { if (ownedDirectory != null) { try { await ownedDirectory!.delete(recursive: true); } catch (_) {} } }
}

/// Replaces the live database (file + device key); in the app this is
/// `(fn) => FinBroRoot.replaceDatabase(context, fn)`.
typedef DatabaseReplacer = Future<void> Function(Future<void> Function(DeviceDatabase live) replace);

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
  static const _mb = 1024 * 1024;

  /// Largest backup zip accepted for restore; checked before it is read.
  static const maxBackupBytes = 512 * _mb;

  /// Largest single zip entry (database or attachment) once unpacked.
  static const maxEntryBytes = 256 * _mb;

  /// Largest total of all zip entries once unpacked (zip-bomb guard).
  static const maxUnpackedBytes = 1024 * _mb;

  static const oversizeMessage =
      'File backup terlalu besar (maksimal ${maxBackupBytes ~/ _mb} MB). Pilih file backup FinBro lain.';

  /// `finbro-backup-YYYY-MM-DD-HHmm.zip`.
  static String fileNameFor(DateTime t, {String prefix = backupPrefix}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix-${isoDate(t)}-${two(t.hour)}${two(t.minute)}.zip';
  }

  /// Consistent plaintext copy of the live DB ([_exportPlaintext]) +
  /// attachments + manifest. The ZIP is written in a background isolate,
  /// streamed to a temporary file in fixed-size chunks; CRC32 and SHA-256 are
  /// computed during the copy.
  Future<BackupPackage> buildPackage(
    DateTime now, {
    String prefix = backupPrefix,
    int zipLimit = maxBackupBytes,
    int entryLimit = maxEntryBytes,
    int totalLimit = maxUnpackedBytes,
  }) async {
    final work = await (await workDir()).createTemp('finbro-export-');
    final archiveFile = File(p.join(work.parent.path, 'finbro-archive-${newId()}.zip'));
    try {
      final copy = File(p.join(work.path, BackupManifest.sqliteEntry));
      await _exportPlaintext(db, copy);
      final snapshot = _openSecondary(copy);
      late final int transactions;
      late final int accounts;
      late final List<Attachment> rows;
      try {
        await (snapshot.delete(snapshot.appSettings)..where((s) => s.key.isIn(deviceLocalSettingKeys))).go();
        transactions = await _count(snapshot, 'transactions');
        accounts = await _count(snapshot, 'accounts');
        rows = await snapshot.select(snapshot.attachments).get();
      } finally { await snapshot.close(); }
      final attachmentsRoot = (await attachmentsDir()).path;
      final entryPaths = <String, String>{};
      final entryForPath = <String, String>{};
      final usedNames = <String>{};
      final attachmentFiles = <String, String>{};
      for (final row in rows) {
        final existing = entryForPath[row.localPath];
        if (existing != null) { attachmentFiles[row.id] = existing; continue; }
        if (!AttachmentStorage.isWithin(attachmentsRoot, row.localPath)) continue;
        final file = File(row.localPath);
        if (!await file.exists()) continue;
        var name = p.basename(row.localPath);
        if (!usedNames.add(name)) { name = '${row.id}_$name'; usedNames.add(name); }
        final entry = '${BackupManifest.attachmentsFolder}/$name';
        entryPaths[entry] = row.localPath;
        entryForPath[row.localPath] = entry;
        attachmentFiles[row.id] = entry;
      }
      final manifest = await _writePackageInIsolate(
        archivePath: archiveFile.path,
        attachments: entryPaths,
        sqlitePath: copy.path,
        info: (
          createdAt: now,
          transactions: transactions,
          accounts: accounts,
          attachments: rows.length,
          attachmentFiles: attachmentFiles,
        ),
        zipLimit: zipLimit,
        entryLimit: entryLimit,
        totalLimit: totalLimit,
      );
      return BackupPackage(fileName: fileNameFor(now, prefix: prefix), file: archiveFile, manifest: manifest);
    } catch (e) {
      try { await archiveFile.delete(); } catch (_) {}
      await _deleteQuietly(work);
      rethrow;
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
        fileName: p.basename(file.path),
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
    await pruneSafetySnapshots(now, protect: file.path);
    AppLogger.info('Safety snapshot dibuat: ${package.fileName}');
    return file;
  }

  /// Safety snapshots are emergency copies made right before a restore; once
  /// a restore has finished safely, older ones have no recovery value and
  /// only grow the app storage. Deletes all but the newest [keep] safety
  /// snapshots ([protect], the snapshot just written, counts towards [keep]
  /// and is never deleted); returns the deleted paths. Never throws:
  /// retention must not break the restore that created it.
  Future<List<String>> pruneSafetySnapshots(DateTime now, {int keep = 2, String? protect}) async {
    final deleted = <String>[];
    try {
      final dir = await backupsDir();
      if (!await dir.exists()) return deleted;
      final snapshots = <String, DateTime>{};
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.startsWith(safetyPrefix) || !name.toLowerCase().endsWith('.zip')) continue;
        snapshots[p.canonicalize(e.path)] = await e.lastModified();
      }
      final protectedPath = protect == null ? null : p.canonicalize(protect);
      if (protectedPath != null && !snapshots.containsKey(protectedPath)) {
        final f = File(protect!);
        if (f.existsSync()) snapshots[protectedPath] = f.lastModifiedSync();
      }
      final newest = snapshots.keys.toList()
        ..sort((a, b) => snapshots[b]!.compareTo(snapshots[a]!));
      for (final path in newest.skip(keep)) {
        if (path == protectedPath) continue;
        try {
          await File(path).delete();
          deleted.add(path);
        } catch (e, s) {
          AppLogger.error('Menghapus snapshot lama gagal: ${p.basename(path)}', e, s);
        }
      }
      if (deleted.isNotEmpty) {
        AppLogger.info('Retensi safety snapshot: ${deleted.length} dihapus');
      }
    } catch (e, s) {
      AppLogger.error('Retensi safety snapshot gagal', e, s);
    }
    return deleted;
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
    // The restored DB carries the settings of its own past, so it would
    // forget backups made since (and the backup itself was written after its
    // export copy). Keep the newer of the live value and the backup date.
    final live = DateTime.tryParse(await AppSettingsRepository(db).get(SettingKeys.lastBackupAt) ?? '');
    final created = backup.manifest.createdAt;
    final lastBackupAt = live != null && live.isAfter(created) ? live : created;
    // Resolve directories while the live DB is still open.
    final attachments = await attachmentsDir();
    final work = await workDir();
    final deviceSettings = <String, String>{};
    final settings = AppSettingsRepository(db);
    for (final key in deviceLocalSettingKeys) {
      if (key == integrityReportKey) continue; // describes the old data, not the device
      final v = await settings.get(key);
      if (v != null) deviceSettings[key] = v;
    }
    await replaceDatabase(
      (live) => installBackup(
        backup,
        dbFile: live.file,
        key: live.key,
        attachmentsDir: attachments,
        workDir: work,
        lastBackupAt: lastBackupAt,
        deviceSettings: deviceSettings,
      ),
    );
    return snapshot;
  }

  /// Validates a file-backed ZIP and stages its entries in a temporary
  /// directory. Runs in a background isolate; every entry is streamed to its
  /// staged file in fixed-size chunks while its size, CRC32 and SHA-256 are
  /// checked, so memory does not grow with the backup or entry size.
  static Future<ValidatedBackup> validateFile(
    File zipFile, {
    Future<Directory> Function()? workDir,
    int currentSchemaVersion = AppDatabase.currentSchemaVersion,
    int entryLimit = maxEntryBytes,
    int totalLimit = maxUnpackedBytes,
  }) async {
    if (!await zipFile.exists() || await zipFile.length() > maxBackupBytes) {
      throw const BackupException(oversizeMessage);
    }
    final root = await (workDir ?? getTemporaryDirectory)();
    final owned = await root.createTemp('finbro-validated-');
    try {
      final staged = await _validateInIsolate(
        zipPath: zipFile.path,
        outDir: owned.path,
        currentSchemaVersion: currentSchemaVersion,
        entryLimit: entryLimit,
        totalLimit: totalLimit,
      );
      return ValidatedBackup(
        manifest: staged.manifest,
        sqliteFile: File(staged.sqlitePath),
        files: {for (final e in staged.files.entries) e.key: File(e.value)},
        ownedDirectory: owned,
      );
    } catch (_) { await _deleteQuietly(owned); rethrow; }
  }

  /// Swaps [dbFile] (which must be closed) for the backup database:
  /// 1. stage the sqlite in [workDir] and, on a plain connection before any
  ///    migration runs, check its `user_version` and tables and drop every
  ///    trigger and view (the file is untrusted; see [_sanitizeStaged]);
  /// 2. open it with [AppDatabase] so older schemas migrate and
  ///    `attachments.local_path` is rewritten to files restored into
  ///    [attachmentsDir];
  /// 3. reject a staged DB that fails `PRAGMA integrity_check`;
  /// 4. encrypt it with this device's [key] into a verified copy next to
  ///    [dbFile] ([exportDatabase]), so the plaintext backup never becomes
  ///    the live file;
  /// 5. atomically replace [dbFile] and prune attachment files no restored
  ///    row references (the safety snapshot still holds the old ones).
  static Future<void> installBackup(
    ValidatedBackup backup, {
    required File dbFile,
    required DatabaseKey key,
    required Directory attachmentsDir,
    required Directory workDir,
    DateTime? lastBackupAt,
    Map<String, String> deviceSettings = const {},
  }) async {
    final stageDir = await workDir.createTemp('finbro-restore-');
    final created = <File>[];
    var swapped = false;
    try {
      final staged = File(p.join(stageDir.path, BackupManifest.sqliteEntry));
      await backup.sqliteFile.copy(staged.path);

      await attachmentsDir.create(recursive: true);
      final pathForEntry = <String, String>{};
      for (final e in backup.files.entries) {
        final target = File(p.join(attachmentsDir.path, p.basename(e.key)));
        if (!await target.exists()) created.add(target);
        await e.value.copy(target.path);
        pathForEntry[e.key] = target.path;
      }

      final referenced = <String>{};
      final stagedDb = _openSecondary(staged);
      try {
        // stagedDb is not opened yet (drift opens lazily on the first query).
        await _sanitizeStaged(
          staged,
          // Old backups (pre-v5) legitimately lack tables added by later
          // migration steps; the migration recreates them on install.
          expectedTables: {
            for (final t in stagedDb.allTables)
              if (_tableExistsAt(t.actualTableName, backup.manifest.schemaVersion)) t.actualTableName,
          },
          manifestSchemaVersion: backup.manifest.schemaVersion,
        );
        final problems = await stagedDb.integrityProblems();
        final structural = problems.where((x) => x.startsWith('integrity:')).toList();
        if (structural.isNotEmpty) {
          throw BackupException('Database di dalam backup rusak: ${structural.first}');
        }
        await stagedDb.transaction(() async {
          final restoredIds = <String>{};
          for (final e in backup.manifest.attachmentFiles.entries) {
            final path = pathForEntry[e.value];
            if (path == null) continue;
            restoredIds.add(e.key);
            await (stagedDb.update(stagedDb.attachments)..where((a) => a.id.equals(e.key))).write(
              AttachmentsCompanion(
                localPath: Value(path),
                // The checksum of the packaged file; integrity check later
                // compares it against the restored file on disk.
                fileSha256: Value(backup.manifest.attachmentChecksums[e.value]),
              ),
            );
          }
          // The backup DB is untrusted: a row whose file did not come from the
          // zip could point anywhere (later deleted or re-backed-up). Point it
          // at a not-yet-existing file inside the attachments folder.
          for (final a in await stagedDb.select(stagedDb.attachments).get()) {
            if (restoredIds.contains(a.id)) continue;
            await (stagedDb.update(stagedDb.attachments)..where((x) => x.id.equals(a.id))).write(
              AttachmentsCompanion(localPath: Value(p.join(attachmentsDir.path, 'missing-${a.id}'))),
            );
          }
          // Lock settings belong to this device, never to the backup.
          await (stagedDb.delete(stagedDb.appSettings)..where((s) => s.key.isIn(deviceLocalSettingKeys))).go();
          for (final e in deviceSettings.entries) {
            await AppSettingsRepository(stagedDb).set(e.key, e.value);
          }
          if (lastBackupAt != null) {
            await AppSettingsRepository(stagedDb).set(SettingKeys.lastBackupAt, isoLocal(lastBackupAt));
          }
        });
        for (final a in await stagedDb.select(stagedDb.attachments).get()) {
          referenced.add(p.normalize(a.localPath));
        }
      } finally {
        await stagedDb.close();
      }

      await dbFile.parent.create(recursive: true);
      final incoming = File('${dbFile.path}.restoring');
      await exportDatabase(source: staged, target: incoming, targetKey: key);
      for (final suffix in const ['-wal', '-shm', '-journal']) {
        await _deleteQuietly(File('${dbFile.path}$suffix'));
      }
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

  /// Writes [package] under its own name, or `-2`, `-3`, … when that file
  /// exists, so a backup or safety snapshot never overwrites an earlier one
  /// (two restores within a minute must keep the original data).
  Future<File> _writeToBackups(BackupPackage package) async {
    final dir = await backupsDir();
    await dir.create(recursive: true);
    final base = p.basenameWithoutExtension(package.fileName);
    var file = File(p.join(dir.path, package.fileName));
    for (var n = 2; await file.exists(); n++) {
      file = File(p.join(dir.path, '$base-$n.zip'));
    }
    await package.file.copy(file.path);
    await package.dispose();
    return file;
  }

  /// Opens a standalone file (export copy / restore stage) next to the live
  /// DB. Different files, so drift's "multiple instances" warning does not
  /// apply and is muted just for this construction.
  ///
  /// Tables added in a schema version later than [schemaVersion] are not
  /// expected inside a backup made by that older app version (the migration
  /// recreates them on install). Keyed on the actual SQLite table name.
  static bool _tableExistsAt(String tableName, int schemaVersion) {
    // Schema v5 added exchange_rates (manual kurs).
    if (tableName == 'exchange_rates') return schemaVersion >= 5;
    return true;
  }

  static AppDatabase _openSecondary(File file) {
    final previous = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    try {
      return AppDatabase(NativeDatabase(file));
    } finally {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = previous;
    }
  }

  /// Writes a plaintext SQLite copy of [db] to [target]: the live database
  /// is SQLCipher-encrypted with a device-bound key, but backups must restore
  /// on any device. `sqlcipher_export` into a database attached without a key,
  /// in one transaction so the copy is consistent; exclusive so no other query
  /// of this connection runs while the copy is attached.
  static Future<void> _exportPlaintext(AppDatabase db, File target) => db.exclusively(() async {
    await db.customStatement("ATTACH DATABASE ? AS finbro_export KEY ''", [target.path]);
    try {
      await db.transaction(() async {
        final version = (await db.customSelect('PRAGMA main.user_version').getSingle()).data.values.single as int;
        await db.customSelect("SELECT sqlcipher_export('finbro_export')").get();
        // sqlcipher_export copies schema and rows, not the schema version.
        await db.customStatement('PRAGMA finbro_export.user_version = $version');
      });
    } finally {
      await db.customStatement('DETACH DATABASE finbro_export');
    }
  });

  /// Checks the untrusted restored database on a plain connection, before
  /// [AppDatabase] runs migrations on it:
  /// - `user_version` must be between 1 and [AppDatabase.currentSchemaVersion]
  ///   and equal the manifest's schema version;
  /// - every table of the current schema must exist (all of them exist since
  ///   schema 1; a migration that adds a table must exempt older versions
  ///   here);
  /// - every trigger and view is dropped: FinBro defines none, and one
  ///   smuggled into a backup could rewrite data during migration or on any
  ///   later write.
  static Future<void> _sanitizeStaged(
    File staged, {
    required Set<String> expectedTables,
    required int manifestSchemaVersion,
  }) async {
    final raw = NativeDatabase(staged, enableMigrations: false);
    try {
      await raw.ensureOpen(const _PlainConnection());
      final versionRows = await raw.runSelect('PRAGMA user_version', const []);
      final version = versionRows.isEmpty ? 0 : versionRows.first.values.first as int? ?? 0;
      if (version < 1) {
        throw const BackupException('Versi skema database di dalam backup tidak valid.');
      }
      if (version > AppDatabase.currentSchemaVersion) {
        throw BackupException(
          'Database di dalam backup dibuat oleh versi FinBro yang lebih baru (skema $version, '
          'aplikasi ini skema ${AppDatabase.currentSchemaVersion}). Perbarui aplikasi sebelum restore.',
        );
      }
      if (version != manifestSchemaVersion) {
        throw BackupException(
          'Versi skema database ($version) tidak cocok dengan manifest ($manifestSchemaVersion). '
          'File backup rusak atau telah diubah.',
        );
      }
      final schema = await raw.runSelect(
        "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'trigger', 'view')",
        const [],
      );
      final tables = {for (final r in schema) if (r['type'] == 'table') r['name']};
      final missing = expectedTables.where((t) => !tables.contains(t)).toList()..sort();
      if (missing.isNotEmpty) {
        throw BackupException('Database di dalam backup tidak lengkap: tabel ${missing.join(', ')} tidak ditemukan.');
      }
      var dropped = 0;
      for (final r in schema) {
        final kind = switch (r['type']) {
          'trigger' => 'TRIGGER',
          'view' => 'VIEW',
          _ => null,
        };
        if (kind == null) continue;
        final name = '${r['name']}'.replaceAll('"', '""');
        await raw.runCustom('DROP $kind IF EXISTS "$name"');
        dropped++;
      }
      if (dropped > 0) AppLogger.info('Restore: $dropped trigger/view dari backup dihapus');
    } finally {
      await raw.close();
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

/// Chunk size for every streamed copy (zip writing and entry staging).
const _chunkBytes = 1024 * 1024;
const _corruptZip = BackupException('File backup rusak atau bukan file ZIP FinBro.');
const _tooLargeContent = BackupException('Isi backup terlalu besar untuk dipulihkan.');

/// What [BackupService.buildPackage] knows about the backup before the
/// checksums are computed while writing the zip.
typedef _ManifestInfo = ({
  DateTime createdAt,
  int transactions,
  int accounts,
  int attachments,
  Map<String, String> attachmentFiles,
});

/// Writes the backup zip at [archivePath] in a background isolate and returns
/// its manifest. Only paths, numbers and plain maps cross the isolate boundary.
Future<BackupManifest> _writePackageInIsolate({
  required String archivePath,
  required Map<String, String> attachments,
  required String sqlitePath,
  required _ManifestInfo info,
  required int zipLimit,
  required int entryLimit,
  required int totalLimit,
}) => Isolate.run(() {
  final writer = _StreamingZipWriter(File(archivePath), zipLimit: zipLimit, totalLimit: totalLimit, entryLimit: entryLimit);
  try {
    final checksums = <String, String>{
      for (final e in attachments.entries) e.key: writer.addFile(e.key, File(e.value)),
    };
    final manifest = BackupManifest(
      schemaVersion: AppDatabase.currentSchemaVersion,
      createdAt: info.createdAt,
      transactions: info.transactions,
      accounts: info.accounts,
      attachments: info.attachments,
      sha256: writer.addFile(BackupManifest.sqliteEntry, File(sqlitePath)),
      attachmentFiles: info.attachmentFiles,
      attachmentChecksums: checksums,
    );
    writer.addBytes(BackupManifest.entryName, utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson())));
    writer.finish();
    return manifest;
  } finally {
    writer.close();
  }
});

/// Bounded-memory ZIP writer using STORE entries (synchronous; runs inside
/// the packaging isolate). File contents are copied through one reused
/// buffer; the CRC32 in each local header is patched after the copy.
class _StreamingZipWriter {
  _StreamingZipWriter(File file, {required this.zipLimit, required this.totalLimit, required this.entryLimit})
      : _out = file.openSync(mode: FileMode.writeOnly);
  final int zipLimit;
  final int totalLimit;
  final int entryLimit;
  final RandomAccessFile _out;
  final _buffer = Uint8List(_chunkBytes);
  final _central = <({List<int> name, int size, int crc, int offset})>[];
  int _total = 0;

  /// Copies [source] into the zip; returns its SHA-256 (hex).
  String addFile(String name, File source) {
    final input = source.openSync();
    try {
      final size = input.lengthSync();
      _count(size);
      final n = utf8.encode(name);
      final offset = _out.positionSync();
      _header(n, size, 0);
      final digest = AccumulatorSink<crypto.Digest>();
      final hash = crypto.sha256.startChunkedConversion(digest);
      var crc = 0;
      for (var copied = 0; copied < size;) {
        final read = input.readIntoSync(_buffer, 0, min(_chunkBytes, size - copied));
        if (read <= 0) throw BackupException('${p.basename(source.path)} berubah saat backup dibuat. Coba lagi.');
        final chunk = Uint8List.sublistView(_buffer, 0, read);
        crc = getCrc32(chunk, crc);
        hash.add(chunk);
        _out.writeFromSync(_buffer, 0, read);
        copied += read;
      }
      hash.close();
      final end = _out.positionSync();
      _out
        ..setPositionSync(offset + 14)
        ..writeFromSync(_u32(crc))
        ..setPositionSync(end);
      _central.add((name: n, size: size, crc: crc, offset: offset));
      _check();
      return digest.events.single.toString();
    } finally {
      input.closeSync();
    }
  }

  void addBytes(String name, List<int> bytes) {
    _count(bytes.length);
    final n = utf8.encode(name);
    final crc = getCrc32(bytes);
    final offset = _out.positionSync();
    _header(n, bytes.length, crc);
    _out.writeFromSync(bytes);
    _central.add((name: n, size: bytes.length, crc: crc, offset: offset));
    _check();
  }

  /// Writes the central directory and end-of-central-directory record.
  void finish() {
    final start = _out.positionSync();
    for (final e in _central) {
      final h = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x800, Endian.little)
        ..setUint32(16, e.crc, Endian.little)
        ..setUint32(20, e.size, Endian.little)
        ..setUint32(24, e.size, Endian.little)
        ..setUint16(28, e.name.length, Endian.little)
        ..setUint32(42, e.offset, Endian.little);
      _out
        ..writeFromSync(h.buffer.asUint8List())
        ..writeFromSync(e.name);
    }
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, _central.length, Endian.little)
      ..setUint16(10, _central.length, Endian.little)
      ..setUint32(12, _out.positionSync() - start, Endian.little)
      ..setUint32(16, start, Endian.little);
    _out.writeFromSync(end.buffer.asUint8List());
    _check();
  }

  void close() => _out.closeSync();

  void _count(int size) {
    if (size > entryLimit || (_total += size) > totalLimit) throw _tooLargeContent;
  }

  void _header(List<int> name, int size, int crc) {
    final h = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x800, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, size, Endian.little)
      ..setUint32(22, size, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    _out
      ..writeFromSync(h.buffer.asUint8List())
      ..writeFromSync(name);
  }

  void _check() {
    if (_out.positionSync() > zipLimit) throw const BackupException(BackupService.oversizeMessage);
  }

  static Uint8List _u32(int value) => (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
}

/// A zip entry streamed to [path] during validation.
typedef _StagedEntry = ({String path, int length, String sha256});

/// Result of [_validateInIsolate]: staged file paths keyed by zip entry.
typedef _StagedBackup = ({BackupManifest manifest, String sqlitePath, Map<String, String> files});

/// Runs [_stageAndValidate] in a background isolate. Only paths and numbers
/// go in; the manifest and paths come back.
Future<_StagedBackup> _validateInIsolate({
  required String zipPath,
  required String outDir,
  required int currentSchemaVersion,
  required int entryLimit,
  required int totalLimit,
}) => Isolate.run(() => _stageAndValidate(zipPath, outDir, currentSchemaVersion, entryLimit, totalLimit));

_StagedBackup _stageAndValidate(String zipPath, String outDir, int currentSchemaVersion, int entryLimit, int totalLimit) {
  final staged = <String, _StagedEntry>{};
  final input = InputFileStream(zipPath);
  try {
    final directory = ZipDirectory();
    try { directory.read(input); } catch (_) { throw _corruptZip; }
    var total = 0;
    for (final header in directory.fileHeaders) {
      final zf = header.file;
      if (zf == null) throw _corruptZip;
      final name = zf.filename;
      final known = name == BackupManifest.entryName ||
          name == BackupManifest.sqliteEntry || BackupService._isSafeAttachmentEntry(name) ||
          name == '${BackupManifest.attachmentsFolder}/';
      if (!known) throw BackupException('Isi backup tidak dikenal: $name. File ini bukan backup FinBro yang valid.');
      if (name == '${BackupManifest.attachmentsFolder}/') continue;
      if (staged.containsKey(name)) throw _corruptZip;
      final size = zf.uncompressedSize;
      if (size < 0 || size > entryLimit || (total += size) > totalLimit) throw _tooLargeContent;
      staged[name] = _stageEntry(zf, File(p.join(outDir, 'entry-${staged.length}')));
    }
  } finally {
    input.closeSync();
  }

  final manifestEntry = staged[BackupManifest.entryName];
  if (manifestEntry == null) throw const BackupException('manifest.json tidak ditemukan. File ini bukan backup FinBro.');
  final BackupManifest manifest;
  try { manifest = BackupManifest.fromJson(jsonDecode(File(manifestEntry.path).readAsStringSync()) as Map<String, dynamic>); }
  catch (_) { throw const BackupException('manifest.json rusak atau tidak lengkap.'); }
  if (manifest.app != BackupManifest.appId) throw const BackupException('File ini bukan backup FinBro.');
  if (manifest.format != BackupManifest.currentFormat) throw BackupException('Format backup ${manifest.format} tidak didukung versi aplikasi ini.');
  if (manifest.schemaVersion < 1) throw const BackupException('Versi skema pada backup tidak valid.');
  if (manifest.schemaVersion > currentSchemaVersion) throw BackupException('Backup dibuat oleh versi FinBro yang lebih baru (skema ${manifest.schemaVersion}, aplikasi ini skema $currentSchemaVersion). Perbarui aplikasi sebelum restore.');
  final sqlite = staged[BackupManifest.sqliteEntry];
  if (sqlite == null) throw const BackupException('Database tidak ditemukan di dalam backup.');
  if (sqlite.sha256 != manifest.sha256.toLowerCase()) throw const BackupException('Checksum database tidak cocok. File backup rusak atau telah diubah.');
  if (sqlite.length < 100 || _readHead(sqlite.path, 16) != BackupService._sqliteMagic) throw const BackupException('Database di dalam backup bukan file SQLite yang valid.');
  final files = <String, String>{};
  for (final entry in manifest.attachmentFiles.values.toSet()) {
    if (!BackupService._isSafeAttachmentEntry(entry)) throw BackupException('Nama lampiran tidak valid: $entry');
    final file = staged[entry];
    if (file == null) throw BackupException('Lampiran $entry hilang dari backup. File backup tidak lengkap.');
    final expected = manifest.attachmentChecksums[entry]?.toLowerCase();
    if (expected != null && file.sha256 != expected) throw BackupException('Checksum lampiran ${p.basename(entry)} tidak cocok. File backup rusak atau telah diubah.');
    files[entry] = file.path;
  }
  return (manifest: manifest, sqlitePath: sqlite.path, files: files);
}

/// Streams one zip entry to [target], inflating it if needed. The entry may
/// not unpack to more than its declared size (already checked against the
/// per-entry and total limits); its size and CRC32 must match the headers.
_StagedEntry _stageEntry(ZipFile zf, File target) {
  if (zf.flags & 0x1 != 0) throw _corruptZip; // encrypted
  final out = target.openSync(mode: FileMode.writeOnly);
  final sink = _StagingSink(out, zf.uncompressedSize);
  try {
    final raw = zf.getStream(decompress: false);
    final Sink<List<int>> feed = switch (zf.compressionMethod) {
      CompressionType.none => sink,
      CompressionType.deflate => ZLibCodec(raw: true).decoder.startChunkedConversion(sink),
      _ => throw _corruptZip,
    };
    while (!raw.isEOS) {
      feed.add(raw.readBytes(min(_chunkBytes, raw.length)).toUint8List());
    }
    feed.close();
  } on BackupException {
    rethrow;
  } catch (_) {
    throw _corruptZip;
  } finally {
    out.closeSync();
  }
  if (sink.length != zf.uncompressedSize || sink.crc != zf.crc32) throw _corruptZip;
  return (path: target.path, length: sink.length, sha256: sink.sha256);
}

/// Writes unpacked bytes to a file while counting them and updating CRC32 and
/// SHA-256; throws as soon as more than [_limit] bytes arrive.
class _StagingSink implements Sink<List<int>> {
  _StagingSink(this._out, this._limit);
  final RandomAccessFile _out;
  final int _limit;
  final _digest = AccumulatorSink<crypto.Digest>();
  late final _hash = crypto.sha256.startChunkedConversion(_digest);
  int length = 0;
  int crc = 0;

  @override
  void add(List<int> chunk) {
    if ((length += chunk.length) > _limit) throw _corruptZip;
    crc = getCrc32(chunk, crc);
    _hash.add(chunk);
    _out.writeFromSync(chunk);
  }

  @override
  void close() => _hash.close();

  String get sha256 => _digest.events.single.toString();
}

String _readHead(String path, int count) {
  final f = File(path).openSync();
  try { return String.fromCharCodes(f.readSync(count)); } finally { f.closeSync(); }
}

/// Opens a plain connection: no schema, no migrations.
class _PlainConnection implements QueryExecutorUser {
  const _PlainConnection();

  @override
  int get schemaVersion => AppDatabase.currentSchemaVersion;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}
