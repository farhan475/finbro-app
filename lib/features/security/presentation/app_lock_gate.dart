import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/utilities/app_logger.dart';
import '../../backup/presentation/restore_result_overlay.dart';
import '../../settings/domain/startup_checks.dart';
import '../domain/app_lock_service.dart';
import '../domain/relock_timer.dart';
import 'lock_screen.dart';

/// Wraps the whole app (MaterialApp.builder, above the Navigator):
/// - full-screen PIN/biometric lock on cold start and on resume after the
///   configured timeout, blocking everything beneath (pointer, semantics,
///   focus and the Android back button);
/// - while a relock decision waits for the device clock, an opaque cover
///   hides the content so nothing shows before the decision;
/// - marks a clean shutdown when the app is paused/detached (StartupChecks);
/// - shows the post-restore result (its own Stack layer, not a dialog).
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  /// Key of the cover shown while a relock decision is pending.
  @visibleForTesting
  static const pendingCoverKey = ValueKey('app-lock-pending-cover');

  /// Runs [action] — file picker, system permission prompt, share sheet —
  /// without re-locking when the external screen it opens pauses the app.
  /// An action that keeps the app away longer than [RelockTimer.maxExempt]
  /// locks it when it returns.
  static Future<T> runExempt<T>(Future<T> Function() action) async {
    _AppLockGateState._timer.beginExempt();
    try {
      return await action();
    } finally {
      _AppLockGateState._settle(_AppLockGateState._timer.endExempt());
    }
  }

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  // Process-wide: a provider-tree rebuild (restore) must not relock, a cold
  // start always does.
  static bool _unlocked = false;
  static final _timer = RelockTimer();
  static _AppLockGateState? _current;
  // Relock decisions still waiting for the device clock (process-wide like
  // [_unlocked], so a rebuilt gate keeps covering).
  static int _pending = 0;

  late final AppLifecycleListener _lifecycle;

  /// Applies a relock decision; a pending one covers the content until it
  /// completes. A failed decision locks.
  static void _settle(FutureOr<bool> decision) {
    if (decision is bool) {
      if (decision) _relock();
      return;
    }
    _pending++;
    _current?._refresh();
    decision.catchError((Object e, StackTrace s) {
      AppLogger.error('Keputusan kunci ulang gagal', e, s);
      return true;
    }).then((lock) {
      _pending--;
      if (lock) _relock();
      _current?._refresh();
    });
  }

  static void _relock() {
    final gate = _current;
    if (gate != null && gate.mounted) {
      gate._lock();
    } else {
      // No gate mounted right now; the next build unlocks again when no PIN
      // is set.
      _unlocked = false;
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _current = this;
    // Registered before the Router's back button dispatcher (the Router is a
    // descendant), so [didPopRoute] sees the back button first.
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = AppLifecycleListener(
      onHide: _timer.background,
      onPause: () {
        _timer.background();
        _markClean();
      },
      onDetach: _markClean,
      onResume: _onResume,
    );
    if (!_unlocked) FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    if (identical(_current, this)) _current = null;
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle.dispose();
    super.dispose();
  }

  /// Android back while locked (or while a relock decision is pending) must
  /// not pop routes under the lock screen.
  @override
  Future<bool> didPopRoute() async => !_unlocked || _covered;

  /// A relock decision is pending and there is something to hide.
  bool get _covered => _pending > 0 && _unlocked && ref.read(appLockConfigProvider).pinEnabled;

  void _markClean() {
    ref.read(startupChecksProvider).markCleanShutdown().catchError(
      (Object e, StackTrace s) => AppLogger.error('Gagal menandai clean shutdown', e, s),
    );
  }

  void _onResume() {
    final config = ref.read(appLockConfigProvider);
    _settle(_timer.resume(Duration(seconds: config.timeoutSeconds)));
  }

  void _lock() {
    if (!_unlocked || !ref.read(appLockConfigProvider).pinEnabled) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _unlocked = false);
  }

  Future<bool> _authenticateBiometric() =>
      AppLockGate.runExempt(AppLockService.authenticateBiometric);

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appLockConfigProvider);
    // Without a PIN the session counts as authenticated, so enabling a PIN
    // (or restoring a backup that has one) never locks the current session.
    if (!config.pinEnabled) _unlocked = true;
    final locked = !_unlocked;
    // Not ExcludeFocus: a decision that ends unlocked must keep the focused
    // field (and its keyboard) as it was.
    final covered = !locked && _pending > 0 && config.pinEnabled;
    final hidden = locked || covered;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: locked,
          child: ExcludeSemantics(
            excluding: hidden,
            child: IgnorePointer(ignoring: hidden, child: widget.child),
          ),
        ),
        if (!hidden) const RestoreResultOverlay(),
        if (covered) ColoredBox(key: AppLockGate.pendingCoverKey, color: context.fin.background),
        if (locked)
          LockScreen(
            biometricEnabled: config.biometricEnabled,
            authenticateBiometric: _authenticateBiometric,
            onUnlocked: () => setState(() => _unlocked = true),
          ),
      ],
    );
  }
}
