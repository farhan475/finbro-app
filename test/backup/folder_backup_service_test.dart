import 'dart:io';

import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/features/backup/domain/backup_service.dart';
import 'package:finbro_app/features/backup/domain/encrypted_backup.dart';
import 'package:finbro_app/features/backup/domain/folder_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _MemoryKeyStore implements BackupKeyStore {
  BackupKey? key;

  @override
  Future<BackupKey?> read() async => key;

  @override
  Future<void> write(BackupKey key) async => this.key = key;

  @override
  Future<void> delete() async => key = null;
}

/// A plain directory standing in for the SAF tree.
class _DirFolder implements BackupFolderAccess {
  _DirFolder(this.dir);
  final Directory dir;
  final released = <String>[];

  @override
  Future<({String uri, String name})?> pick() async => (uri: dir.path, name: p.basename(dir.path));

  @override
  Future<bool> canWrite(String treeUri) async => treeUri == dir.path && dir.existsSync();

  @override
  Future<List<FolderEntry>> list(String treeUri) async => [
    for (final f in dir.listSync().whereType<File>()) FolderEntry(uri: f.path, name: p.basename(f.path)),
  ];

  @override
  Future<String> write(String treeUri, String fileName, File source) async {
    await source.copy(p.join(treeUri, fileName));
    return fileName;
  }

  @override
  Future<void> delete(String uri) => File(uri).delete();

  @override
  Future<void> release(String treeUri) async => released.add(treeUri);
}

void main() {
  const fastKdf = KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);
  late Directory tmp;
  late Directory folderDir;
  late Directory work;
  late AppDatabase db;
  late _MemoryKeyStore keys;
  late _DirFolder folder;
  late FolderBackupService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('finbro-folder-test-');
    folderDir = await Directory(p.join(tmp.path, 'Drive')).create();
    work = await Directory(p.join(tmp.path, 'work')).create();
    final attachments = await Directory(p.join(tmp.path, 'attachments')).create();
    final backups = await Directory(p.join(tmp.path, 'backups')).create();
    db = AppDatabase.memory();
    keys = _MemoryKeyStore();
    folder = _DirFolder(folderDir);
    service = FolderBackupService(
      db: db,
      backups: BackupService(
        db: db,
        attachmentsDir: () async => attachments,
        backupsDir: () async => backups,
        workDir: () async => work,
      ),
      keys: keys,
      folder: folder,
      workDir: () async => work,
    );
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  List<String> folderNames() => [for (final f in folderDir.listSync()) p.basename(f.path)]..sort();

  test('backups are encrypted from the package file, decrypt to a valid backup, and only the newest N FinBro files stay', () async {
    await service.setKey(await EncryptedBackup.deriveKey('rahasia-panjang', params: fastKdf));
    await service.setFolder(folderDir.path, 'Drive');
    await service.setKeep(3);
    File(p.join(folderDir.path, 'catatan.txt')).writeAsStringSync('punya user');
    File(p.join(folderDir.path, 'finbro-lama.finbro')).writeAsStringSync('nama tidak cocok pola');
    // Copy interrupted by a killed process: not a backup, cleaned up.
    File(p.join(folderDir.path, 'finbro-20260930-210500.finbro.partial')).writeAsStringSync('setengah');

    final written = <String>[];
    for (var day = 1; day <= 5; day++) {
      written.add(await service.backupNow(DateTime(2026, 10, day, 21, 5)));
    }

    expect(folderNames(), unorderedEquals(['catatan.txt', 'finbro-lama.finbro', ...written.sublist(2)]));
    expect(work.listSync(), isEmpty, reason: 'package and encrypted temp files are removed');
    final status = await service.status();
    expect(status.lastSuccessAt, DateTime(2026, 10, 5, 21, 5));
    expect(status.failing, isFalse);

    final out = File(p.join(tmp.path, 'restored.zip'));
    await EncryptedBackup.decryptWithPassphrase(File(p.join(folderDir.path, written.last)), out, 'rahasia-panjang');
    final validated = await BackupService.validateFile(out, workDir: () async => work);
    expect(validated.manifest.createdAt, DateTime(2026, 10, 5, 21, 5));
    await validated.dispose();
  });

  test('a missing key is recorded as the failure; setting a key clears it', () async {
    await service.setFolder(folderDir.path, 'Drive');
    await expectLater(
      service.backupNow(DateTime(2026, 10, 7, 8)),
      throwsA(isA<BackupException>().having((e) => e.message, 'message', FolderBackupService.noKeyMessage)),
    );
    var status = await service.status();
    expect(status.failing, isTrue);
    expect(status.lastError, FolderBackupService.noKeyMessage);
    expect(folderNames(), isEmpty);

    await service.setKey(await EncryptedBackup.deriveKey('rahasia-panjang', params: fastKdf));
    status = await service.status();
    expect(status.failing, isFalse);
    expect(await service.runIfDue(DateTime(2026, 10, 7, 9)), isNotNull);
  });

  test('disable releases the folder and deletes the key but keeps written files', () async {
    await service.setKey(await EncryptedBackup.deriveKey('rahasia-panjang', params: fastKdf));
    await service.setFolder(folderDir.path, 'Drive');
    final name = await service.backupNow(DateTime(2026, 10, 7, 8));

    await service.disable();

    expect(keys.key, isNull);
    expect(folder.released, [folderDir.path]);
    expect((await service.status()).hasFolder, isFalse);
    expect(await service.runIfDue(DateTime(2026, 10, 9, 8)), isNull);
    expect(folderNames(), [name]);
  });
}
