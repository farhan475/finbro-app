import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/backends.dart' show QueryExecutor, QueryExecutorUser;
import 'package:drift/drift.dart' show OpeningDetails, Value, driftRuntimeOptions;
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

  /// Consistent copy of the live DB (`VACUUM INTO`) + attachments + manifest.
  /// Throws [BackupException] instead of producing a package that [validate]
  /// would reject (larger than [zipLimit], an entry larger than [entryLimit]
  /// or all entries together larger than [totalLimit]).
  Future<BackupPackage> buildPackage(
    DateTime now, {
    String prefix = backupPrefix,
    int zipLimit = maxBackupBytes,
    int entryLimit = maxEntryBytes,
    int totalLimit = maxUnpackedBytes,
  }) async {
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
        // PIN hash/salt and lock settings never leave the device in a backup.
        await (snapshot.delete(snapshot.appSettings)..where((s) => s.key.isIn(deviceLocalSettingKeys))).go();
        transactions = await _count(snapshot, 'transactions');
        accounts = await _count(snapshot, 'accounts');
        rows = await snapshot.select(snapshot.attachments).get();
      } finally {
        await snapshot.close();
      }

      // local_path may come from a restored backup: only files inside the
      // attachments directory are packed.
      final attachmentsRoot = (await attachmentsDir()).path;
      final entryPaths = <String, String>{};
      final entryForPath = <String, String>{};
      final usedNames = <String>{};
      final attachmentFiles = <String, String>{};
      for (final row in rows) {
        final existing = entryForPath[row.localPath];
        if (existing != null) {
          attachmentFiles[row.id] = existing;
          continue;
        }
        if (!AttachmentStorage.isWithin(attachmentsRoot, row.localPath)) {
          AppLogger.error('Backup: lampiran ${row.id} di luar penyimpanan aplikasi dilewati');
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
        entryPaths[entry] = row.localPath;
        entryForPath[row.localPath] = entry;
        attachmentFiles[row.id] = entry;
      }

      final encoded = await _encodeOffThread(
        sqlitePath: copy.path,
        entryPaths: entryPaths,
        createdAt: now,
        transactions: transactions,
        accounts: accounts,
        attachments: rows.length,
        attachmentFiles: attachmentFiles,
        zipLimit: zipLimit,
        entryLimit: entryLimit,
        totalLimit: totalLimit,
      );
      return BackupPackage(
        fileName: fileNameFor(now, prefix: prefix),
        bytes: encoded.bytes,
        manifest: encoded.manifest,
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
    // The restored DB carries the settings of its own past, so it would
    // forget backups made since (and the backup itself was written after its
    // VACUUM copy). Keep the newer of the live value and the backup date.
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
      (dbFile) => installBackup(
        backup,
        dbFile: dbFile,
        attachmentsDir: attachments,
        workDir: work,
        lastBackupAt: lastBackupAt,
        deviceSettings: deviceSettings,
      ),
    );
    return snapshot;
  }

  /// [validate] on a background isolate (unzipping and hashing a large
  /// backup would freeze the UI).
  static Future<ValidatedBackup> validateInBackground(Uint8List zipBytes) =>
      Isolate.run(() => validate(zipBytes));

  /// Checks a backup zip. Throws [BackupException] with a user-facing reason
  /// for corrupted, foreign, tampered, oversized or newer-schema backups.
  /// Only `manifest.json`, `finbro.sqlite` and `attachments/<name>` entries
  /// are accepted; each entry is size-checked before it is unpacked.
  static ValidatedBackup validate(
    Uint8List zipBytes, {
    int currentSchemaVersion = AppDatabase.currentSchemaVersion,
    int entryLimit = maxEntryBytes,
    int totalLimit = maxUnpackedBytes,
  }) {
    const corrupted = BackupException('File backup rusak atau bukan file ZIP FinBro.');
    if (zipBytes.length > maxBackupBytes) throw const BackupException(oversizeMessage);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    } catch (_) {
      throw corrupted;
    }
    final tooLarge = BackupException(
      'Isi backup terlalu besar untuk dipulihkan (maksimal ${entryLimit ~/ _mb} MB per file, '
      '${totalLimit ~/ _mb} MB total).',
    );
    var total = 0;
    for (final f in archive) {
      final known = f.isFile
          ? f.name == BackupManifest.entryName ||
              f.name == BackupManifest.sqliteEntry ||
              _isSafeAttachmentEntry(f.name)
          : f.name == '${BackupManifest.attachmentsFolder}/';
      if (!known) {
        throw BackupException('Isi backup tidak dikenal: ${f.name}. File ini bukan backup FinBro yang valid.');
      }
      if (f.size < 0 || f.size > entryLimit) throw tooLarge;
      total += f.size;
      if (total > totalLimit) throw tooLarge;
    }
    Uint8List? read(String name) {
      final f = archive.findFile(name);
      if (f == null || !f.isFile) return null;
      try {
        return _unpack(f);
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
  /// 1. stage the sqlite in [workDir] and, on a plain connection before any
  ///    migration runs, check its `user_version` and tables and drop every
  ///    trigger and view (the file is untrusted; see [_sanitizeStaged]);
  /// 2. open it with [AppDatabase] so older schemas migrate and
  ///    `attachments.local_path` is rewritten to files restored into
  ///    [attachmentsDir];
  /// 3. reject a staged DB that fails `PRAGMA integrity_check`;
  /// 4. atomically replace [dbFile] and prune attachment files no restored
  ///    row references (the safety snapshot still holds the old ones).
  static Future<void> installBackup(
    ValidatedBackup backup, {
    required File dbFile,
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
        // stagedDb is not opened yet (drift opens lazily on the first query).
        await _sanitizeStaged(
          staged,
          expectedTables: {for (final t in stagedDb.allTables) t.actualTableName},
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
            await (stagedDb.update(stagedDb.attachments)..where((a) => a.id.equals(e.key)))
                .write(AttachmentsCompanion(localPath: Value(path)));
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

  /// Hashes the database copy and zips it with the attachment files and the
  /// manifest on a background isolate, refusing (before reading any file and
  /// after encoding) a package that restore would reject. Static, so the
  /// closure captures only these sendable values, never `this`.
  static Future<({BackupManifest manifest, Uint8List bytes})> _encodeOffThread({
    required String sqlitePath,
    required Map<String, String> entryPaths,
    required DateTime createdAt,
    required int transactions,
    required int accounts,
    required int attachments,
    required Map<String, String> attachmentFiles,
    required int zipLimit,
    required int entryLimit,
    required int totalLimit,
  }) =>
      Isolate.run(() {
        final tooLarge = BackupException(
          'Backup terlalu besar untuk dipulihkan (maksimal ${zipLimit ~/ _mb} MB, '
          '${entryLimit ~/ _mb} MB per file). Hapus lampiran lama lalu coba lagi.',
        );
        var total = 0;
        void count(int size) {
          total += size;
          if (size > entryLimit || total > totalLimit) throw tooLarge;
        }

        count(File(sqlitePath).lengthSync());
        for (final path in entryPaths.values) {
          count(File(path).lengthSync());
        }
        final sqlite = File(sqlitePath).readAsBytesSync();
        final manifest = BackupManifest(
          schemaVersion: AppDatabase.currentSchemaVersion,
          createdAt: createdAt,
          transactions: transactions,
          accounts: accounts,
          attachments: attachments,
          sha256: crypto.sha256.convert(sqlite).toString(),
          attachmentFiles: attachmentFiles,
        );
        final manifestBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
        count(manifestBytes.length);
        final archive = Archive();
        for (final e in entryPaths.entries) {
          archive.add(ArchiveFile.bytes(e.key, File(e.value).readAsBytesSync()));
        }
        archive
          ..add(ArchiveFile.bytes(BackupManifest.sqliteEntry, sqlite))
          ..add(ArchiveFile.bytes(BackupManifest.entryName, manifestBytes));
        final bytes = ZipEncoder().encodeBytes(archive);
        if (bytes.length > zipLimit) throw tooLarge;
        return (manifest: manifest, bytes: bytes);
      });

  /// Unpacks [f] without ever producing more than its declared (already
  /// size-checked) length: an entry whose header understates its content
  /// fails early instead of inflating without bound.
  static Uint8List? _unpack(ArchiveFile f) {
    final raw = f.rawContent;
    if (raw == null) return null;
    final input = raw.getStream(decompress: false);
    final start = input.position;
    final out = _BoundedBytesSink(f.size);
    try {
      switch (f.compression) {
        case CompressionType.deflate:
          final inflate = ZLibCodec(raw: true).decoder.startChunkedConversion(out);
          while (!input.isEOS) {
            inflate.add(input.readBytes(min(64 * 1024, input.length)).toUint8List());
          }
          inflate.close();
        case CompressionType.none || null:
          out.add(input.toUint8List());
        case CompressionType.bzip2:
          throw const FormatException('FinBro backups never use bzip2');
      }
    } finally {
      input.setPosition(start);
    }
    if (out.length != f.size) throw const FormatException('Entry size does not match its header');
    return out.takeBytes();
  }

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

/// Opens a plain connection: no schema, no migrations.
class _PlainConnection implements QueryExecutorUser {
  const _PlainConnection();

  @override
  int get schemaVersion => AppDatabase.currentSchemaVersion;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}

/// Collects unpacked bytes and throws once more than [limit] arrive.
class _BoundedBytesSink implements Sink<List<int>> {
  _BoundedBytesSink(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);

  int get length => _bytes.length;

  @override
  void add(List<int> chunk) {
    if (_bytes.length + chunk.length > limit) {
      throw const FormatException('Entry is larger than its header says');
    }
    _bytes.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}
