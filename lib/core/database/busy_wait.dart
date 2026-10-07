import 'dart:io' show sleep;

import 'package:sqlite3/sqlite3.dart';

/// How long a connection waits for a competing one (app, notification,
/// widget, WorkManager, backup/restore) before failing with SQLITE_BUSY.
const busyWait = Duration(seconds: 5);

/// Installs a busy handler that retries for up to [busyWait]. Used instead of
/// `PRAGMA busy_timeout` (which would replace it): SQLite's own sleep is cut
/// short by the Dart VM profiler's SIGPROF in debug builds and `flutter test`,
/// so the pragma gives up after ~50 ms there; `sleep` from `dart:io` resumes
/// after a signal. Runs synchronously on the isolate owning the connection.
void waitWhenBusy(Database db) {
  final waited = Stopwatch();
  db.busyHandler = (count) {
    // count restarts at 0 for every new lock wait.
    if (count == 0) waited.reset();
    waited.start();
    if (waited.elapsed >= busyWait) return false;
    // 1, 2, 4 … 32 ms, then 50 ms per retry.
    sleep(Duration(milliseconds: count < 6 ? 1 << count : 50));
    return true;
  };
}
