import 'dart:convert';

import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/security/domain/app_lock_service.dart';
import 'package:finbro_app/features/security/domain/pin_hasher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../security/fake_elapsed_clock.dart';

void main() {
  // AppLockService uses the shared limiter on the system clock: without the
  // Android channel it falls back to a process stopwatch.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PIN hash verifies the right PIN only, salted per setup', () {
    final salt = PinHasher.newSalt();
    final hash = PinHasher.hash('482913', salt);
    final saltText = PinHasher.encodeSalt(salt);

    expect(hash, hasLength(64));
    expect(PinHasher.verify('482913', storedHash: hash, storedSalt: saltText), isTrue);
    expect(PinHasher.verify('482914', storedHash: hash, storedSalt: saltText), isFalse);
    expect(PinHasher.verify('482913', storedHash: hash, storedSalt: 'not base64!'), isFalse);
    expect(PinHasher.hash('482913', PinHasher.newSalt()), isNot(hash));
    // Iteration count is part of the hash.
    expect(PinHasher.hash('482913', salt, iterations: 1), isNot(hash));
  });

  test('PIN format is 4–6 digits', () {
    expect(PinHasher.isValidPin('1234'), isTrue);
    expect(PinHasher.isValidPin('123456'), isTrue);
    expect(PinHasher.isValidPin('123'), isFalse);
    expect(PinHasher.isValidPin('1234567'), isFalse);
    expect(PinHasher.isValidPin('12a4'), isFalse);
  });

  test('AppLockService stores only salt + hash and guards change/disable', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final settings = AppSettingsRepository(db);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final lock = AppLockService(settings);
    await PinAttemptLimiter.instance.reset();

    await lock.setPin('2468');
    expect(await lock.hasPin(), isTrue);
    expect(await settings.get(SettingKeys.pinHash), isNot(contains('2468')));
    expect(await lock.verifyPin('2468'), isTrue);
    expect(await lock.verifyPin('1357'), isFalse);

    await expectLater(lock.changePin(current: '0000', next: '1111'), throwsA(isA<PinException>()));
    await lock.changePin(current: '2468', next: '13579');
    expect(await lock.verifyPin('13579'), isTrue);

    await lock.setBiometricEnabled(true);
    await lock.disable(current: '13579');
    expect(await lock.hasPin(), isFalse);
    expect(await settings.get(SettingKeys.biometricEnabled), isNull);
  });

  test('legacy verifier migrates after correct PIN on Android channel', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final settings = AppSettingsRepository(db);
    final salt = PinHasher.newSalt();
    final saltText = PinHasher.encodeSalt(salt);
    final hash = PinHasher.hash('2468', salt);
    await settings.set(SettingKeys.pinSalt, saltText);
    await settings.set(SettingKeys.pinHash, hash);
    final channel = MethodChannel('test.pin.migration');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'bind' ? 'binding' : null,
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final lock = AppLockService(settings, pinChannel: channel, android: true);
    expect(await lock.verifyPin('2468'), isTrue);
    expect(PinHasher.bindingPart(await settings.get(SettingKeys.pinHash) ?? ''), 'binding');
  });

  test('Android binding failure is explicit and does not unlock', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final settings = AppSettingsRepository(db);
    final salt = PinHasher.newSalt();
    final saltText = PinHasher.encodeSalt(salt);
    await settings.set(SettingKeys.pinSalt, saltText);
    await settings.set(SettingKeys.pinHash, PinHasher.withBinding(PinHasher.hash('2468', salt), 'bad'));
    final channel = MethodChannel('test.pin.failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => false,
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final lock = AppLockService(settings, pinChannel: channel, android: true);
    await expectLater(lock.verifyPin('2468'), throwsA(isA<PinIntegrityException>()));
  });

  test('five wrong attempts start a 30 s cooldown', () async {
    final clock = FakeElapsedClock();
    final limiter = PinAttemptLimiter(clock: clock);
    for (var i = 0; i < 4; i++) {
      await limiter.recordFailure();
    }
    expect(await limiter.remaining(), isNull);
    expect(limiter.attemptsLeft, 1);
    await limiter.recordFailure();
    expect(await limiter.remaining(), const Duration(seconds: 30));
    clock.elapsed += const Duration(seconds: 30);
    expect(await limiter.remaining(), isNull);
    await limiter.reset();
    expect(limiter.attemptsLeft, 5);
  });

  test('changing the wall clock has no effect on a cooldown; device sleep counts', () async {
    final clock = FakeElapsedClock();
    var wall = DateTime(2026, 9, 30, 12);
    final limiter = PinAttemptLimiter(clock: clock, wall: () => wall);
    for (var i = 0; i < 5; i++) {
      await limiter.recordFailure();
    }
    wall = wall.add(const Duration(days: 1));
    expect(await limiter.remaining(), const Duration(seconds: 30), reason: 'clock moved forward');
    wall = wall.subtract(const Duration(days: 2));
    expect(await limiter.remaining(), const Duration(seconds: 30), reason: 'clock moved back');
    // Asleep for 31 s: the elapsed-since-boot clock keeps counting.
    clock.elapsed += const Duration(seconds: 31);
    expect(await limiter.remaining(), isNull);
  });

  test('cooldown escalates and survives an app restart', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final settings = AppSettingsRepository(db);
    final clock = FakeElapsedClock();

    final first = PinAttemptLimiter(clock: clock);
    await first.bind(settings);
    for (var i = 0; i < 5; i++) {
      await first.recordFailure();
    }
    expect(await first.remaining(), const Duration(seconds: 30));
    clock.elapsed += const Duration(minutes: 2);
    for (var i = 0; i < 5; i++) {
      await first.recordFailure();
    }
    expect(await first.remaining(), const Duration(minutes: 1), reason: 'second lockout is longer');
    clock.elapsed += const Duration(seconds: 10);
    await first.saved;

    // New process, same boot: fresh limiter, same store.
    final restarted = PinAttemptLimiter(clock: clock);
    await restarted.bind(settings);
    expect(await restarted.remaining(), const Duration(seconds: 50));
    expect(restarted.failures, 10);

    await restarted.reset();
    await restarted.saved;
    final cleared = PinAttemptLimiter(clock: clock);
    await cleared.bind(settings);
    expect(await cleared.remaining(), isNull);
  });

  test('a reboot restarts the cooldown in full, never shortens it, and an ended one stays ended', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final settings = AppSettingsRepository(db);
    final clock = FakeElapsedClock();

    final before = PinAttemptLimiter(clock: clock);
    await before.bind(settings);
    for (var i = 0; i < 5; i++) {
      await before.recordFailure();
    }
    clock.elapsed += const Duration(seconds: 20);
    expect(await before.remaining(), const Duration(seconds: 10));
    await before.saved;

    // Rebooted with a longer uptime than the saved deadline: comparing raw
    // elapsed times would end the cooldown, the boot count prevents it.
    clock
      ..boot = 'boot:2'
      ..elapsed = const Duration(hours: 9);
    final afterReboot = PinAttemptLimiter(clock: clock);
    await afterReboot.bind(settings);
    expect(await afterReboot.remaining(), const Duration(seconds: 30));
    clock.elapsed += const Duration(seconds: 29);
    expect(await afterReboot.remaining(), const Duration(seconds: 1));
    await afterReboot.saved;

    // The restarted deadline was saved for this boot.
    final restarted = PinAttemptLimiter(clock: clock);
    await restarted.bind(settings);
    expect(await restarted.remaining(), const Duration(seconds: 1));

    clock.elapsed += const Duration(seconds: 1);
    expect(await restarted.remaining(), isNull);
    await restarted.saved;
    clock
      ..boot = 'boot:3'
      ..elapsed = const Duration(seconds: 40);
    final nextBoot = PinAttemptLimiter(clock: clock);
    await nextBoot.bind(settings);
    expect(await nextBoot.remaining(), isNull);
    expect(nextBoot.failures, 5, reason: 'failures still count towards the next lockout');
  });

  test('the old wall-clock format is migrated, capped at the lockout cooldown', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final settings = AppSettingsRepository(db);
    final clock = FakeElapsedClock();
    final wall = DateTime(2026, 9, 30, 12);
    Future<PinAttemptLimiter> load(int failures, Duration untilFromNow) async {
      await settings.set(
        SettingKeys.pinLimiter,
        jsonEncode({'failures': failures, 'until': wall.add(untilFromNow).millisecondsSinceEpoch}),
      );
      final limiter = PinAttemptLimiter(clock: clock, wall: () => wall);
      await limiter.bind(settings);
      await limiter.saved;
      return limiter;
    }

    // Clock had been rolled back: no more than the 30 s first lockout.
    expect(await (await load(5, const Duration(hours: 1))).remaining(), const Duration(seconds: 30));
    final stored = jsonDecode((await settings.get(SettingKeys.pinLimiter))!) as Map<String, dynamic>;
    expect(stored, isNot(contains('until')));
    expect(stored['boot'], clock.boot);

    expect(await (await load(10, const Duration(seconds: 20))).remaining(), const Duration(seconds: 20));
    final expired = await load(10, const Duration(seconds: -1));
    expect(await expired.remaining(), isNull);
    expect(expired.failures, 10);
  });
}
