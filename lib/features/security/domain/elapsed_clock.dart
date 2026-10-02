import 'dart:math';

import 'package:flutter/services.dart';

import '../../../core/utilities/app_logger.dart';

/// A reading of a clock the user cannot set.
///
/// [elapsed] only means something relative to another reading with the same
/// [boot]: a different [boot] is a different clock (the device rebooted, or
/// the reading came from another source) and the two cannot be compared.
typedef ClockReading = ({String boot, Duration elapsed});

/// Source of [ClockReading]s for the app lock. Implementations never throw.
abstract interface class ElapsedClock {
  Future<ClockReading> now();
}

/// Android `SystemClock.elapsedRealtime()` (keeps counting in deep sleep, not
/// user-settable) tagged with `Settings.Global.BOOT_COUNT`, via the
/// `id.finbro.app/clock` channel (MainActivity → ClockChannel.kt).
///
/// Without the channel (tests, other platforms) or when it fails, it falls back
/// to a process-local [Stopwatch], which pauses while the device sleeps; its
/// readings carry a per-process [ClockReading.boot] so they never compare
/// equal to platform readings or to readings saved by another process.
class SystemElapsedClock implements ElapsedClock {
  const SystemElapsedClock();

  static const _channel = MethodChannel('id.finbro.app/clock');
  static final _stopwatch = Stopwatch()..start();
  static final _process = Random.secure().nextInt(1 << 32).toRadixString(16);

  @override
  Future<ClockReading> now() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('now');
      final elapsed = r?['elapsedRealtime'];
      if (elapsed is int) {
        final bootCount = r!['bootCount'];
        return (
          // No boot count: elapsedRealtime is still valid within this process.
          boot: bootCount is int ? 'boot:$bootCount' : 'process:$_process:realtime',
          elapsed: Duration(milliseconds: elapsed),
        );
      }
      AppLogger.error('Jam perangkat: balasan tidak valid ($r)');
    } on MissingPluginException {
      // Not Android (or a test without a mock handler): use the fallback.
    } catch (e, s) {
      AppLogger.error('Jam perangkat tidak terbaca', e, s);
    }
    return (boot: 'process:$_process:stopwatch', elapsed: _stopwatch.elapsed);
  }
}
