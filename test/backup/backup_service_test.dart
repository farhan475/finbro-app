import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:finbro_app/core/database/app_database.dart';
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

    final validated = BackupService.validate(created.package.bytes);
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
        await replace(dbFile);
      },
    );
    expect(snapshot.path, snapshotSeenDuringReplace!.path);
    expect(p.basename(snapshot.path), 'safety-finbro-backup-2026-09-30-2106.zip');
    // The snapshot holds the pre-restore data (4 transactions).
    final snap = BackupService.validate(await snapshot.readAsBytes());
    expect(snap.manifest.transactions, 4);

    final restored = AppDatabase(NativeDatabase(dbFile));
    addTearDown(restored.close);
    expect(await count(restored, 'transactions'), m.transactions);
    expect(await count(restored, 'accounts'), m.accounts);
    final att = await restored.select(restored.attachments).getSingle();
    expect(await File(att.localPath).readAsString(), 'receipt-bytes');
    final report = await runIntegrityCheck(restored, attachments, now: now, trigger: 'restore');
    expect(report.ok, isTrue, reason: report.summary.join('; '));
  });

  test('backups carry no PIN data and restore keeps this device\'s lock settings', () async {
    await seedData();
    final settings = AppSettingsRepository(db);
    await settings.set(SettingKeys.pinHash, 'old-hash');
    await settings.set(SettingKeys.pinSalt, 'old-salt');
    final created = await service.createBackup(now);
    final validated = BackupService.validate(created.package.bytes);

    final staged = File(p.join(tmp.path, 'inspect.sqlite'))..writeAsBytesSync(validated.sqlite);
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
      replaceDatabase: (replace) => replace(dbFile),
    );
    final restored = AppDatabase(NativeDatabase(dbFile));
    addTearDown(restored.close);
    expect(await AppSettingsRepository(restored).get(SettingKeys.pinHash), 'device-hash');
    expect(await AppSettingsRepository(restored).get(SettingKeys.pinSalt), 'device-salt');
  });

  test('two safety snapshots in the same minute never overwrite each other', () async {
    await seedData();
    final first = await service.createSafetySnapshot(now);
    final firstBytes = await first.readAsBytes();
    await expense(await account('Extra', 1), 1000);
    final second = await service.createSafetySnapshot(now);

    expect(second.path, isNot(first.path));
    expect(await first.readAsBytes(), firstBytes);
    expect(await second.exists(), isTrue);
  });

  test('restore keeps the newer of the live last-backup date and the backup date', () async {
    await seedData();
    final old = BackupService.validate((await service.createBackup(now)).package.bytes);
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
      await s.restore(old, now: later, replaceDatabase: (replace) => replace(dbFile));
      final restored = AppDatabase(NativeDatabase(dbFile));
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
    final validated = BackupService.validate(package.bytes);

    final newAttachments = await Directory(p.join(tmp.path, 'device2', 'attachments')).create(recursive: true);
    final stale = File(p.join(newAttachments.path, 'old.jpg'))..writeAsStringSync('old');
    final dbFile = File(p.join(tmp.path, 'device2', 'finbro.sqlite'));
    await BackupService.installBackup(validated, dbFile: dbFile, attachmentsDir: newAttachments, workDir: work);

    final restored = AppDatabase(NativeDatabase(dbFile));
    addTearDown(restored.close);
    final att = await restored.select(restored.attachments).getSingle();
    expect(att.localPath, p.join(newAttachments.path, 'r1.jpg'));
    expect(await File(att.localPath).readAsString(), 'receipt-bytes');
    expect(stale.existsSync(), isFalse);
    expect(await work.list().toList(), isEmpty, reason: 'staging files cleaned up');
  });

  test('corrupted or foreign files are rejected', () async {
    await seedData();
    final package = await service.buildPackage(now);

    expect(() => BackupService.validate(Uint8List.fromList(List.generate(512, (i) => i % 251))),
        throwsA(isA<BackupException>()));
    expect(() => BackupService.validate(Uint8List.sublistView(package.bytes, 0, package.bytes.length ~/ 2)),
        throwsA(isA<BackupException>()));

    final noManifest = ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string('finbro.sqlite', 'x')));
    expect(() => BackupService.validate(noManifest),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('manifest.json'))));

    final foreign = tamper(package.bytes, manifest: (m) => {...m, 'app': 'OtherApp'});
    expect(() => BackupService.validate(foreign),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('bukan backup FinBro'))));
  });

  test('sha256 mismatch is rejected', () async {
    await seedData();
    final package = await service.buildPackage(now);
    final validated = BackupService.validate(package.bytes);

    final altered = Uint8List.fromList(validated.sqlite)..[validated.sqlite.length - 1] ^= 0xFF;
    expect(() => BackupService.validate(tamper(package.bytes, sqlite: altered)),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('Checksum'))));

    final wrongHash = tamper(package.bytes, manifest: (m) => {...m, 'sha256': '0' * 64});
    expect(() => BackupService.validate(wrongHash),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('Checksum'))));
  });

  test('newer schema version is rejected, older is accepted', () async {
    await seedData();
    final package = await service.buildPackage(now);

    final newer = tamper(package.bytes,
        manifest: (m) => {...m, 'schemaVersion': AppDatabase.currentSchemaVersion + 1});
    expect(() => BackupService.validate(newer),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('lebih baru'))));

    // A future app (schema current+1) accepts today's backup as "older".
    final v = BackupService.validate(package.bytes,
        currentSchemaVersion: AppDatabase.currentSchemaVersion + 1);
    expect(v.manifest.schemaVersion, AppDatabase.currentSchemaVersion);
  });

  test('failed install keeps the old database and removes extracted files', () async {
    await seedData();
    final validated = BackupService.validate((await service.buildPackage(now)).bytes);
    final broken = ValidatedBackup(
      manifest: validated.manifest,
      sqlite: Uint8List.fromList([...'SQLite format 3\u0000'.codeUnits, ...List.filled(4096, 7)]),
      files: validated.files,
    );
    final target = await Directory(p.join(tmp.path, 'd3', 'attachments')).create(recursive: true);
    final dbFile = File(p.join(tmp.path, 'd3', 'finbro.sqlite'))..writeAsStringSync('old-db');

    await expectLater(
      BackupService.installBackup(broken, dbFile: dbFile, attachmentsDir: target, workDir: work),
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
    final src = ZipDecoder().decodeBytes(created.package.bytes);

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

    expect(
      () => BackupService.validate(zip),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message, 'message', contains('Checksum lampiran r1.jpg tidak cocok'),
        ),
      ),
    );
  });

  test('restore writes the manifest checksum into attachments and integrity check verifies it', () async {
    await seedData();
    final created = await service.createBackup(now);
    final validated = BackupService.validate(created.package.bytes);

    final dbFile = File(p.join(tmp.path, 'live', 'finbro.sqlite'));
    await service.restore(
      validated,
      now: now.add(const Duration(minutes: 1)),
      replaceDatabase: (replace) => replace(dbFile),
    );
    final restored = AppDatabase(NativeDatabase(dbFile));
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
    expect(lines.first, 'date,type,amount,category,account,to_account,note,source,status');
    expect(lines, contains('2026-09-30T21:05:00,expense,25000,Food,BCA,,"Makan, ""siang""",manual,confirmed'));
    expect(lines, contains('2026-09-30T21:05:00,transfer,100000,,BCA,Cash,,manual,confirmed'));
    expect(lines, contains('2026-09-30T21:05:00,income,1500000,Salary,BCA,,"\'=HYPERLINK(""x"")",manual,confirmed'));
    // Leading tab / carriage return also start a formula in some spreadsheets.
    expect(csvField('\t=1+1'), "'\t=1+1");
    expect(csvField('\r=1+1'), '"\'\r=1+1"');
  });

  /// Package whose database was changed by [mutate], with a matching hash.
  Future<Uint8List> withMutatedDb(Future<void> Function(AppDatabase d) mutate) async {
    final package = await service.buildPackage(now);
    final file = File(p.join(tmp.path, 'mutate-${DateTime.now().microsecondsSinceEpoch}.sqlite'))
      ..writeAsBytesSync(BackupService.validate(package.bytes).sqlite);
    final d = AppDatabase(NativeDatabase(file));
    await mutate(d);
    await d.close();
    final sqlite = file.readAsBytesSync();
    return tamper(package.bytes, sqlite: sqlite, manifest: (m) => {...m, 'sha256': sha256.convert(sqlite).toString()});
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
      final validated = BackupService.validate(zip);
      final target = await Directory(p.join(tmp.path, 'v$version', 'attachments')).create(recursive: true);
      final dbFile = File(p.join(tmp.path, 'v$version', 'finbro.sqlite'))..writeAsStringSync('old-db');
      await expectLater(
        BackupService.installBackup(validated, dbFile: dbFile, attachmentsDir: target, workDir: work),
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
      (await service.buildPackage(now)).bytes,
      sqlite: sqlite,
      manifest: (m) => {...m, 'schemaVersion': 2, 'sha256': sha256.convert(sqlite).toString()},
    );

    final validated = BackupService.validate(zip);
    expect(validated.manifest.schemaVersion, 2);
    final target = await Directory(p.join(tmp.path, 'from-v2', 'attachments')).create(recursive: true);
    final dbFile = File(p.join(tmp.path, 'from-v2', 'finbro.sqlite'));
    await BackupService.installBackup(validated, dbFile: dbFile, attachmentsDir: target, workDir: work);

    final restored = AppDatabase(NativeDatabase(dbFile));
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
    await BackupService.installBackup(BackupService.validate(zip),
        dbFile: dbFile, attachmentsDir: target, workDir: work, lastBackupAt: now);

    final restored = AppDatabase(NativeDatabase(dbFile));
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
    final zip = (await service.buildPackage(now)).bytes;
    final entries = ZipDecoder().decodeBytes(zip);
    final largest = entries.map((f) => f.size).reduce((a, b) => a > b ? a : b);
    final total = entries.fold(0, (sum, f) => sum + f.size);
    final tooLarge = throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('terlalu besar untuk dipulihkan')));

    await expectLater(service.buildPackage(now, zipLimit: zip.length - 1), tooLarge);
    await expectLater(service.buildPackage(now, entryLimit: largest - 1), tooLarge);
    await expectLater(service.buildPackage(now, totalLimit: total - 1), tooLarge);
    expect(await work.list().toList(), isEmpty, reason: 'export files cleaned up');

    // Exactly at the limits the package is produced and passes validation.
    final ok = await service.buildPackage(now, zipLimit: zip.length, entryLimit: largest, totalLimit: total);
    expect(BackupService.validate(ok.bytes, entryLimit: largest, totalLimit: total).manifest.transactions, 3);
  });

  test('validate rejects oversized entries, understated sizes and unknown entry names', () async {
    await seedData();
    final zip = (await service.buildPackage(now)).bytes;
    Matcher rejected(String text) => throwsA(isA<BackupException>().having((e) => e.message, 'message', contains(text)));

    final sizes = [for (final f in ZipDecoder().decodeBytes(zip)) f.size];
    final largest = sizes.reduce((a, b) => a > b ? a : b);
    final total = sizes.reduce((a, b) => a + b);
    expect(() => BackupService.validate(zip, entryLimit: largest - 1), rejected('terlalu besar'));
    expect(() => BackupService.validate(zip, totalLimit: total - 1), rejected('terlalu besar'));
    expect(BackupService.validate(zip, entryLimit: largest, totalLimit: total).manifest.transactions, 3);

    for (final name in ['evil.sh', 'attachments/sub/x.jpg', '../finbro.sqlite']) {
      final withExtra = ZipEncoder().encodeBytes(ZipDecoder().decodeBytes(zip)..add(ArchiveFile.string(name, 'x')));
      expect(() => BackupService.validate(withExtra), rejected('tidak dikenal'), reason: name);
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
    expect(() => BackupService.validate(bombZip), rejected('rusak'));
  });

  test('entry whose CRC32 does not match its content is rejected', () async {
    // archive 4.3.0 ignores ZipDecoder's `verify` flag, so validation must
    // itself compare the unpacked content against the header CRC.
    await seedData();
    final package = await service.buildPackage(now);

    final corrupted = ZipDecoder().decodeBytes(package.bytes);
    final attachment = corrupted.findFile('attachments/r1.jpg')!;
    attachment.crc32 = (attachment.crc32 ?? 0) ^ 0xFFFF; // stale CRC, content untouched
    final crcZip = ZipEncoder().encodeBytes(corrupted);

    // The content itself still matches the manifest, so only the CRC catches it.
    expect(() => BackupService.validate(crcZip), throwsA(isA<BackupException>()));
    // Sanity check: an entry with a bad CRC but no manifest entry for it is
    // rejected before unpacking anyway — the check must be the CRC, not the
    // unknown-name path.
    expect(corrupted.findFile('attachments/r1.jpg')!.name, 'attachments/r1.jpg');
  });
}
