import 'dart:io';

import 'package:drift/drift.dart' show DriftWrappedException;
import 'package:drift/native.dart' show SqliteException;
// Background-isolate DB (`createInBackground`) surfaces SQLite failures
// wrapped in this type; unwrapping it is the only way to redact them.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Local-only error log (no network). File lives in app-private storage and
/// is rotated at [_maxBytes]; the previous file is kept as `finbro.log.1`.
abstract final class AppLogger {
  static const _maxBytes = 512 * 1024;
  static File? _file;

  static File? get file => _file;

  static File _rotated(File f) => File('${f.path}.1');

  static Future<void> init(Directory dir) async {
    final f = File(p.join(dir.path, 'logs', 'finbro.log'));
    await f.parent.create(recursive: true);
    _rotateIfFull(f);
    _file = f;
  }

  static void info(String message) => _write('INFO', message);

  static void error(String message, [Object? error, StackTrace? stack]) {
    final buf = StringBuffer(message);
    if (error != null) buf.write(' | ${describeError(error)}');
    if (stack != null) buf.write('\n$stack');
    _write('ERROR', buf.toString());
  }

  /// `error.toString()`, except that SQLite failures drop the statement and
  /// its bound parameters (amounts, notes, merchant names).
  @visibleForTesting
  static String describeError(Object error) => switch (error) {
    SqliteException(:final extendedResultCode, :final operation, :final message, :final explanation) =>
      'SqliteException($extendedResultCode): '
          '${operation == null ? '' : 'while $operation, '}$message'
          '${explanation == null ? '' : ', $explanation'}',
    DriftRemoteException(:final remoteCause) => describeError(remoteCause),
    DriftWrappedException(:final cause?, :final message) => '${describeError(cause)} ($message)',
    _ => '$error',
  };

  static void _write(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} [$level] $message\n';
    if (kDebugMode) debugPrint(line.trimRight());
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
      _rotateIfFull(f);
    } catch (_) {
      // Logging must never crash the app.
    }
  }

  static void _rotateIfFull(File f) {
    if (f.existsSync() && f.lengthSync() > _maxBytes) f.renameSync(_rotated(f).path);
  }

  static Future<String> read() async {
    final f = _file;
    if (f == null || !await f.exists()) return '';
    return f.readAsString();
  }

  /// Empties the log and deletes the rotated previous file.
  static Future<void> clear() async {
    final f = _file;
    if (f == null) return;
    if (await f.exists()) await f.writeAsString('');
    final old = _rotated(f);
    if (await old.exists()) await old.delete();
  }
}
