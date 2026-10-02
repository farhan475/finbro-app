import 'dart:async';

import 'package:finbro_app/features/security/domain/relock_timer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_elapsed_clock.dart';

void main() {
  late FakeElapsedClock clock;
  late Duration mono;
  late DateTime wall;
  late RelockTimer timer;
  const timeout = Duration(seconds: 30);

  /// Real time passes by [d] (elapsed-since-boot clock). The stopwatch pauses
  /// while the device sleeps ([monoBy]); the user may set the wall clock
  /// ([wallBy]).
  void advance(Duration d, {Duration? monoBy, Duration? wallBy}) {
    clock.elapsed += d;
    mono += monoBy ?? d;
    wall = wall.add(wallBy ?? d);
  }

  setUp(() async {
    clock = FakeElapsedClock();
    mono = Duration.zero;
    wall = DateTime(2026, 10, 2, 9);
    timer = RelockTimer(clock: clock, monotonic: () => mono, wall: () => wall);
    await timer.calibrated;
  });

  test('resume locks once the timeout is reached, not before', () async {
    timer.background();
    advance(const Duration(seconds: 29));
    expect(await timer.resume(timeout), isFalse);

    timer.background();
    advance(timeout);
    expect(await timer.resume(timeout), isTrue);
  });

  test('a decision the stopwatch and wall clock cannot make waits for the device clock', () async {
    timer.background();
    advance(const Duration(seconds: 5));
    clock.hold = Completer();
    final decision = timer.resume(timeout);
    expect(decision, isA<Future<bool>>());
    // The device slept for an hour before the reading arrived.
    clock.elapsed += const Duration(hours: 1);
    clock.hold!.complete();
    expect(await decision, isTrue);
  });

  test('device sleep counts even when the wall clock was set back by the sleep time', () async {
    timer.background();
    // Asleep 2 h: the stopwatch saw 1 s and the wall clock was moved back so
    // it also shows only 1 s away.
    advance(const Duration(hours: 2), monoBy: const Duration(seconds: 1), wallBy: const Duration(seconds: 1));
    expect(await timer.resume(timeout), isTrue);
  });

  test('rolling the wall clock back locks at once', () {
    timer.background();
    advance(const Duration(seconds: 1), wallBy: const Duration(hours: -1));
    expect(timer.resume(timeout), isTrue);
  });

  test('moving the wall clock forward never keeps the app unlocked', () async {
    timer.background();
    advance(const Duration(seconds: 1), wallBy: const Duration(hours: 1));
    expect(await timer.resume(timeout), isTrue);
  });

  test('readings from another boot or clock lock', () async {
    timer.background();
    advance(const Duration(seconds: 1));
    clock.boot = 'boot:2';
    expect(await timer.resume(timeout), isTrue);
  });

  test('an exempt operation returning within the cap does not lock', () async {
    timer.beginExempt();
    timer.background();
    advance(const Duration(minutes: 4));
    expect(await timer.endExempt(), isFalse);
    expect(await timer.resume(timeout), isFalse, reason: 'backgrounding during the exempt window is ignored');
  });

  test('the exempt cap counts device sleep on the elapsed clock', () async {
    timer.beginExempt();
    timer.background();
    // Stopwatch and (rolled back) wall clock both show 1 s.
    advance(
      RelockTimer.maxExempt + const Duration(seconds: 1),
      monoBy: const Duration(seconds: 1),
      wallBy: const Duration(seconds: 1),
    );
    expect(await timer.endExempt(), isTrue);

    timer.beginExempt();
    advance(RelockTimer.maxExempt, monoBy: const Duration(seconds: 1), wallBy: const Duration(seconds: 1));
    expect(await timer.endExempt(), isFalse, reason: 'exactly the cap is still allowed');
  });

  test('nested exempt operations are capped from the outermost start', () async {
    timer.beginExempt();
    advance(const Duration(minutes: 3));
    timer.beginExempt();
    advance(const Duration(minutes: 3));
    expect(timer.endExempt(), isFalse, reason: 'outer operation still running');
    expect(await timer.endExempt(), isTrue);
  });
}
