import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/database/database_cipher.dart';
import '../core/providers.dart';
import '../core/utilities/app_logger.dart';
import '../shared/widgets/fin_widgets.dart';
import 'app.dart';
import 'app_wiring.dart';
import 'theme/app_theme.dart';

/// Owns the database connection. Restore replaces the DB file through
/// [FinBroRoot.replaceDatabase], which closes the connection first and
/// rebuilds the whole provider tree afterwards.
class FinBroRoot extends StatefulWidget {
  const FinBroRoot({super.key});

  /// Closes the live DB, runs [replace] with the live database (file + device
  /// key), reopens it and restarts all providers. Throws whatever [replace]
  /// throws (after reopening the DB so the app stays usable).
  static Future<void> replaceDatabase(
    BuildContext context,
    Future<void> Function(DeviceDatabase live) replace,
  ) => context.findAncestorStateOfType<_FinBroRootState>()!._replace(replace);

  @override
  State<FinBroRoot> createState() => _FinBroRootState();
}

class _FinBroRootState extends State<FinBroRoot> {
  AppDatabase? _db;
  Key _scopeKey = UniqueKey();

  /// Why the database could not be opened; shown instead of the app.
  String? _openError;

  /// The failure is the device key (missing/rejected): the user may set the
  /// unreadable file aside and start over (then restore a backup).
  bool _keyProblem = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final db = await openDeviceDatabase();
      if (!mounted) {
        await db.close();
        return;
      }
      setState(() {
        _db = db;
        _openError = null;
        _keyProblem = false;
        _scopeKey = UniqueKey();
      });
    } catch (e, s) {
      AppLogger.error('Database tidak dapat dibuka', e, s);
      if (!mounted) return;
      setState(() {
        _keyProblem = e == DatabaseCipherException.keyMissing || e == DatabaseCipherException.keyRejected;
        _openError = e is DatabaseCipherException
            ? e.message
            : 'Terjadi kesalahan saat membuka data FinBro. Coba lagi; jika tetap gagal, pulihkan dari file backup.';
      });
    }
  }

  void _retry() {
    setState(() => _openError = null);
    _open();
  }

  Future<void> _startFresh(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mulai dengan database baru?'),
        content: const Text(
          'Data yang tidak dapat dibuka tidak dihapus: file lama disimpan terpisah di perangkat. '
          'FinBro akan dimulai kosong; setelah itu Anda dapat memulihkan data dari file backup '
          '(Pengaturan → Backup & Restore).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Mulai baru')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final aside = await setAsideDeviceDatabase();
      AppLogger.info('Database yang tidak terbaca dipindah ke ${aside.path}');
    } catch (e, s) {
      AppLogger.error('Memindahkan database gagal', e, s);
    }
    _retry();
  }

  Future<void> _replace(Future<void> Function(DeviceDatabase live) replace) async {
    final old = _db;
    setState(() => _db = null);
    try {
      await old?.close();
      await replace(await deviceDatabase());
    } catch (e, s) {
      AppLogger.error('Penggantian database gagal', e, s);
      rethrow;
    } finally {
      // Reopen even when closing the old connection failed, so the app never
      // stays on the blank placeholder.
      await _open();
    }
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _openError;
    if (error != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmptyState(
                    icon: Icons.lock_outline,
                    title: 'Data FinBro tidak dapat dibuka',
                    message: error,
                    actionLabel: 'Coba lagi',
                    onAction: _retry,
                  ),
                  if (_keyProblem)
                    TextButton(
                      onPressed: () => _startFresh(context),
                      child: const Text('Mulai dengan database baru'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
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
