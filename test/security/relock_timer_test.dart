import 'package:finbro_app/features/security/domain/relock_timer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Duration mono;
  late DateTime wall;
  late RelockTimer timer;
  const timeout = Duration(seconds: 30);

  void advance(Duration d, {Duration? wallBy}) {
    mono += d;
    wall = wall.add(wallBy ?? d);
  }

  setUp(() {
    mono = Duration.zero;
    wall = DateTime(2026, 10, 2, 9);
    timer = RelockTimer(monotonic: () => mono, wall: () => wall);
  });

  test('resume locks once the timeout is reached, not before', () {
    timer.background();
    advance(const Duration(seconds: 29));
    expect(timer.resume(timeout), isFalse);

    timer.background();
    advance(timeout);
    expect(timer.resume(timeout), isTrue);
  });

  test('rolling the device clock back while away still locks', () {
    timer.background();
    advance(const Duration(minutes: 10), wallBy: const Duration(hours: -1));
    expect(timer.resume(timeout), isTrue);

    // Rolled back by less than the time away: the monotonic clock decides.
    timer.background();
    advance(const Duration(minutes: 10), wallBy: const Duration(seconds: 1));
    expect(timer.resume(timeout), isTrue);
  });

  test('device sleep (monotonic clock paused) is caught by the wall clock', () {
    timer.background();
    advance(const Duration(seconds: 1), wallBy: const Duration(hours: 2));
    expect(timer.resume(timeout), isTrue);
  });

  test('an exempt operation returning within the cap does not lock', () {
    timer.beginExempt();
    timer.background();
    advance(const Duration(minutes: 4));
    expect(timer.endExempt(), isFalse);
    expect(timer.resume(timeout), isFalse, reason: 'backgrounding during the exempt window is ignored');
  });

  test('an exempt operation left open past the cap locks when it returns', () {
    timer.beginExempt();
    timer.background();
    advance(RelockTimer.maxExempt + const Duration(seconds: 1));
    expect(timer.endExempt(), isTrue);

    // Same via the wall clock while the device slept.
    timer.beginExempt();
    advance(const Duration(seconds: 1), wallBy: const Duration(hours: 3));
    expect(timer.endExempt(), isTrue);
  });

  test('nested exempt operations are capped from the outermost start', () {
    timer.beginExempt();
    advance(const Duration(minutes: 3));
    timer.beginExempt();
    advance(const Duration(minutes: 3));
    expect(timer.endExempt(), isFalse, reason: 'outer operation still running');
    expect(timer.endExempt(), isTrue);
  });
}
