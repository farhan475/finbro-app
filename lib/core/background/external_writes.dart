import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../providers.dart';

final externalWritesProvider = Provider<ExternalWrites>((ref) => ExternalWrites(ref.watch(databaseProvider)));

/// Drift only re-runs stream queries after writes on its own connection, so
/// commits by other connections — the periodic background job, notification
/// actions — would stay invisible while the app process lives on. [check]
/// (a lifecycle task) compares SQLite's `data_version`, which changes
/// exactly when another connection committed, and then re-runs every
/// stream query of this connection.
class ExternalWrites {
  ExternalWrites(this._db);

  final AppDatabase _db;
  int? _seen;

  Future<void> check(DateTime now) async {
    final version = (await _db.customSelect('PRAGMA data_version').getSingle()).read<int>('data_version');
    final seen = _seen;
    _seen = version;
    if (seen != null && seen != version) {
      _db.notifyUpdates({for (final table in _db.allTables) TableUpdate.onTable(table)});
    }
  }
}
