import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utilities/app_logger.dart';
import '../../backup/presentation/restore_result_overlay.dart';
import '../../settings/domain/startup_checks.dart';
import '../domain/app_lock_service.dart';
import 'lock_screen.dart';

/// Wraps the whole app (MaterialApp.builder, above the Navigator):
/// - full-screen PIN/biometric lock on cold start and on resume after the
///   configured timeout, blocking everything beneath;
/// - marks a clean shutdown when the app is paused/detached (StartupChecks);
/// - shows the post-restore result (its own Stack layer, not a dialog).
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  /// Runs [action] — file picker, system permission prompt, share sheet —
  /// without re-locking when the external screen it opens pauses the app.
  static Future<T> runExempt<T>(Future<T> Function() action) async {
    _AppLockGateState._exemptDepth++;
    try {
      return await action();
    } finally {
      _AppLockGateState._exemptDepth--;
      _AppLockGateState._backgroundedAt = null;
    }
  }

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  // Process-wide: a provider-tree rebuild (restore) must not relock, a cold
  // start always does.
  static bool _unlocked = false;
  static DateTime? _backgroundedAt;
  static int _exemptDepth = 0;

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: _onBackground,
      onPause: () {
        _onBackground();
        _markClean();
      },
      onDetach: _markClean,
      onResume: _onResume,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _onBackground() {
    if (_exemptDepth == 0) _backgroundedAt ??= DateTime.now();
  }

  void _markClean() {
    ref.read(startupChecksProvider).markCleanShutdown().catchError(
      (Object e, StackTrace s) => AppLogger.error('Gagal menandai clean shutdown', e, s),
    );
  }

  void _onResume() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    final config = ref.read(appLockConfigProvider);
    if (since == null || !config.pinEnabled || !_unlocked) return;
    if (DateTime.now().difference(since).inSeconds >= config.timeoutSeconds) {
      setState(() => _unlocked = false);
    }
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
        ExcludeSemantics(
          excluding: locked,
          child: IgnorePointer(ignoring: locked, child: widget.child),
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
