import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Local-only error log (no network). File lives in app-private storage and
/// is rotated at [_maxBytes]; the previous file is kept as `finbro.log.1`.
abstract final class AppLogger {
  static const _maxBytes = 512 * 1024;
  static File? _file;

  static File? get file => _file;

  static Future<void> init(Directory dir) async {
    final f = File(p.join(dir.path, 'logs', 'finbro.log'));
    await f.parent.create(recursive: true);
    if (await f.exists() && await f.length() > _maxBytes) {
      await f.rename('${f.path}.1');
    }
    _file = f;
  }

  static void info(String message) => _write('INFO', message);

  static void error(String message, [Object? error, StackTrace? stack]) {
    final buf = StringBuffer(message);
    if (error != null) buf.write(' | $error');
    if (stack != null) buf.write('\n$stack');
    _write('ERROR', buf.toString());
  }

  static void _write(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} [$level] $message\n';
    if (kDebugMode) debugPrint(line.trimRight());
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never crash the app.
    }
  }

  static Future<String> read() async {
    final f = _file;
    if (f == null || !await f.exists()) return '';
    return f.readAsString();
  }

  static Future<void> clear() async {
    final f = _file;
    if (f != null && await f.exists()) await f.writeAsString('');
  }
}
