import 'backup_manifest.dart';

/// Outcome of a database swap, handed from the restore flow (whose screen is
/// disposed when [FinBroRoot] rebuilds the provider tree) to the
/// `RestoreResultOverlay` mounted in the new tree.
sealed class RestoreOutcome {
  const RestoreOutcome();
}

class RestoreSucceeded extends RestoreOutcome {
  const RestoreSucceeded({required this.manifest, required this.snapshotName});
  final BackupManifest manifest;
  final String snapshotName;
}

class RestoreFailed extends RestoreOutcome {
  const RestoreFailed({required this.message, required this.snapshotName});
  final String message;
  final String snapshotName;
}

/// Process-wide mailbox; survives the provider scope being recreated.
abstract final class RestoreSession {
  static RestoreOutcome? _pending;

  static void post(RestoreOutcome outcome) => _pending = outcome;

  /// Returns and clears the pending outcome.
  static RestoreOutcome? take() {
    final o = _pending;
    _pending = null;
    return o;
  }
}
