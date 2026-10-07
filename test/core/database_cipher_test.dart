import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/database_cipher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

/// In-memory key store; the delays let concurrent callers interleave like
/// isolates awaiting the platform channel.
class _MemoryKeyStore implements DatabaseKeyStore {
  DatabaseKey? stored;
  int writes = 0;

  @override
  Future<DatabaseKey?> read() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return stored;
  }

  @override
  Future<void> write(DatabaseKey key) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    stored = key;
    writes++;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late File file;
  late _MemoryKeyStore keys;
  final ts = DateTime(2026, 10, 1, 9);

  String header(File f) => String.fromCharCodes(f.readAsBytesSync().take(16));
  const plainHeader = 'SQLite format 3\u0000';

  Future<int> count(AppDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle()).read<int>('c');

  /// Plaintext database as written by an app version before encryption.
  Future<void> writePlaintextDatabase() async {
    final db = AppDatabase(NativeDatabase(file));
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: 'a1', name: 'Dompet', type: AccountType.cash, createdAt: ts, updatedAt: ts,
    ));
    await db.close();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('finbro-cipher-test-');
    file = File(p.join(tmp.path, 'finbro.sqlite'));
    keys = _MemoryKeyStore();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('fresh install: a key is stored and the new database is encrypted', () async {
    final key = await prepareEncryptedDatabase(file, keys);
    expect(keys.stored, key);

    final db = AppDatabase.encrypted(file, key);
    expect(await count(db, 'categories'), greaterThan(0), reason: 'seeded on create');
    await db.close();

    expect(header(file), isNot(plainHeader));
    expect(await databaseFileKind(file), DatabaseFileKind.encrypted);
    expect(await prepareEncryptedDatabase(file, keys), key, reason: 'reopen reuses the stored key');
    expect(keys.writes, 1);
  });

  test('upgrade: a plaintext database is encrypted in place without losing data', () async {
    await writePlaintextDatabase();
    expect(header(file), plainHeader);

    final key = await prepareEncryptedDatabase(file, keys);

    expect(header(file), isNot(plainHeader));
    expect(keys.stored, key);
    expect(tmp.listSync().map((e) => p.basename(e.path)).toSet(),
        {'finbro.sqlite', 'finbro.sqlite.plain-pending', 'finbro.sqlite.key-unconfirmed'},
        reason: 'plaintext kept until a later process confirms the key; no temp file or lock left');
    final db = AppDatabase.encrypted(file, key);
    addTearDown(db.close);
    expect((await db.select(db.accounts).getSingle()).name, 'Dompet');
    expect(await count(db, 'categories'), greaterThan(0));
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, AppDatabase.currentSchemaVersion);
  });

  test('an encrypted database without its key is an error, never a new database', () async {
    final db = AppDatabase.encrypted(file, DatabaseKey.generate());
    await db.customSelect('SELECT 1').get();
    await db.close();
    final before = file.readAsBytesSync();

    await expectLater(prepareEncryptedDatabase(file, keys), throwsA(DatabaseCipherException.keyMissing));
    expect(keys.stored, isNull);
    expect(file.readAsBytesSync(), before);
  });

  test('a wrong key is rejected when the connection is set up', () async {
    final db = AppDatabase.encrypted(file, DatabaseKey.generate());
    await db.customSelect('SELECT 1').get();
    await db.close();

    final raw = sqlite3.open(file.path);
    addTearDown(raw.close);
    expect(() => unlockDatabase(raw, DatabaseKey.generate()), throwsA(DatabaseCipherException.keyRejected));
  });

  test('a failed encryption leaves the plaintext database untouched', () async {
    // Valid header, corrupt pages: the export or its verification fails.
    file.writeAsBytesSync([...plainHeader.codeUnits, ...List.filled(8192, 7)]);
    final before = file.readAsBytesSync();

    await expectLater(prepareEncryptedDatabase(file, keys), throwsA(anything));
    expect(file.readAsBytesSync(), before);
    expect(tmp.listSync().map((e) => p.basename(e.path)).toSet(), {'finbro.sqlite', 'finbro.sqlite.key-unconfirmed'},
        reason: 'no partial copy; the stored key stays marked unconfirmed for the next attempt');
  });

  test('leftovers of an interrupted encryption do not block the next attempt', () async {
    await writePlaintextDatabase();
    File('${file.path}.encrypting').writeAsStringSync('half-written');
    // Lock of a process that died mid-migration.
    File('${file.path}.setup-lock').writeAsStringSync('${pid + 1}');

    final key = await prepareEncryptedDatabase(file, keys).timeout(const Duration(seconds: 10));

    final db = AppDatabase.encrypted(file, key);
    addTearDown(db.close);
    expect((await db.select(db.accounts).getSingle()).id, 'a1');
    expect(tmp.listSync().map((e) => p.basename(e.path)).toSet(),
        {'finbro.sqlite', 'finbro.sqlite.plain-pending', 'finbro.sqlite.key-unconfirmed'});
  });

  test('concurrent first opens agree on one key and encrypt once', () async {
    await writePlaintextDatabase();

    final results = await Future.wait([
      prepareEncryptedDatabase(file, keys),
      prepareEncryptedDatabase(file, keys),
      prepareEncryptedDatabase(file, keys),
    ]);

    expect(results.toSet(), {keys.stored});
    expect(keys.writes, 1);
    final db = AppDatabase.encrypted(file, keys.stored!);
    addTearDown(db.close);
    expect((await db.select(db.accounts).getSingle()).id, 'a1');
  });

  group('key not yet durable (written by an earlier process)', () {
    const later = -1; // any pid other than this test process

    test('a later process that reads the key back drops the plaintext fallback', () async {
      await writePlaintextDatabase();
      final key = await prepareEncryptedDatabase(file, keys);

      expect(await prepareEncryptedDatabase(file, keys, processId: later), key);

      expect(tmp.listSync().map((e) => p.basename(e.path)), ['finbro.sqlite']);
      final db = AppDatabase.encrypted(file, key);
      addTearDown(db.close);
      expect((await db.select(db.accounts).getSingle()).name, 'Dompet');
    });

    test('key lost after a migration: redone from the kept plaintext, nothing lost', () async {
      await writePlaintextDatabase();
      final lost = await prepareEncryptedDatabase(file, keys);
      keys.stored = null; // process died before SharedPreferences flushed

      final key = await prepareEncryptedDatabase(file, keys, processId: later);

      expect(key, isNot(lost));
      expect(header(file), isNot(plainHeader));
      final db = AppDatabase.encrypted(file, key);
      addTearDown(db.close);
      expect((await db.select(db.accounts).getSingle()).name, 'Dompet');
      expect(tmp.listSync().map((e) => p.basename(e.path)).where((n) => n.contains('.unreadable-')), hasLength(1),
          reason: 'the copy encrypted with the lost key is set aside, not deleted');
    });

    test('key lost right after a fresh install: the unreadable file is set aside and a new database starts', () async {
      final lost = await prepareEncryptedDatabase(file, keys);
      final first = AppDatabase.encrypted(file, lost);
      await first.customSelect('SELECT 1').get();
      await first.close();
      keys.stored = null;

      final key = await prepareEncryptedDatabase(file, keys, processId: later);

      final db = AppDatabase.encrypted(file, key);
      addTearDown(db.close);
      expect(await count(db, 'categories'), greaterThan(0));
      expect(tmp.listSync().map((e) => p.basename(e.path)).where((n) => n.contains('.unreadable-')), hasLength(1));
    });

    test('a confirmed key that disappears later is an error, not a reset', () async {
      await prepareEncryptedDatabase(file, keys);
      final first = AppDatabase.encrypted(file, keys.stored!);
      await first.customSelect('SELECT 1').get();
      await first.close();
      await prepareEncryptedDatabase(file, keys, processId: later); // confirms
      keys.stored = null;

      await expectLater(prepareEncryptedDatabase(file, keys, processId: later - 1),
          throwsA(DatabaseCipherException.keyMissing));
      expect(await databaseFileKind(file), DatabaseFileKind.encrypted);
    });
  });

  test('moveDatabaseAside keeps the unreadable file and frees the path', () async {
    final db = AppDatabase.encrypted(file, DatabaseKey.generate());
    await db.customSelect('SELECT 1').get();
    await db.close();
    final before = file.readAsBytesSync();

    final aside = await moveDatabaseAside(file);

    expect(file.existsSync(), isFalse);
    expect(aside.readAsBytesSync(), before);
  });
}
