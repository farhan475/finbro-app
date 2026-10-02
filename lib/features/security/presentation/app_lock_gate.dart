import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// - marks a clean shutdown when the app is paused/detached (StartupChecks);
/// - shows the post-restore result (its own Stack layer, not a dialog).
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  /// Runs [action] — file picker, system permission prompt, share sheet —
  /// without re-locking when the external screen it opens pauses the app.
  /// An action that keeps the app away longer than [RelockTimer.maxExempt]
  /// locks it when it returns.
  static Future<T> runExempt<T>(Future<T> Function() action) async {
    _AppLockGateState._timer.beginExempt();
    try {
      return await action();
    } finally {
      if (_AppLockGateState._timer.endExempt()) _AppLockGateState._relockAfterExempt();
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

  late final AppLifecycleListener _lifecycle;

  static void _relockAfterExempt() {
    final gate = _current;
    if (gate != null && gate.mounted) {
      gate._lock();
    } else {
      // No gate mounted right now; the next build unlocks again when no PIN
      // is set.
      _unlocked = false;
    }
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

  /// Android back while locked must not pop routes under the lock screen.
  @override
  Future<bool> didPopRoute() async => !_unlocked;

  void _markClean() {
    ref.read(startupChecksProvider).markCleanShutdown().catchError(
      (Object e, StackTrace s) => AppLogger.error('Gagal menandai clean shutdown', e, s),
    );
  }

  void _onResume() {
    final config = ref.read(appLockConfigProvider);
    if (_timer.resume(Duration(seconds: config.timeoutSeconds))) _lock();
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
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: locked,
          child: ExcludeSemantics(
            excluding: locked,
            child: IgnorePointer(ignoring: locked, child: widget.child),
          ),
        ),
        if (!locked) const RestoreResultOverlay(),
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
