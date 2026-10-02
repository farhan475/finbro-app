import 'dart:async';

import 'elapsed_clock.dart';

/// Decides when `AppLockGate` relocks after the app was in the background or
/// inside an exempt operation (file picker, save dialog, biometric prompt).
///
/// Time is measured on three clocks and any one reaching the limit locks:
/// - the device's elapsed-since-boot clock ([ElapsedClock]: counts deep sleep,
///   cannot be set by the user) — the primary source;
/// - a monotonic [Stopwatch] (pauses while the device sleeps);
/// - the wall clock. A wall clock that went backwards (rollback) locks too.
///
/// The stopwatch and wall clock are read synchronously, so a decision they
/// already reach is returned at once. The elapsed clock sits behind a platform
/// channel; when it is still needed the result is a [Future] and the caller
/// must keep the app covered until it completes.
///
/// The "since" side of a measurement is taken synchronously when the app goes
/// to the background, before the process may be frozen: it is estimated from
/// the last elapsed-clock reading plus stopwatch time since then. While the
/// app is in the foreground the device is awake, so the estimate can only be
/// early, which only makes the measured time away longer.
class RelockTimer {
  RelockTimer({ElapsedClock? clock, Duration Function()? monotonic, DateTime Function()? wall})
      : _clock = clock ?? const SystemElapsedClock(),
        _monotonic = monotonic ?? (Stopwatch()..start()).elapsedFn,
        _wall = wall ?? DateTime.now {
    calibrated = _calibrate();
  }

  /// Longest an exempt operation may keep the app unlocked in the background.
  static const maxExempt = Duration(minutes: 5);

  final ElapsedClock _clock;
  final Duration Function() _monotonic;
  final DateTime Function() _wall;

  /// Completes once the first elapsed-clock reading is in.
  late final Future<void> calibrated;

  /// Last elapsed-clock reading and the stopwatch value right after it.
  ({ClockReading reading, Duration monotonic})? _anchor;

  _Mark? _backgroundedAt;
  _Mark? _exemptSince;
  int _exemptDepth = 0;

  /// The app was hidden/paused. Ignored while an exempt operation runs.
  void background() {
    if (_exemptDepth == 0) _backgroundedAt ??= _mark();
  }

  /// The app resumed: true when it was away for at least [timeout]. Returns a
  /// [bool] when the synchronous clocks decide, otherwise a [Future].
  FutureOr<bool> resume(Duration timeout) {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since == null) return false;
    return _reached(since, timeout, inclusive: true);
  }

  void beginExempt() {
    if (_exemptDepth++ == 0) _exemptSince = _mark();
  }

  /// Ends an exempt operation; true when the outermost one ran longer than
  /// [maxExempt], so the app must lock now. [bool] or [Future] as in [resume].
  FutureOr<bool> endExempt() {
    _exemptDepth--;
    _backgroundedAt = null;
    if (_exemptDepth > 0) return false;
    final since = _exemptSince;
    _exemptSince = null;
    if (since == null) return false;
    return _reached(since, maxExempt, inclusive: false);
  }

  Future<void> _calibrate() async => _anchorTo(await _clock.now());

  void _anchorTo(ClockReading reading) => _anchor = (reading: reading, monotonic: _monotonic());

  _Mark _mark() {
    final mono = _monotonic();
    final anchor = _anchor;
    return (
      monotonic: mono,
      wall: _wall(),
      // No reading yet (just started): ask now, possibly answered late.
      elapsed: anchor == null
          ? _clock.now()
          : Future.value((
              boot: anchor.reading.boot,
              elapsed: anchor.reading.elapsed + (mono - anchor.monotonic),
            )),
    );
  }

  FutureOr<bool> _reached(_Mark since, Duration limit, {required bool inclusive}) {
    bool hit(Duration d) => inclusive ? d >= limit : d > limit;
    final wall = _wall().difference(since.wall);
    if (wall.isNegative || hit(wall) || hit(_monotonic() - since.monotonic)) return true;
    return () async {
      final start = await since.elapsed;
      final now = await _clock.now();
      _anchorTo(now);
      // Readings from different clocks (reboot, channel failure) cannot be
      // compared: lock.
      if (now.boot != start.boot) return true;
      final away = now.elapsed - start.elapsed;
      return away.isNegative || hit(away);
    }();
  }
}

typedef _Mark = ({Duration monotonic, DateTime wall, Future<ClockReading> elapsed});

extension on Stopwatch {
  Duration Function() get elapsedFn => () => elapsed;
}
