import 'dart:async';
import 'dart:io' show Platform;

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../providers.dart';
import '../utilities/app_logger.dart';
import 'widget_background.dart';

/// Asks the launcher to add the FinBro widget (Android 8+ pin dialog).
/// False when the launcher cannot pin widgets or off Android: the user adds
/// it from the launcher's widget list instead.
Future<bool> requestPinWidget() async {
  if (!Platform.isAndroid) return false;
  try {
    return await widgetChannel.invokeMethod<bool>('requestPin') ?? false;
  } on PlatformException catch (e, s) {
    AppLogger.error('Permintaan pasang widget gagal', e, s);
    return false;
  }
}

/// Screens a tapped widget section opens. Kotlin sends the [name]; any other
/// value is ignored, so the exported activity cannot be steered elsewhere.
enum WidgetTarget { home, reports, budget, recurring }

/// The widget section the app was opened from (cleared on read), or null.
Future<WidgetTarget?> takeWidgetTarget() async {
  if (!Platform.isAndroid) return null;
  try {
    return WidgetTarget.values.asNameMap()[await widgetChannel.invokeMethod<String>('takeLaunchTarget')];
  } on MissingPluginException {
    return null;
  }
}

/// Calls [onTap] when a widget section is tapped while the app is running
/// (Kotlin `open`); [onTap] then reads [takeWidgetTarget].
void listenWidgetTaps(void Function() onTap) {
  if (!Platform.isAndroid) return;
  widgetChannel.setMethodCallHandler((call) async {
    if (call.method == 'open') onTap();
  });
}

typedef WidgetRenderer = Future<void> Function(WidgetSnapshot snapshot);

/// Keeps the Android home-screen widget current while the app runs.
///
/// Recomputes after writes to every table the snapshot reads — balances
/// (`accounts`, `transactions`), kurs (`exchange_rates`), the PIN /
/// hide-balance / onboarding / planning settings (`app_settings`) and, for
/// the taller sizes, `budgets`, `categories`, `goals`, `recurring_rules` and
/// `recurring_instances` — and on every app start and resume ([refresh], a
/// lifecycle task), which also covers restore and future-dated rows reaching
/// their date. Computes on the app's own
/// connection; the headless widget engine is only used for system-triggered
/// updates. An unchanged snapshot is not re-sent.
class WidgetSync {
  WidgetSync(
    this._db, {
    required this._render,
    DateTime Function()? clock,
    this.coalesce = const Duration(milliseconds: 300),
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final WidgetRenderer _render;
  final DateTime Function() _clock;

  /// Bursts of writes within this window produce one compute.
  final Duration coalesce;

  StreamSubscription<void>? _sub;
  Timer? _pending;
  Future<void> _queue = Future.value();
  WidgetSnapshot? _last;
  bool _disposed = false;

  void start() {
    if (_sub != null || _disposed) return;
    _sub = _db
        .tableUpdates(TableUpdateQuery.onAllTables([
          _db.accounts,
          _db.transactions,
          _db.exchangeRates,
          _db.appSettings,
          _db.budgets,
          _db.categories,
          _db.goals,
          _db.recurringRules,
          _db.recurringInstances,
        ]))
        .listen((_) => _pending ??= Timer(coalesce, () {
              _pending = null;
              _enqueue(force: false);
            }));
  }

  /// Lifecycle task: recompute and re-send even when unchanged, so the
  /// caption's time reflects this start/resume.
  Future<void> refresh(DateTime now) => _sub == null ? Future.value() : _enqueue(force: true);

  Future<void> _enqueue({required bool force}) => _queue = _queue.then((_) => _sync(force: force));

  Future<void> _sync({required bool force}) async {
    if (_disposed) return;
    try {
      final snapshot = await computeWidgetSnapshot(_db, now: _clock());
      if (_disposed || (!force && _sameValue(snapshot, _last))) return;
      await _render(snapshot);
      _last = snapshot;
    } on PlatformException catch (e, s) {
      AppLogger.error('Widget gagal diperbarui', e, s);
    } on MissingPluginException {
      // No widget channel (non-Android host): nothing to update.
    } catch (e, s) {
      // Database closed by a restore swap mid-compute; the new scope resyncs.
      if (!_disposed) AppLogger.error('Widget gagal diperbarui', e, s);
    }
  }

  /// Same figures, chart, details and mask state; only the "Diperbarui" time may differ.
  static bool _sameValue(WidgetSnapshot a, WidgetSnapshot? b) =>
      b != null &&
      a.balanceText == b.balanceText &&
      a.masked == b.masked &&
      listEquals(a.chart, b.chart) &&
      a.details == b.details &&
      (!a.masked || a.updatedText == b.updatedText);

  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _sub?.cancel();
  }
}

/// App-scope [WidgetSync]; started on Android only. Instantiated by the
/// lifecycle task list (`app_wiring.dart`).
final widgetSyncProvider = Provider<WidgetSync>((ref) {
  final sync = WidgetSync(ref.watch(databaseProvider), render: renderWidget, clock: ref.watch(clockProvider));
  if (Platform.isAndroid) sync.start();
  ref.onDispose(sync.dispose);
  return sync;
});
