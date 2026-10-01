import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
  });
}
