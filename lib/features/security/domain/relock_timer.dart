/// Decides when `AppLockGate` relocks after the app was in the background or
/// inside an exempt operation (file picker, save dialog, biometric prompt).
///
/// Time is measured on two clocks and either one reaching the limit locks:
/// - a monotonic [Stopwatch], which moving the device clock cannot affect;
/// - the wall clock, because the monotonic clock pauses while the device
///   sleeps. A wall clock that went backwards (rollback) locks as well.
class RelockTimer {
  RelockTimer({Duration Function()? monotonic, DateTime Function()? wall})
      : _monotonic = monotonic ?? (Stopwatch()..start()).elapsedFn,
        _wall = wall ?? DateTime.now;

  /// Longest an exempt operation may keep the app unlocked in the background.
  static const maxExempt = Duration(minutes: 5);

  final Duration Function() _monotonic;
  final DateTime Function() _wall;

  _Mark? _backgroundedAt;
  _Mark? _exemptSince;
  int _exemptDepth = 0;

  /// The app was hidden/paused. Ignored while an exempt operation runs.
  void background() {
    if (_exemptDepth == 0) _backgroundedAt ??= _now();
  }

  /// The app resumed; true when it was away for at least [timeout].
  bool resume(Duration timeout) {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    return since != null && _reached(since, timeout, inclusive: true);
  }

  void beginExempt() {
    if (_exemptDepth++ == 0) _exemptSince = _now();
  }

  /// Ends an exempt operation; true when the outermost one ran longer than
  /// [maxExempt], so the app must lock now.
  bool endExempt() {
    _exemptDepth--;
    _backgroundedAt = null;
    if (_exemptDepth > 0) return false;
    final since = _exemptSince;
    _exemptSince = null;
    return since != null && _reached(since, maxExempt, inclusive: false);
  }

  _Mark _now() => (monotonic: _monotonic(), wall: _wall());

  bool _reached(_Mark since, Duration limit, {required bool inclusive}) {
    final now = _now();
    final mono = now.monotonic - since.monotonic;
    final wall = now.wall.difference(since.wall);
    if (wall.isNegative) return true;
    return inclusive ? (mono >= limit || wall >= limit) : (mono > limit || wall > limit);
  }
}

typedef _Mark = ({Duration monotonic, DateTime wall});

extension on Stopwatch {
  Duration Function() get elapsedFn => () => elapsed;
}
