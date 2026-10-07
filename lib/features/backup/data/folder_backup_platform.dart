import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../security/presentation/app_lock_gate.dart';
import '../domain/backup_service.dart';
import '../domain/encrypted_backup.dart';
import '../domain/folder_backup_service.dart';

/// Derived backup key in flutter_secure_storage (AES-GCM data encrypted with
/// an Android Keystore key). App data is excluded from Android backup and
/// device transfer (`allowBackup=false`, data extraction rules), so the key
/// never leaves the device.
class SecureBackupKeyStore implements BackupKeyStore {
  const SecureBackupKeyStore();

  static const _storage = FlutterSecureStorage();
  static const _name = 'finbro_backup_key_v1';

  @override
  Future<BackupKey?> read() async => BackupKey.tryDecode(await _storage.read(key: _name));

  @override
  Future<void> write(BackupKey key) => _storage.write(key: _name, value: key.encode());

  @override
  Future<void> delete() => _storage.delete(key: _name);
}

/// Storage Access Framework folder with persisted read/write permission.
class SafBackupFolderAccess implements BackupFolderAccess {
  const SafBackupFolderAccess();

  static final _util = SafUtil();
  static final _stream = SafStream();

  @override
  Future<({String uri, String name})?> pick() async {
    final dir = await AppLockGate.runExempt(
      () => _util.pickDirectory(writePermission: true, persistablePermission: true),
    );
    return dir == null ? null : (uri: dir.uri, name: dir.name);
  }

  @override
  Future<bool> canWrite(String treeUri) async =>
      await _util.hasPersistedPermission(treeUri, checkRead: true, checkWrite: true) &&
      await _util.exists(treeUri, true);

  @override
  Future<List<FolderEntry>> list(String treeUri) async => [
    for (final f in await _util.list(treeUri))
      if (!f.isDir) FolderEntry(uri: f.uri, name: f.name),
  ];

  /// Pasted under a temporary `.partial` name and renamed once complete, so
  /// a copy interrupted mid-way (process killed, WorkManager stop) never
  /// looks like a finished backup to retention or restore.
  @override
  Future<String> write(String treeUri, String fileName, File source) async {
    final partial = await _stream.pasteLocalFile(
      source.path,
      treeUri,
      '$fileName${FolderBackupService.partialSuffix}',
      EncryptedBackup.mimeType,
    );
    try {
      final done = await _util.rename(partial.uri.toString(), false, fileName);
      return done.name;
    } catch (_) {
      try {
        await _util.delete(partial.uri.toString(), false);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String uri) => _util.delete(uri, false);

  @override
  Future<void> release(String treeUri) => _util.releasePersistedPermission(treeUri, read: true, write: true);

  /// Lets the user pick any file (cloud providers rarely know a `.finbro`
  /// MIME type) and copies it into a fresh temporary directory under
  /// [workDir]; the caller deletes the returned file's parent. Returns null
  /// when cancelled; throws [BackupException] when the picker reports a size
  /// above [EncryptedBackup.maxFileBytes] (checked again when the header is
  /// read).
  static Future<File?> pickEncryptedFile(Directory workDir) async {
    final picked = await AppLockGate.runExempt(() => _util.pickFile(mimeTypes: const ['*/*']));
    if (picked == null) return null;
    if (picked.length > EncryptedBackup.maxFileBytes) {
      throw const BackupException(EncryptedBackup.oversizeMessage);
    }
    final dir = await workDir.createTemp('finbro-pick-');
    final dest = File('${dir.path}/picked${EncryptedBackup.extension}');
    try {
      await _stream.copyToLocalFile(picked.uri, dest.path);
    } catch (_) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    return dest;
  }
}

final backupKeyStoreProvider = Provider<BackupKeyStore>((ref) => const SecureBackupKeyStore());

final backupFolderAccessProvider = Provider<BackupFolderAccess>((ref) => const SafBackupFolderAccess());

final folderBackupServiceProvider = Provider<FolderBackupService>(
  (ref) => FolderBackupService(
    db: ref.watch(databaseProvider),
    backups: ref.watch(backupServiceProvider),
    keys: ref.watch(backupKeyStoreProvider),
    folder: ref.watch(backupFolderAccessProvider),
    workDir: getTemporaryDirectory,
  ),
);

/// Folder backup settings and last outcome, live from `app_settings`.
final folderBackupStatusProvider = Provider<FolderBackupStatus>(
  (ref) => FolderBackupStatus.fromSettings(ref.watch(appSettingsProvider).value ?? const {}),
);

/// The stored backup key (null: no passphrase set on this device).
final backupKeyProvider = FutureProvider.autoDispose<BackupKey?>(
  (ref) => ref.watch(backupKeyStoreProvider).read(),
);

/// Whether the chosen folder is still writable (null: no folder chosen).
final folderWritableProvider = FutureProvider.autoDispose<bool?>((ref) async {
  final uri = ref.watch(folderBackupStatusProvider.select((s) => s.folderUri));
  if (uri == null) return null;
  try {
    return await ref.watch(backupFolderAccessProvider).canWrite(uri);
  } catch (_) {
    return false;
  }
});
