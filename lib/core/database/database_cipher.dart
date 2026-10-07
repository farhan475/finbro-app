import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:convert/convert.dart' show hex;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqlite3/sqlite3.dart';

import '../utilities/app_logger.dart';
import 'busy_wait.dart';

/// Raw 256-bit SQLCipher key of the live database. Passed to SQLCipher as
/// `x'…'`, so opening skips key derivation. Never logged: [toString] hides it.
final class DatabaseKey {
  const DatabaseKey._(this._hex);

  /// A fresh random key (once per device).
  factory DatabaseKey.generate() {
    final random = Random.secure();
    return DatabaseKey._(hex.encode(List.generate(32, (_) => random.nextInt(256))));
  }

  /// Null unless [value] is 64 hex characters.
  static DatabaseKey? tryParse(String? value) {
    final v = value?.toLowerCase();
    if (v == null || !_hexKey.hasMatch(v)) return null;
    return DatabaseKey._(v);
  }

  static final _hexKey = RegExp(r'^[0-9a-f]{64}$');

  final String _hex;

  /// Storage form; only for [DatabaseKeyStore] implementations.
  String encode() => _hex;

  /// SQLCipher raw-key literal for `PRAGMA key` and `ATTACH … KEY`.
  String get _literal => "x'$_hex'";

  @override
  bool operator ==(Object other) => other is DatabaseKey && other._hex == _hex;

  @override
  int get hashCode => _hex.hashCode;

  @override
  String toString() => 'DatabaseKey(…)';
}

/// Where the device keeps its [DatabaseKey].
abstract interface class DatabaseKeyStore {
  Future<DatabaseKey?> read();
  Future<void> write(DatabaseKey key);
}

/// [DatabaseKey] in flutter_secure_storage: AES-GCM data wrapped by an Android
/// Keystore key, in its own namespace (prefs + Keystore alias). App data is
/// excluded from Android backup and device transfer, so the key never leaves
/// the device. Readable headless (notification, widget and WorkManager
/// engines): no user-authentication requirement on the Keystore key.
class SecureDatabaseKeyStore implements DatabaseKeyStore {
  const SecureDatabaseKeyStore();

  static const _storage = FlutterSecureStorage(
    // resetOnError off: a Keystore failure must surface as an error, never
    // wipe the only key to the database.
    aOptions: AndroidOptions(storageNamespace: 'finbro_database', resetOnError: false),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _name = 'finbro_db_key_v1';

  @override
  Future<DatabaseKey?> read() async => DatabaseKey.tryParse(await _storage.read(key: _name));

  @override
  Future<void> write(DatabaseKey key) => _storage.write(key: _name, value: key.encode());
}

/// The live database cannot be opened with the device key (missing key,
/// wrong key, or SQLite without SQLCipher). Never answered by creating a new
/// database.
class DatabaseCipherException implements Exception {
  const DatabaseCipherException(this.message);
  final String message;

  static const keyMissing = DatabaseCipherException(
    'Kunci enkripsi database tidak ditemukan di perangkat ini, jadi data FinBro tidak dapat dibuka. '
    'Pulihkan dari file backup FinBro.',
  );
  static const keyRejected = DatabaseCipherException(
    'Database FinBro tidak dapat dibuka dengan kunci enkripsi perangkat ini. '
    'Pulihkan dari file backup FinBro.',
  );
  static const cipherUnavailable = DatabaseCipherException(
    'Enkripsi database (SQLCipher) tidak tersedia di build ini; database tidak dibuka tanpa enkripsi.',
  );

  @override
  String toString() => 'DatabaseCipherException: $message';
}

/// Setup for every connection to an encrypted database, before drift reads
/// anything: `PRAGMA key` first, then the busy handler ([waitWhenBusy]; the
/// open itself waits for a competing connection instead of failing with
/// SQLITE_BUSY). Fails closed when SQLCipher is not the loaded library or
/// [key] does not open the file.
void unlockDatabase(Database db, DatabaseKey key) {
  _keyed(db, 'PRAGMA key = "${key._literal}"');
  waitWhenBusy(db);
  _requireCipher(db);
  try {
    db.select('SELECT count(*) FROM sqlite_master');
  } on SqliteException catch (e) {
    if (e.resultCode == _sqliteNotADb) throw DatabaseCipherException.keyRejected;
    rethrow;
  }
}

/// What lies at the database path.
enum DatabaseFileKind {
  /// No file, or an empty one: SQLite creates the database on open.
  missing,

  /// Plain SQLite (`SQLite format 3\0` header), e.g. from an app version
  /// before encryption.
  plaintext,

  /// Anything else: an encrypted database (or garbage SQLCipher rejects).
  encrypted,
}

Future<DatabaseFileKind> databaseFileKind(File file) async {
  if (!await file.exists() || await file.length() == 0) return DatabaseFileKind.missing;
  final raf = await file.open();
  try {
    final head = await raf.read(_sqliteMagic.length);
    return String.fromCharCodes(head) == _sqliteMagic ? DatabaseFileKind.plaintext : DatabaseFileKind.encrypted;
  } finally {
    await raf.close();
  }
}

/// Makes the database at [file] ready to open with the device key and
/// returns that key:
/// - no database yet: a new key is generated and stored (the database is
///   then created encrypted);
/// - plaintext database: the key is created if needed and the file is
///   encrypted in place ([_encryptInPlace]);
/// - encrypted database: the stored key; without one this throws
///   [DatabaseCipherException.keyMissing] and leaves the file untouched.
///
/// The key store persists asynchronously (Android `SharedPreferences.apply`
/// in flutter_secure_storage), so a key written by this process is only
/// trusted once a LATER process reads it back and it opens the live file.
/// Until then the plaintext source of a migration is kept
/// (`.plain-pending`) and a marker (`.key-unconfirmed`, holding the writer's
/// pid) records the unconfirmed key. If the key turns out lost, the
/// migration is redone from the kept plaintext, or — for a database created
/// with that key — the unreadable file is moved aside ([moveDatabaseAside])
/// and a new one created. A key confirmed earlier is never second-guessed:
/// losing it is [DatabaseCipherException.keyMissing].
///
/// Key creation and migration run under a lock file next to the database,
/// so isolates opening at the same time (app, notification, widget,
/// WorkManager) agree on one key and encrypt once. [processId] is the
/// current process (tests simulate a restart with another value).
Future<DatabaseKey> prepareEncryptedDatabase(File file, DatabaseKeyStore keys, {int? processId}) async {
  final self = processId ?? pid;
  final pending = _plainPending(file);
  final marker = _keyMarker(file);
  final stored = await keys.read();
  if (stored != null &&
      await databaseFileKind(file) != DatabaseFileKind.plaintext &&
      !await pending.exists() &&
      !await marker.exists()) {
    return stored;
  }
  return _withSetupLock(file, () async {
    var kind = await databaseFileKind(file);
    var key = await keys.read();
    final markerPid = await _readPid(marker);
    final unconfirmed = markerPid != null && markerPid != self;

    // Died between the two renames of a migration: the kept plaintext is the
    // only complete database.
    if (kind == DatabaseFileKind.missing && await pending.exists()) {
      await _deleteDatabaseFiles(File('${file.path}.encrypting'));
      await pending.rename(file.path);
      kind = DatabaseFileKind.plaintext;
    }
    if (key == null && kind == DatabaseFileKind.encrypted && unconfirmed) {
      // The key written by an earlier process never reached storage.
      final aside = await moveDatabaseAside(file);
      AppLogger.error('Kunci database baru hilang sebelum tersimpan; database dipindah ke ${aside.path}');
      if (await pending.exists()) {
        await pending.rename(file.path);
        kind = DatabaseFileKind.plaintext;
      } else {
        kind = DatabaseFileKind.missing;
      }
      await _deleteIfPresent(marker);
    }
    if (key == null) {
      if (kind == DatabaseFileKind.encrypted) throw DatabaseCipherException.keyMissing;
      key = DatabaseKey.generate();
      // Stored, and marked unconfirmed, before any file is encrypted with it.
      await keys.write(key);
      await marker.writeAsString('$self', flush: true);
    } else if (unconfirmed && kind == DatabaseFileKind.encrypted) {
      if (await _opensWith(file, key)) {
        // A later process read the key back and it opens the live file: the
        // key is durable, the plaintext fallback can go.
        await _deleteDatabaseFiles(pending);
        await _deleteIfPresent(marker);
      } else if (await pending.exists()) {
        // The stored key is not the one the migration used: redo it.
        await moveDatabaseAside(file);
        await pending.rename(file.path);
        kind = DatabaseFileKind.plaintext;
      }
    }
    if (kind == DatabaseFileKind.plaintext) {
      if (!await marker.exists()) await marker.writeAsString('$self', flush: true);
      await _encryptInPlace(file, key);
    }
    return key;
  });
}

/// Moves the database at [file] (and its side files) to
/// `<name>.unreadable-<timestamp>` so a new database can be created; nothing
/// is deleted. Returns the moved main file.
Future<File> moveDatabaseAside(File file) async {
  final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');
  final aside = File('${file.path}.unreadable-$stamp');
  for (final suffix in const ['', '-journal', '-wal', '-shm']) {
    final f = File('${file.path}$suffix');
    if (await f.exists()) await f.rename('${aside.path}$suffix');
  }
  return aside;
}

/// Plaintext source of a migration, kept until the new key is confirmed.
File _plainPending(File file) => File('${file.path}.plain-pending');

/// Present while the stored key has not been read back by a later process.
File _keyMarker(File file) => File('${file.path}.key-unconfirmed');

Future<int?> _readPid(File marker) async {
  try {
    return int.tryParse((await marker.readAsString()).trim());
  } on FileSystemException {
    return null;
  }
}

/// Whether [key] opens the encrypted database at [file].
Future<bool> _opensWith(File file, DatabaseKey key) => Isolate.run(() {
  final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    unlockDatabase(db, key);
    return true;
  } on DatabaseCipherException {
    return false;
  } finally {
    db.close();
  }
});

/// Writes a verified copy of the database at [source] (opened with
/// [sourceKey], plaintext when null) to [target] (encrypted with [targetKey],
/// plaintext when null), replacing [target]. The copy is checked on a fresh
/// connection: `integrity_check`, `user_version` and the row count of every
/// table must match. On failure [target] is removed and [source] untouched.
Future<void> exportDatabase({
  required File source,
  DatabaseKey? sourceKey,
  required File target,
  DatabaseKey? targetKey,
}) async {
  if (!await source.exists()) throw FileSystemException('Database tidak ditemukan', source.path);
  await _deleteDatabaseFiles(target);
  try {
    await Isolate.run(() => _export(source.path, sourceKey, target.path, targetKey));
  } catch (_) {
    await _deleteDatabaseFiles(target);
    rethrow;
  }
}

/// Deletes a database file and its journal/WAL side files, if present.
Future<void> _deleteDatabaseFiles(File file) async {
  await _deleteIfPresent(file);
  await _deleteSideFiles(file);
}

Future<void> _deleteSideFiles(File file) async {
  for (final suffix in const ['-journal', '-wal', '-shm']) {
    await _deleteIfPresent(File('${file.path}$suffix'));
  }
}

const _sqliteMagic = 'SQLite format 3\u0000';
const _sqliteNotADb = 26;

/// Encrypts the plaintext database at [file] with [key]. Crash-safe: the
/// verified encrypted copy replaces the live file, and the plaintext is kept
/// as `.plain-pending` until the key is confirmed by a later process (see
/// [prepareEncryptedDatabase]), so a key lost before reaching storage never
/// costs data.
Future<void> _encryptInPlace(File file, DatabaseKey key) async {
  final encrypted = File('${file.path}.encrypting');
  final pending = _plainPending(file);
  await exportDatabase(source: file, target: encrypted, targetKey: key);
  // The plaintext connection closed cleanly, so these hold nothing live; a
  // plaintext journal next to the encrypted file would corrupt it.
  await _deleteSideFiles(file);
  await _deleteDatabaseFiles(pending);
  await file.rename(pending.path);
  await encrypted.rename(file.path);
  AppLogger.info('Database dienkripsi dengan SQLCipher');
}

void _export(String sourcePath, DatabaseKey? sourceKey, String targetPath, DatabaseKey? targetKey) {
  final int version;
  final Map<String, int> counts;
  // Default mode (read/write/create): ATTACH opens the target with the main
  // database's flags and must create it. exportDatabase checked the source.
  final source = sqlite3.open(sourcePath);
  try {
    if (sourceKey != null) {
      unlockDatabase(source, sourceKey);
    } else {
      _requireCipher(source);
    }
    _keyed(source, 'ATTACH DATABASE ? AS finbro_target KEY ?', [targetPath, targetKey?._literal ?? '']);
    try {
      source.execute('BEGIN');
      try {
        version = source.select('PRAGMA main.user_version').single.values.single as int;
        counts = _rowCounts(source);
        source.select("SELECT sqlcipher_export('finbro_target')");
        // sqlcipher_export copies schema and rows, not the schema version.
        source.execute('PRAGMA finbro_target.user_version = $version');
        source.execute('COMMIT');
      } catch (_) {
        if (!source.autocommit) source.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      source.execute('DETACH DATABASE finbro_target');
    }
  } finally {
    source.close();
  }

  final copy = sqlite3.open(targetPath, mode: OpenMode.readWrite);
  try {
    if (targetKey != null) unlockDatabase(copy, targetKey);
    final integrity = copy.select('PRAGMA integrity_check').map((r) => '${r.values.single}').toList();
    if (integrity.length != 1 || integrity.single != 'ok') {
      throw StateError('Salinan database rusak: ${integrity.first}');
    }
    final copied = copy.select('PRAGMA user_version').single.values.single as int;
    if (copied != version) throw StateError('Salinan database: user_version $copied ≠ $version');
    final copiedCounts = _rowCounts(copy);
    for (final MapEntry(key: table, value: rows) in counts.entries) {
      if (copiedCounts[table] != rows) {
        throw StateError('Salinan database: tabel $table ${copiedCounts[table]} baris, sumber $rows');
      }
    }
  } finally {
    copy.close();
  }
}

/// Row count of every user table in the main schema.
Map<String, int> _rowCounts(Database db) => {
  for (final row in db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
    row['name'] as String: db
        .select('SELECT count(*) AS c FROM "${(row['name'] as String).replaceAll('"', '""')}"')
        .single['c'] as int,
};

void _requireCipher(Database db) {
  final rows = db.select('PRAGMA cipher_version');
  final version = rows.isEmpty ? null : rows.first.values.first;
  if (version == null || '$version'.isEmpty) throw DatabaseCipherException.cipherUnavailable;
}

/// Runs a statement carrying a key; a failure is rethrown without the
/// statement text and parameters so the key never reaches a log.
void _keyed(Database db, String sql, [List<Object?> parameters = const []]) {
  try {
    db.execute(sql, parameters);
  } on SqliteException catch (e, s) {
    Error.throwWithStackTrace(
      SqliteException(
        extendedResultCode: e.extendedResultCode,
        message: e.message,
        explanation: e.explanation,
        operation: e.operation,
      ),
      s,
    );
  }
}

/// Lock held while the device key is created or a plaintext database is
/// encrypted. An exclusive create works across isolates of one process (a
/// POSIX file lock would not). A lock left by a dead process, or older than
/// any migration takes, is stale and removed ([_breakIfStale]).
Future<T> _withSetupLock<T>(File db, Future<T> Function() action) async {
  final lock = File('${db.path}.setup-lock');
  await db.parent.create(recursive: true);
  while (true) {
    try {
      await lock.create(exclusive: true);
      break;
    } on PathExistsException {
      if (!await _breakIfStale(lock)) await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  try {
    await lock.writeAsString('$pid', flush: true);
    return await action();
  } finally {
    await _deleteIfPresent(lock);
  }
}

const _staleLockAge = Duration(minutes: 2);

/// Removes [lock] if it is stale; true when it did. Only the holder of the
/// `.break` guard decides and deletes, so two isolates breaking the same
/// stale lock can never delete the fresh lock one of them created meanwhile.
Future<bool> _breakIfStale(File lock) async {
  final guard = File('${lock.path}.break');
  try {
    await guard.create(exclusive: true);
  } on PathExistsException {
    // Another isolate is breaking it; a guard left by a crash only ages.
    if (await _olderThan(guard, _staleLockAge)) await _deleteIfPresent(guard);
    return false;
  }
  try {
    final owner = int.tryParse((await lock.readAsString()).trim());
    // Every isolate of the app shares one process: another pid is a dead one.
    if ((owner != null && owner != pid) || await _olderThan(lock, _staleLockAge)) {
      await _deleteIfPresent(lock);
      AppLogger.info('Kunci setup database usang dilepas');
      return true;
    }
    return false;
  } on FileSystemException {
    return false; // released meanwhile; the next create attempt decides
  } finally {
    await _deleteIfPresent(guard);
  }
}

Future<bool> _olderThan(File f, Duration age) async {
  try {
    return DateTime.now().difference(await f.lastModified()) > age;
  } on FileSystemException {
    return false;
  }
}

/// Deletes [f]; a missing file is fine, any other failure throws (a stale
/// plaintext journal must never survive next to an encrypted database).
Future<void> _deleteIfPresent(File f) async {
  try {
    await f.delete();
  } on PathNotFoundException {
    // Already gone.
  }
}
