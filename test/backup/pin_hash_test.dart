import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/security/domain/app_lock_service.dart';
import 'package:finbro_app/features/security/domain/pin_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    final lock = AppLockService(settings);
    final now = DateTime(2026, 9, 30, 12);
    PinAttemptLimiter.instance.reset();

    await lock.setPin('2468');
    expect(await lock.hasPin(), isTrue);
    expect(await settings.get(SettingKeys.pinHash), isNot(contains('2468')));
    expect(await lock.verifyPin('2468'), isTrue);
    expect(await lock.verifyPin('1357'), isFalse);

    await expectLater(lock.changePin(current: '0000', next: '1111', now: now), throwsA(isA<PinException>()));
    await lock.changePin(current: '2468', next: '13579', now: now);
    expect(await lock.verifyPin('13579'), isTrue);

    await lock.setBiometricEnabled(true);
    await lock.disable(current: '13579', now: now);
    expect(await lock.hasPin(), isFalse);
    expect(await settings.get(SettingKeys.biometricEnabled), isNull);
  });

  test('five wrong attempts start a 30 s cooldown', () {
    final limiter = PinAttemptLimiter();
    final t0 = DateTime(2026, 9, 30, 12);
    for (var i = 0; i < 4; i++) {
      limiter.recordFailure(t0);
    }
    expect(limiter.remaining(t0), isNull);
    expect(limiter.attemptsLeft, 1);
    limiter.recordFailure(t0);
    expect(limiter.remaining(t0), const Duration(seconds: 30));
    expect(limiter.remaining(t0.add(const Duration(seconds: 30))), isNull);
    limiter.reset();
    expect(limiter.attemptsLeft, 5);
  });
}
