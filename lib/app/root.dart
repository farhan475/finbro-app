import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/providers.dart';
import '../core/utilities/app_logger.dart';
import 'app.dart';
import 'app_wiring.dart';

/// Owns the database connection. Restore replaces the DB file through
/// [FinBroRoot.replaceDatabase], which closes the connection first and
/// rebuilds the whole provider tree afterwards.
class FinBroRoot extends StatefulWidget {
  const FinBroRoot({super.key});

  /// Closes the live DB, runs [replace] with the DB file path, reopens it and
  /// restarts all providers. Throws whatever [replace] throws (after
  /// reopening the DB so the app stays usable).
  static Future<void> replaceDatabase(
    BuildContext context,
    Future<void> Function(File dbFile) replace,
  ) => context.findAncestorStateOfType<_FinBroRootState>()!._replace(replace);

  @override
  State<FinBroRoot> createState() => _FinBroRootState();
}

class _FinBroRootState extends State<FinBroRoot> {
  AppDatabase? _db;
  Key _scopeKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final db = AppDatabase.open(await databaseFile());
    setState(() {
      _db = db;
      _scopeKey = UniqueKey();
    });
  }

  Future<void> _replace(Future<void> Function(File dbFile) replace) async {
    final old = _db;
    setState(() => _db = null);
    await old?.close();
    try {
      await replace(await databaseFile());
    } catch (e, s) {
      AppLogger.error('Penggantian database gagal', e, s);
      await _open();
      rethrow;
    }
    await _open();
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = _db;
    if (db == null) {
      return const ColoredBox(color: Color(0xFF0B0B0B));
    }
    return ProviderScope(
      key: _scopeKey,
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...wiringOverrides(),
      ],
      child: const FinBroApp(),
    );
  }
}
