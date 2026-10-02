import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import 'pin_hasher.dart';

/// PIN problem the user can fix; show [message] as-is.
class PinException implements Exception {
  const PinException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lock timeout choices (seconds) for SettingKeys.lockTimeoutSeconds.
const lockTimeoutOptions = <int, String>{0: 'Segera', 60: '1 menit', 300: '5 menit'};
const defaultLockTimeoutSeconds = 60;

const appLockDisclaimer =
    'App lock melindungi tampilan aplikasi, bukan pengganti enkripsi perangkat.';

/// Snapshot of lock-related settings derived from [appSettingsProvider].
class AppLockConfig {
  const AppLockConfig({required this.pinEnabled, required this.biometricEnabled, required this.timeoutSeconds});
  final bool pinEnabled;
  final bool biometricEnabled;
  final int timeoutSeconds;
}

final appLockConfigProvider = Provider<AppLockConfig>((ref) {
  final s = ref.watch(appSettingsProvider).value ?? const {};
  final hash = s[SettingKeys.pinHash];
  final pin = hash != null && hash.isNotEmpty && (s[SettingKeys.pinSalt]?.isNotEmpty ?? false);
  return AppLockConfig(
    pinEnabled: pin,
    biometricEnabled: pin && s[SettingKeys.biometricEnabled] == 'true',
    timeoutSeconds: int.tryParse(s[SettingKeys.lockTimeoutSeconds] ?? '') ?? defaultLockTimeoutSeconds,
  );
});

final appLockServiceProvider = Provider<AppLockService>((ref) {
  final settings = ref.watch(appSettingsRepositoryProvider);
  PinAttemptLimiter.instance.bind(settings);
  return AppLockService(settings);
});

/// Whether biometric unlock can be offered on this device.
final biometricAvailableProvider = FutureProvider<bool>((ref) => AppLockService.biometricAvailable());

class AppLockService {
  AppLockService(this.settings);
  final AppSettingsRepository settings;

  static final _auth = LocalAuthentication();

  Future<bool> hasPin() async {
    final hash = await settings.get(SettingKeys.pinHash);
    final salt = await settings.get(SettingKeys.pinSalt);
    return (hash?.isNotEmpty ?? false) && (salt?.isNotEmpty ?? false);
  }

  /// Stores a new salted hash for [pin] (4–6 digits).
  Future<void> setPin(String pin) async {
    if (!PinHasher.isValidPin(pin)) {
      throw const PinException('PIN harus 4–6 digit angka.');
    }
    final salt = PinHasher.newSalt();
    final hash = await _hashOffThread(pin, salt);
    // One transaction: a crash between the two writes must not leave a new
    // salt next to the old hash (nothing would verify, permanent lockout).
    await settings.db.transaction(() async {
      await settings.set(SettingKeys.pinSalt, PinHasher.encodeSalt(salt));
      await settings.set(SettingKeys.pinHash, hash);
    });
    AppLogger.info('PIN app lock diperbarui');
  }

  Future<bool> verifyPin(String pin) async {
    final hash = await settings.get(SettingKeys.pinHash);
    final salt = await settings.get(SettingKeys.pinSalt);
    if (hash == null || salt == null || !PinHasher.isValidPin(pin)) return false;
    return _verifyOffThread(pin, hash, salt);
  }

  // Static so the isolate closures capture only sendable values, never `this`.
  static Future<String> _hashOffThread(String pin, List<int> salt) =>
      Isolate.run(() => PinHasher.hash(pin, salt));

  static Future<bool> _verifyOffThread(String pin, String hash, String salt) =>
      Isolate.run(() => PinHasher.verify(pin, storedHash: hash, storedSalt: salt));

  /// Verifies [current] through the shared attempt limiter.
  Future<void> requireCurrentPin(String current, DateTime now) async {
    final limiter = PinAttemptLimiter.instance;
    final wait = limiter.remaining(now);
    if (wait != null) {
      throw PinException('Terlalu banyak percobaan. Coba lagi dalam ${wait.inSeconds + 1} detik.');
    }
    if (!await verifyPin(current)) {
      limiter.recordFailure(now);
      throw const PinException('PIN saat ini salah.');
    }
    limiter.reset();
  }

  Future<void> changePin({required String current, required String next, required DateTime now}) async {
    await requireCurrentPin(current, now);
    await setPin(next);
  }

  /// Removes the PIN and biometric unlock after verifying [current].
  Future<void> disable({required String current, required DateTime now}) async {
    await requireCurrentPin(current, now);
    await settings.remove(SettingKeys.pinHash);
    await settings.remove(SettingKeys.pinSalt);
    await settings.remove(SettingKeys.biometricEnabled);
    AppLogger.info('App lock dinonaktifkan');
  }

  Future<void> setBiometricEnabled(bool enabled) => settings.setBool(SettingKeys.biometricEnabled, enabled);

  Future<void> setLockTimeout(int seconds) => settings.set(SettingKeys.lockTimeoutSeconds, '$seconds');

  static Future<bool> biometricAvailable() async {
    try {
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } on MissingPluginException {
      return false;
    } catch (e) {
      AppLogger.error('Cek biometrik gagal', e);
      return false;
    }
  }

  /// Shows the system biometric prompt; false on cancel/failure.
  static Future<bool> authenticateBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Buka FinBro',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on MissingPluginException {
      return false;
    } catch (e) {
      AppLogger.error('Autentikasi biometrik gagal', e);
      return false;
    }
  }
}

/// Wrong-PIN rate limit: every [maxAttempts] consecutive failures start a
/// cooldown that grows with each lockout ([cooldowns], last one repeats).
/// Process-wide so the lock screen and settings share it. When [bind]ed to
/// the settings store the state survives killing the app. It uses the wall
/// clock, so moving the device clock forward can still shorten a cooldown.
class PinAttemptLimiter {
  PinAttemptLimiter({
    this.maxAttempts = 5,
    this.cooldowns = const [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(hours: 1),
    ],
  });

  static final instance = PinAttemptLimiter();

  final int maxAttempts;
  final List<Duration> cooldowns;
  int _failures = 0;
  DateTime? _lockedUntil;
  AppSettingsRepository? _store;

  int get failures => _failures;

  /// Persists state in [store] and restores what an earlier process saved.
  Future<void> bind(AppSettingsRepository store) async {
    if (identical(_store, store)) return;
    _store = store;
    try {
      final raw = await store.get(SettingKeys.pinLimiter);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final failures = (m['failures'] as num?)?.toInt() ?? 0;
      final until = (m['until'] as num?)?.toInt();
      if (failures > _failures) _failures = failures;
      if (until != null) {
        final t = DateTime.fromMillisecondsSinceEpoch(until);
        if (_lockedUntil == null || t.isAfter(_lockedUntil!)) _lockedUntil = t;
      }
    } catch (e, s) {
      AppLogger.error('Status limiter PIN tidak terbaca', e, s);
    }
  }

  /// Remaining cooldown, or null when a new attempt is allowed.
  Duration? remaining(DateTime now) {
    final until = _lockedUntil;
    if (until == null || !now.isBefore(until)) return null;
    return until.difference(now);
  }

  /// Attempts left before the next cooldown.
  int get attemptsLeft => maxAttempts - (_failures % maxAttempts);

  void recordFailure(DateTime now) {
    _failures++;
    if (_failures % maxAttempts == 0) {
      final level = _failures ~/ maxAttempts - 1;
      _lockedUntil = now.add(cooldowns[level < cooldowns.length ? level : cooldowns.length - 1]);
    }
    _persist();
  }

  void reset() {
    if (_failures == 0 && _lockedUntil == null) return;
    _failures = 0;
    _lockedUntil = null;
    _persist();
  }

  void _persist() {
    final store = _store;
    if (store != null) unawaited(_write(store));
  }

  Future<void> _write(AppSettingsRepository store) async {
    try {
      if (_failures == 0 && _lockedUntil == null) {
        await store.remove(SettingKeys.pinLimiter);
      } else {
        await store.set(
          SettingKeys.pinLimiter,
          jsonEncode({'failures': _failures, 'until': _lockedUntil?.millisecondsSinceEpoch}),
        );
      }
    } catch (e, s) {
      AppLogger.error('Status limiter PIN gagal disimpan', e, s);
    }
  }
}
