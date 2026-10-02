import 'dart:async';

import 'package:finbro_app/features/security/domain/elapsed_clock.dart';

/// Elapsed-since-boot clock the test moves by hand. While [hold] is set,
/// readings wait for it (like a slow platform channel) and report the values
/// current when it completes.
class FakeElapsedClock implements ElapsedClock {
  String boot = 'boot:1';
  Duration elapsed = const Duration(hours: 3);
  Completer<void>? hold;

  @override
  Future<ClockReading> now() async {
    final h = hold;
    if (h != null) await h.future;
    return (boot: boot, elapsed: elapsed);
  }
}
