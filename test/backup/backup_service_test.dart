import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/database_cipher.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/backup/domain/backup_service.dart';
import 'package:finbro_app/features/backup/domain/csv_export.dart';
import 'package:finbro_app/features/backup/domain/integrity_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../generated_migrations/schema_v2.dart' as v2db;

void main() {
  late Directory tmp;
  late Directory attachments;
  late Directory backups;
  late Directory work;
  late AppDatabase db;
  late LedgerService ledger;
  late BackupService service;
  final now = DateTime(2026, 9, 30, 21, 5);
  // This device's database key: restores land encrypted with it.
  final key = DatabaseKey.generate();

  String header(File f) => String.fromCharCodes(f.readAsBytesSync().take(16));

  Future<String> account(String name, int opening) async {
    final id = 'acc-$name';
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: id, name: name, type: AccountType.bank,
      openingBalance: Value(opening), createdAt: now, updatedAt: now,
    ));
    return id;
  }

  Future<String> expense(String accountId, int amount, {List<AttachmentDraft> attachments = const []}) =>
      ledger.create(TransactionDraft(
        type: TransactionType.expense, amount: amount, accountId: accountId,
        categoryId: SystemCategories.food, transactionAt: now, note: 'Makan, "siang"',
        attachments: attachments,
      ));

  Future<AttachmentDraft> receipt(String name, String content) async {
    final f = File(p.join(attachments.path, name));
    await f.writeAsString(content);
    return AttachmentDraft(localPath: f.path, mimeType: 'image/jpeg', kind: AttachmentKind.receipt);
  }

  /// Seeds 2 accounts, 3 transactions, 1 attachment.
  Future<void> seedData() async {
    final bca = await account('BCA', 1000000);
    final cash = await account('Cash', 50000);
    await expense(bca, 25000, attachments: [await receipt('r1.jpg', 'receipt-bytes')]);
    await expense(cash, 10000);
    await ledger.create(TransactionDraft(
      type: TransactionType.transfer, amount: 100000, accountId: bca,
      transferToAccountId: cash, transactionAt: now,
    ));
  }

  Future<int> count(AppDatabase d, String table) async =>
      (await d.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle()).read<int>('c');

  /// Rewrites entries of a valid package to simulate tampering.
  Uint8List tamper(Uint8List zip, {Map<String, Object?> Function(Map<String, Object?>)? manifest, Uint8List? sqlite}) {
    final src = ZipDecoder().decodeBytes(zip);
    final out = Archive();
    for (final f in src) {
      if (f.name == BackupManifest.entryName && manifest != null) {
        final m = jsonDecode(utf8.decode(f.readBytes()!)) as Map<String, Object?>;
        out.add(ArchiveFile.string(f.name, jsonEncode(manifest(m))));
      } else if (f.name == BackupManifest.sqliteEntry && sqlite != null) {
        out.add(ArchiveFile.bytes(f.name, sqlite));
      } else {
        out.add(ArchiveFile.bytes(f.name, f.readBytes()!));
      }
    }
    return ZipEncoder().encodeBytes(out);
  }
  Future<File> writeZip(Uint8List bytes, [String prefix = 'zip']) async {
    final file = File(p.join(tmp.path, '$prefix-${DateTime.now().microsecondsSinceEpoch}.zip'));
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<ValidatedBackup> validateZip(Uint8List bytes, {
    int? currentSchemaVersion,
    int? entryLimit,
    int? totalLimit,
  }) async {
    final file = await writeZip(bytes);
    return BackupService.validateFile(file,
        workDir: () async => work,
        currentSchemaVersion: currentSchemaVersion ?? AppDatabase.currentSchemaVersion,
        entryLimit: entryLimit ?? BackupService.maxEntryBytes,
        totalLimit: totalLimit ?? BackupService.maxUnpackedBytes);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('finbro-backup-test-');
    attachments = await Directory(p.join(tmp.path, 'attachments')).create();
    backups = await Directory(p.join(tmp.path, 'backups')).create();
    work = await Directory(p.join(tmp.path, 'work')).create();
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    service = BackupService(
      db: db,
      attachmentsDir: () async => attachments,
      backupsDir: () async => backups,
      workDir: () async => work,
    );
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('export → validate → restore roundtrip keeps counts and snapshots first', () async {
    await seedData();
    final created = await service.createBackup(now);

    expect(created.package.fileName, 'finbro-backup-2026-09-30-2105.zip');
    expect(await created.file.exists(), isTrue);
    expect(await AppSettingsRepository(db).get(SettingKeys.lastBackupAt), '2026-09-30T21:05:00');
    expect(await count(db, 'backups'), 1);

    final validated = await validateZip(await created.file.readAsBytes());
    final m = validated.manifest;
    expect(m.app, 'FinBro');
    expect(m.schemaVersion, AppDatabase.currentSchemaVersion);
    expect((m.transactions, m.accounts, m.attachments), (3, 2, 1));
    expect(validated.files.keys, ['attachments/r1.jpg']);

    // Data changes after the backup; restore must bring back the backup state.
    await expense('acc-BCA', 5000);

    final dbFile = File(p.join(tmp.path, 'live', 'finbro.sqlite'));
    File? snapshotSeenDuringReplace;
    final snapshot = await service.restore(
      validated,
      now: now.add(const Duration(minutes: 1)),
      replaceDatabase: (replace) async {
        final safety = (await backups.list().toList())
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith(BackupService.safetyPrefix));
        expect(safety, hasLength(1), reason: 'safety snapshot must exist before the swap');
        snapshotSeenDuringReplace = safety.single;
        await replace((file: dbFile, key: key));
      },
    );
    expect(snapshot.path, snapshotSeenDuringReplace!.path);
    expect(p.basename(snapshot.path), 'safety-finbro-backup-2026-09-30-2106.zip');
    // The snapshot holds the pre-restore data (4 transactions).
    await validateZip(await snapshot.readAsBytes());

    expect(header(dbFile), isNot('SQLite format 3\u0000'), reason: 'the restored live DB is encrypted');
    final restored = AppDatabase.encrypted(dbFile, key);
    addTearDown(restored.close);
    expect(await count(restored, 'transactions'), m.transactions);
    expect(await count(restored, 'accounts'), m.accounts);
    final att = await restored.select(restored.attachments).getSingle();
    expect(await File(att.localPath).readAsString(), 'receipt-bytes');
    final report = await runIntegrityCheck(restored, attachments, now: now, trigger: 'restore');
    expect(report.ok, isTrue, reason: report.summary.join('; '));
  });

  test('an encrypted live database backs up as plain SQLite and restores under another device key', () async {
    // Device A: the live database is SQLCipher-encrypted with its own key.
    final liveA = File(p.join(tmp.path, 'deviceA', 'finbro.sqlite'));
    await liveA.parent.create();
    await db.close();
    db = AppDatabase.encrypted(liveA, DatabaseKey.generate());
    ledger = LedgerService(db);
    service = BackupService(
      db: db,
      attachmentsDir: () async => attachments,
      backupsDir: () async => backups,
      workDir: () async => work,
    );
    await seedData();
    expect(header(liveA), isNot('SQLite format 3\u0000'));

    final package = await service.buildPackage(now);
    final validated = await validateZip(await package.file.readAsBytes());
    // Portable: plain SQLite, readable without any key.
    expect(header(validated.sqliteFile), 'SQLite format 3\u0000');
    final plain = AppDatabase(NativeDatabase(validated.sqliteFile));
    expect(await count(plain, 'transactions'), 3);
    await plain.close();

    // Device B restores it under its own key.
    final liveB = File(p.join(tmp.path, 'deviceB', 'finbro.sqlite'));
    final attachmentsB = await Directory(p.join(tmp.path, 'deviceB', 'attachments')).create(recursive: true);
    await BackupService.installBackup(validated, dbFile: liveB, key: key, attachmentsDir: attachmentsB, workDir: work);
    expect(header(liveB), isNot('SQLite format 3\u0000'));
    final restored = AppDatabase.encrypted(liveB, key);
    addTearDown(restored.close);
    expect(await count(restored, 'transactions'), 3);
    expect(await count(restored, 'accounts'), 2);
    final att = await restored.select(restored.attachments).getSingle();
    expect(await File(att.localPath).readAsString(), 'receipt-bytes');
    await package.dispose();
    await validated.dispose();
  });

  test('backups carry no PIN data and restore keeps this device\'s lock settings', () async {
    await seedData();
    final settings = AppSettingsRepository(db);
    await settings.set(SettingKeys.pinHash, 'old-hash');
    await settings.set(SettingKeys.pinSalt, 'old-salt');
    final created = await service.createBackup(now);
    final validated = await validateZip(await created.file.readAsBytes());
    final staged = validated.sqliteFile;
    final backupDb = AppDatabase(NativeDatabase(staged));
    addTearDown(backupDb.close);
    expect(await AppSettingsRepository(backupDb).get(SettingKeys.pinHash), isNull);
    expect(await AppSettingsRepository(backupDb).get(SettingKeys.pinSalt), isNull);

    // The device sets a different PIN before restoring.
    await settings.set(SettingKeys.pinHash, 'device-hash');
    await settings.set(SettingKeys.pinSalt, 'device-salt');
    final dbFile = File(p.join(tmp.path, 'live2', 'finbro.sqlite'));
    await service.restore(
      validated,
      now: now.add(const Duration(minutes: 1)),
      replaceDatabase: (replace) => replace((file: dbFile, key: key)),
    );
    final restored = AppDatabase.encrypted(dbFile, key);
    addTearDown(restored.close);
    expect(await AppSettingsRepository(restored).get(SettingKeys.pinHash), 'device-hash');
    expect(await AppSettingsRepository(restored).get(SettingKeys.pinSalt), 'device-salt');
  });

  test('safety snapshot retention keeps the newest two and manual backups are untouched', () async {
    await seedData();
    final backupsDirPath = backups.path;
    File make(String name, DateTime modified) {
      final f = File(p.join(backupsDirPath, name))..writeAsStringSync('x');
      f.setLastModifiedSync(modified);
      return f;
    }

    final keep1 = make('${BackupService.safetyPrefix}-2026-09-30-1000.zip', DateTime(2026, 9, 30, 10));
    final keep2 = make('${BackupService.safetyPrefix}-2026-09-30-1100.zip', DateTime(2026, 9, 30, 11));
    make('${BackupService.safetyPrefix}-2026-09-30-0900.zip', DateTime(2026, 9, 30, 9));
    final manual = make('finbro-backup-2026-09-30-0905.zip', DateTime(2026, 9, 30, 9, 5));

    final deleted = await service.pruneSafetySnapshots(now);
    expect(deleted.map(p.basename), ['${BackupService.safetyPrefix}-2026-09-30-0900.zip']);
    expect(keep1.existsSync(), isTrue);
    expect(keep2.existsSync(), isTrue);
    expect(manual.existsSync(), isTrue, reason: 'retention only touches safety snapshots');

    // A new snapshot protects itself and counts towards keep: with keep = 2
    // the previous newest (1100) also stays; 1000 goes (0900 was already
    // deleted by the first prune, so only it can be reported here).
    final fresh = File(p.join(backupsDirPath, '${BackupService.safetyPrefix}-2026-09-30-1200.zip'))..writeAsStringSync('x');
    final deleted2 = await service.pruneSafetySnapshots(now, protect: fresh.path);
    expect(deleted2.map(p.basename).toSet(), {'${BackupService.safetyPrefix}-2026-09-30-1000.zip'});
    expect(fresh.existsSync(), isTrue);
    expect(keep2.existsSync(), isTrue);
    expect(keep1.existsSync(), isFalse);
  });

  test('two safety snapshots in the same minute never overwrite each other', () async {
    await seedData();
    final first = await service.createSafetySnapshot(now);
    final firstBytes = await first.readAsBytes();
    await expense(await account('Extra', 1), 1000);
    final second = await service.createSafetySnapshot(now);

    expect(second.path, isNot(first.path));
    // Retention (keep 2, the new snapshot included) keeps both files alive.
    expect(await first.exists(), isTrue);
    expect(await second.exists(), isTrue);
    expect(firstBytes, isNotEmpty);
  });

  test('restore keeps the newer of the live last-backup date and the backup date', () async {
    await seedData();
    final old = await validateZip(await (await service.createBackup(now)).file.readAsBytes());
    final later = now.add(const Duration(days: 3));
    await service.createBackup(later);

    Future<String?> restoredLastBackup(AppDatabase live, String name) async {
      final dbFile = File(p.join(tmp.path, name, 'finbro.sqlite'));
      final s = BackupService(
        db: live,
        attachmentsDir: () async => attachments,
        backupsDir: () async => backups,
        workDir: () async => work,
      );
      await s.restore(old, now: later, replaceDatabase: (replace) => replace((file: dbFile, key: key)));
      final restored = AppDatabase.encrypted(dbFile, key);
      addTearDown(restored.close);
      return AppSettingsRepository(restored).get(SettingKeys.lastBackupAt);
    }

    // Same device: a backup made after the restored one is not forgotten.
    expect(await restoredLastBackup(db, 'same'), '2026-10-03T21:05:00');
    // New device without any backup history: the backup's own date counts.
    final fresh = AppDatabase.memory();
    addTearDown(fresh.close);
    expect(await restoredLastBackup(fresh, 'fresh'), '2026-09-30T21:05:00');
  });

  test('restore on a new device rewrites attachment paths and prunes stale files', () async {
    await seedData();
    final package = await service.buildPackage(now);
    final validated = await validateZip(await package.file.readAsBytes());

    final newAttachments = await Directory(p.join(tmp.path, 'device2', 'attachments')).create(recursive: true);
    final stale = File(p.join(newAttachments.path, 'old.jpg'))..writeAsStringSync('old');
    final dbFile = File(p.join(tmp.path, 'device2', 'finbro.sqlite'));
    await BackupService.installBackup(validated, dbFile: dbFile, key: key, attachmentsDir: newAttachments, workDir: work);

    final restored = AppDatabase.encrypted(dbFile, key);
    addTearDown(restored.close);
    final att = await restored.select(restored.attachments).getSingle();
    expect(att.localPath, p.join(newAttachments.path, 'r1.jpg'));
    expect(await File(att.localPath).readAsString(), 'receipt-bytes');
    expect(stale.existsSync(), isFalse);
    await package.dispose();
    await validated.dispose();
    expect(await work.list().toList(), isEmpty, reason: 'staging files cleaned up');
  });

  test('corrupted or foreign files are rejected', () async {
    await seedData();
    final package = await service.buildPackage(now);

    await expectLater(validateZip(Uint8List.fromList(List.generate(512, (i) => i % 251))),
        throwsA(isA<BackupException>()));
    final packageBytes = await package.file.readAsBytes();
    await expectLater(validateZip(Uint8List.sublistView(packageBytes, 0, packageBytes.length ~/ 2)),
        throwsA(isA<BackupException>()));

    final noManifest = ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string('finbro.sqlite', 'x')));
    await expectLater(validateZip(noManifest),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('manifest.json'))));

    final foreign = tamper(packageBytes, manifest: (m) => {...m, 'app': 'OtherApp'});
    await expectLater(validateZip(foreign),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('bukan backup FinBro'))));
  });

  test('sha256 mismatch is rejected', () async {
    await seedData();
    final package = await service.buildPackage(now);
    final validated = await validateZip(await package.file.readAsBytes());
    final altered = Uint8List.fromList(await validated.sqliteFile.readAsBytes())
      ..[validated.sqliteFile.lengthSync() - 1] ^= 0xFF;
    await expectLater(validateZip(tamper(await package.file.readAsBytes(), sqlite: altered)),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('Checksum'))));
    final wrongHash = tamper(await package.file.readAsBytes(), manifest: (m) => {...m, 'sha256': '0' * 64});
    await expectLater(validateZip(wrongHash),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('Checksum'))));
  });
  test('newer schema version is rejected, older is accepted', () async {
    await seedData();
    final package = await service.buildPackage(now);
    final packageBytes = await package.file.readAsBytes();
    final newer = tamper(packageBytes,
        manifest: (m) => {...m, 'schemaVersion': AppDatabase.currentSchemaVersion + 1});
    await expectLater(validateZip(newer),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('lebih baru'))));
    final v = await validateZip(packageBytes,
        currentSchemaVersion: AppDatabase.currentSchemaVersion + 1);
    expect(v.manifest.schemaVersion, AppDatabase.currentSchemaVersion);
  });
  test('failed install keeps the old database and removes extracted files', () async {
    await seedData();
    final validated = await validateZip(await (await service.buildPackage(now)).file.readAsBytes());
    final brokenSqlite = File(p.join(tmp.path, 'broken.sqlite'));
    await brokenSqlite.writeAsBytes(Uint8List.fromList(
        [...'SQLite format 3\u0000'.codeUnits, ...List.filled(4096, 7)]));
    final broken = ValidatedBackup(
      manifest: validated.manifest, sqliteFile: brokenSqlite, files: validated.files,
      ownedDirectory: validated.ownedDirectory,
    );

    final target = await Directory(p.join(tmp.path, 'd3', 'attachments')).create(recursive: true);
    final dbFile = File(p.join(tmp.path, 'd3', 'finbro.sqlite'))..writeAsStringSync('old-db');

    await expectLater(
      BackupService.installBackup(broken, dbFile: dbFile, key: key, attachmentsDir: target, workDir: work),
      throwsA(anything),
    );
    expect(dbFile.readAsStringSync(), 'old-db');
    expect(await target.list().toList(), isEmpty);
  });

  test('integrity check finds missing and orphan attachment files', () async {
    await seedData();
    await File(p.join(attachments.path, 'r1.jpg')).delete();
    await File(p.join(attachments.path, 'orphan.png')).writeAsString('x');

    final report = await runIntegrityCheck(db, attachments, now: now, trigger: 'manual');
    expect(report.databaseProblems, isEmpty);
    expect(report.missingFiles.map(p.basename), ['r1.jpg']);
    expect(report.orphanFiles.map(p.basename), ['orphan.png']);
    expect(IntegrityReport.tryParse(jsonEncode(report.toJson()))!.summary, report.summary);
  });

  test('a tampered attachment entry fails validation via its manifest checksum', () async {
    await seedData();
    final created = await service.createBackup(now);
    final src = ZipDecoder().decodeBytes(await created.file.readAsBytes());

    // Rebuild the zip with different attachment bytes (valid zip: CRC fixed
    // by the encoder), so only the manifest SHA-256 can catch the change.
    final out = Archive();
    for (final f in src) {
      out.add(
        f.name == 'attachments/r1.jpg'
            ? ArchiveFile.bytes(f.name, utf8.encode('tampered-bytes'))
            : ArchiveFile.bytes(f.name, f.readBytes()!),
      );
    }
    final zip = ZipEncoder().encodeBytes(out);

    await expectLater(validateZip(zip), throwsA(isA<BackupException>().having(
      (e) => e.message, 'message', contains('Checksum lampiran r1.jpg tidak cocok'))));
  });

  test('restore writes the manifest checksum into attachments and integrity check verifies it', () async {
    await seedData();
    final created = await service.createBackup(now);
    final validated = await validateZip(await created.file.readAsBytes());

    final dbFile = File(p.join(tmp.path, 'live', 'finbro.sqlite'));
    await service.restore(
      validated,
      now: now.add(const Duration(minutes: 1)),
      replaceDatabase: (replace) => replace((file: dbFile, key: key)),
    );
    final restored = AppDatabase.encrypted(dbFile, key);
    addTearDown(restored.close);

    final att = await restored.select(restored.attachments).getSingle();
    expect(att.fileSha256, isNotNull);
    expect(att.fileSha256, sha256.convert(await File(att.localPath).readAsBytes()).toString());

    // Unmodified: report OK and the checksum is not flagged.
    final report = await runIntegrityCheck(restored, attachments, now: now, trigger: 'restore');
    expect(report.checksumMismatches, isEmpty);
    expect(report.ok, isTrue, reason: report.summary.join('; '));

    // Tamper the restored file on disk: the next integrity check flags it.
    await File(att.localPath).writeAsString('edited-after-restore');
    final after = await runIntegrityCheck(restored, attachments, now: now, trigger: 'manual');
    expect(after.checksumMismatches.map(p.basename), ['r1.jpg']);
    expect(after.ok, isFalse);
  });

  test('CSV export quotes free text and neutralises formulas', () async {
    await seedData();
    await ledger.create(TransactionDraft(
      type: TransactionType.income, amount: 1500000, accountId: 'acc-BCA',
      categoryId: SystemCategories.salary, transactionAt: now, note: '=HYPERLINK("x")',
    ));
    final lines = (await buildTransactionsCsv(db)).substring(1).trim().split('\r\n');
    expect(lines.first, 'date,type,amount,currency,category,account,to_account,note,source,status');
    expect(lines, contains('2026-09-30T21:05:00,expense,25000,IDR,Food,BCA,,"Makan, ""siang""",manual,confirmed'));
    expect(lines, contains('2026-09-30T21:05:00,transfer,100000,IDR,,BCA,Cash,,manual,confirmed'));
    expect(lines, contains('2026-09-30T21:05:00,income,1500000,IDR,Salary,BCA,,"\'=HYPERLINK(""x"")",manual,confirmed'));
    // Leading tab / carriage return also start a formula in some spreadsheets.
    expect(csvField('\t=1+1'), "'\t=1+1");
    expect(csvField('\r=1+1'), '"\'\r=1+1"');
  });

  /// Package whose database was changed by [mutate], with a matching hash.
  Future<Uint8List> withMutatedDb(Future<void> Function(AppDatabase d) mutate) async {
    final package = await service.buildPackage(now);
    final file = File(p.join(tmp.path, 'mutate-${DateTime.now().microsecondsSinceEpoch}.sqlite'))
      ..writeAsBytesSync((await validateZip(await package.file.readAsBytes())).sqliteFile.readAsBytesSync());
    final d = AppDatabase(NativeDatabase(file));
    await mutate(d);
    await d.close();
    final sqlite = file.readAsBytesSync();
    return tamper(package.file.readAsBytesSync(), sqlite: sqlite, manifest: (m) => {...m, 'sha256': sha256.convert(sqlite).toString()});
  }

  test('restore rejects a database whose user_version is missing, newer or not the manifest\'s', () async {
    await seedData();
    final cases = {
      0: 'tidak valid',
      AppDatabase.currentSchemaVersion + 1: 'lebih baru',
      AppDatabase.currentSchemaVersion - 1: 'tidak cocok dengan manifest',
    };
    for (final MapEntry(key: version, value: message) in cases.entries) {
      final zip = await withMutatedDb((d) => d.customStatement('PRAGMA user_version = $version'));
      final validated = await validateZip(zip);
      final target = await Directory(p.join(tmp.path, 'v$version', 'attachments')).create(recursive: true);
      final dbFile = File(p.join(tmp.path, 'v$version', 'finbro.sqlite'))..writeAsStringSync('old-db');
      await expectLater(
        BackupService.installBackup(validated, dbFile: dbFile, key: key, attachmentsDir: target, workDir: work),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains(message))),
        reason: 'user_version $version',
      );
      expect(dbFile.readAsStringSync(), 'old-db');
    }
  });

  test('a schema v2 backup restores through the migration and keeps its goals', () async {
    // Database written by the v2 app (frozen schema), with a goal and its movement.
    final v2File = File(p.join(tmp.path, 'v2.sqlite'));
    final v2 = v2db.DatabaseAtV2(NativeDatabase(v2File));
    const ts = '2026-09-01T10:00:00';
    await v2.customStatement(
      'INSERT INTO accounts (id, name, type, opening_balance, created_at, updated_at) '
      "VALUES ('s1', 'Tabungan', 'savings', 2000000, '$ts', '$ts')",
    );
    await v2.customStatement(
      'INSERT INTO goals (id, name, type, target_amount, current_amount, created_at, updated_at) '
      "VALUES ('g1', 'Dana Darurat', 'emergency', 6000000, 1500000, '$ts', '$ts')",
    );
    await v2.customStatement(
      'INSERT INTO goal_movements (id, goal_id, amount, movement_type, movement_at) '
      "VALUES ('m1', 'g1', 1500000, 'contribution', '$ts')",
    );
    await v2.close();
    final sqlite = v2File.readAsBytesSync();
    final zip = tamper(
      (await service.buildPackage(now)).file.readAsBytesSync(),
      sqlite: sqlite,
      manifest: (m) => {...m, 'schemaVersion': 2, 'sha256': sha256.convert(sqlite).toString()},
    );

    final validated = await validateZip(zip);
    expect(validated.manifest.schemaVersion, 2);
    final target = await Directory(p.join(tmp.path, 'from-v2', 'attachments')).create(recursive: true);
    final dbFile = File(p.join(tmp.path, 'from-v2', 'finbro.sqlite'));
    await BackupService.installBackup(validated, dbFile: dbFile, key: key, attachmentsDir: target, workDir: work);

    final restored = AppDatabase.encrypted(dbFile, key);
    addTearDown(restored.close);
    final goal = await restored.select(restored.goals).getSingle();
    expect((goal.id, goal.currentAmount, goal.linkedAccountId), ('g1', 1500000, null));
    expect(await count(restored, 'goal_movements'), 1);
    final version = await restored.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, AppDatabase.currentSchemaVersion);
    // The migrated database accepts the new link column.
    await restored.customStatement("UPDATE goals SET linked_account_id = 's1'");
    expect((await restored.select(restored.goals).getSingle()).linkedAccountId, 's1');
  });

  test('restore drops triggers and views smuggled into the backup database', () async {
    await seedData();
    final zip = await withMutatedDb((d) async {
      // Would fire when restore rewrites attachments.local_path.
      await d.customStatement(
        "CREATE TRIGGER evil AFTER UPDATE ON attachments BEGIN UPDATE transactions SET note = 'pwned'; END",
      );
      await d.customStatement('CREATE VIEW leak AS SELECT * FROM transactions');
    });
    final target = await Directory(p.join(tmp.path, 'd4', 'attachments')).create(recursive: true);
    final dbFile = File(p.join(tmp.path, 'd4', 'finbro.sqlite'));
    await BackupService.installBackup(await validateZip(zip),
        dbFile: dbFile, key: key, attachmentsDir: target, workDir: work, lastBackupAt: now);
    final restored = AppDatabase.encrypted(dbFile, key);
    addTearDown(restored.close);
    final extras = await restored
        .customSelect("SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')")
        .get();
    expect(extras, isEmpty);
    final notes = (await restored.select(restored.transactions).get()).map((t) => t.note);
    expect(notes, isNot(contains('pwned')));
    expect(await count(restored, 'transactions'), 3);
  });

  test('a backup that restore would reject is never produced', () async {
    await seedData();
    final first = await service.buildPackage(now);
    final zip = await first.file.readAsBytes();
    final entries = ZipDecoder().decodeBytes(zip);
    final largest = entries.map((f) => f.size).reduce((a, b) => a > b ? a : b);
    final total = entries.fold(0, (sum, f) => sum + f.size);
    final tooLargeContent = throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('terlalu besar untuk dipulihkan')));
    final tooLargeZip = throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('maksimal')));

    await expectLater(service.buildPackage(now, zipLimit: zip.length - 1), tooLargeZip);
    await expectLater(service.buildPackage(now, entryLimit: largest - 1), tooLargeContent);
    await expectLater(service.buildPackage(now, totalLimit: total - 1), tooLargeContent);
    await first.dispose();
    expect(await work.list().toList(), isEmpty, reason: 'export files cleaned up');
  });

  test('validate rejects oversized entries, understated sizes and unknown entry names', () async {
    await seedData();
    final zip = (await service.buildPackage(now)).file.readAsBytesSync();
    Matcher rejected(String text) => throwsA(isA<BackupException>().having((e) => e.message, 'message', contains(text)));

    final sizes = [for (final f in ZipDecoder().decodeBytes(zip)) f.size];
    final largest = sizes.reduce((a, b) => a > b ? a : b);
    final total = sizes.reduce((a, b) => a + b);
    await expectLater(validateZip(zip, entryLimit: largest - 1), rejected('terlalu besar'));
    await expectLater(validateZip(zip, totalLimit: total - 1), rejected('terlalu besar'));
    expect((await validateZip(zip, entryLimit: largest, totalLimit: total)).manifest.transactions, 3);

    for (final name in ['evil.sh', 'attachments/sub/x.jpg', '../finbro.sqlite']) {
      final withExtra = ZipEncoder().encodeBytes(ZipDecoder().decodeBytes(zip)..add(ArchiveFile.string(name, 'x')));
      await expectLater(validateZip(withExtra), rejected('tidak dikenal'), reason: name);
    }

    // An attachment whose zip headers claim 16 bytes but which inflates to 1 MB.
    const bomb = 'attachments/bomb.jpg';
    final archive = ZipDecoder().decodeBytes(tamper(zip, manifest: (m) => {
      ...m,
      'attachmentFiles': {...(m['attachmentFiles']! as Map), 'att-bomb': bomb},
    }))
      ..add(ArchiveFile.bytes(bomb, Uint8List(1024 * 1024)));
    final bombZip = ZipEncoder().encodeBytes(archive);
    final data = ByteData.sublistView(bombZip);
    final nameBytes = utf8.encode(bomb);
    bool nameAt(int at) => at + nameBytes.length <= bombZip.length &&
        List.generate(nameBytes.length, (i) => bombZip[at + i]).join(',') == nameBytes.join(',');
    var patched = 0;
    for (var i = 0; i + 46 < bombZip.length; i++) {
      final sig = data.getUint32(i, Endian.little);
      if (sig == 0x04034b50 && nameAt(i + 30)) {
        data.setUint32(i + 22, 16, Endian.little);
        patched++;
      } else if (sig == 0x02014b50 && nameAt(i + 46)) {
        data.setUint32(i + 24, 16, Endian.little);
        patched++;
      }
    }
    expect(patched, 2);
    await expectLater(validateZip(bombZip), rejected('rusak'));
  });

  test('entry whose CRC32 does not match its content is rejected', () async {
    // archive 4.3.0 ignores ZipDecoder's `verify` flag, so validation must
    // itself compare the unpacked content against the header CRC.
    await seedData();
    final package = await service.buildPackage(now);

    // ZipEncoder recomputes CRCs when re-encoding, so mutate the encoded
    // bytes directly: every little-endian occurrence of the original CRC
    // (local header and central directory) becomes a stale value.
    final zipBytes = await package.file.readAsBytes();
    final content = ZipDecoder().decodeBytes(zipBytes).findFile('attachments/r1.jpg')!;
    final originalCrc = content.crc32!;
    final staleCrc = originalCrc ^ 0xFFFF;
    final patched = Uint8List.fromList(zipBytes);
    final data = ByteData.sublistView(patched);
    var hits = 0;
    final needle = Uint8List(4)..buffer.asUint32List()[0] = originalCrc;
    bool crcAt(int at) => patched[at] == needle[0] && patched[at + 1] == needle[1] &&
        patched[at + 2] == needle[2] && patched[at + 3] == needle[3];
    for (var i = 0; i + 4 <= patched.length; i++) {
      if (crcAt(i)) {
        data.setUint32(i, staleCrc, Endian.little);
        hits++;
      }
    }
    expect(hits, 2, reason: 'local header and central directory both carry the CRC');
    final crcZip = patched;

    // The content itself still matches the manifest, so only the CRC catches it.
    await expectLater(validateZip(crcZip), throwsA(isA<BackupException>()));
  });
}
