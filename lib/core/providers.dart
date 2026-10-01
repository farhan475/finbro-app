import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database/app_database.dart';

/// Overridden in `main()` (real file) and tests (in-memory).
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

/// Emits whenever any table changes. Read-side providers `ref.watch` this so
/// every derived number is recomputed from source rows after each commit.
final dbChangesProvider = StreamProvider<int>((ref) async* {
  final db = ref.watch(databaseProvider);
  var tick = 0;
  yield tick;
  await for (final _ in db.tableUpdates()) {
    yield ++tick;
  }
});

/// Injectable clock so time-dependent providers are testable.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
