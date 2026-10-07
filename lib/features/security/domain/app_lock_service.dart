import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import 'elapsed_clock.dart';
import 'pin_hasher.dart';

/// PIN problem the user can fix; show [message] as-is.
class PinException implements Exception {
  const PinException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Raised when the device-bound verifier cannot be checked. This is never
/// treated as a wrong PIN: Android must not silently fall back to DB-only data.
class PinIntegrityException extends PinException {
  const PinIntegrityException(super.message);
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
  AppLockService(this.settings, {MethodChannel? pinChannel, bool? android})
      : _pinChannelInstance = pinChannel ?? _pinChannel,
        _android = android ?? _isAndroid;
  final AppSettingsRepository settings;
  final MethodChannel _pinChannelInstance;
  final bool _android;

  static final _auth = LocalAuthentication();

  Future<bool> hasPin() async {
    final hash = await settings.get(SettingKeys.pinHash);
    final salt = await settings.get(SettingKeys.pinSalt);
    return (hash?.isNotEmpty ?? false) && (salt?.isNotEmpty ?? false);
  }

  /// Stores a new salted hash. Android additionally binds it to a non-exportable
  /// Keystore key before either database value is committed.
  Future<void> setPin(String pin) async {
    if (!PinHasher.isValidPin(pin)) {
      throw const PinException('PIN harus 4–6 digit angka.');
    }
    final salt = PinHasher.newSalt();
    final hash = await _hashOffThread(pin, salt);
    final storedHash = await _bindHash(hash, PinHasher.encodeSalt(salt));
    await settings.db.transaction(() async {
      await settings.set(SettingKeys.pinSalt, PinHasher.encodeSalt(salt));
      await settings.set(SettingKeys.pinHash, storedHash);
    });
    AppLogger.info('PIN app lock diperbarui');
  }

  Future<bool> verifyPin(String pin) async {
    final storedHash = await settings.get(SettingKeys.pinHash);
    final salt = await settings.get(SettingKeys.pinSalt);
    if (storedHash == null || salt == null || !PinHasher.isValidPin(pin)) return false;
    final valid = await _verifyOffThread(pin, storedHash, salt);
    if (!valid) return false;
    if (!_android) return true;
    final binding = PinHasher.bindingPart(storedHash);
    if (binding == null) {
      final migrated = await _bindHash(PinHasher.hashPart(storedHash), salt);
      await settings.set(SettingKeys.pinHash, migrated);
      return true;
    }
    await _verifyBinding(PinHasher.hashPart(storedHash), salt, binding);
    return true;
  }

  static final _pinChannel = MethodChannel('id.finbro.app/pin_verifier');
  static bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  Future<String> _bindHash(String hash, String salt) async {
    if (!_android) return hash;
    try {
      final binding = await _pinChannelInstance.invokeMethod<String>('bind', {'data': '$hash.$salt'});
      if (binding == null || binding.isEmpty) throw const PinIntegrityException('Keystore PIN tidak tersedia.');
      return PinHasher.withBinding(hash, binding);
    } on PinIntegrityException {
      rethrow;
    } on MissingPluginException {
      throw const PinIntegrityException('Pengamanan PIN perangkat tidak tersedia.');
    } on PlatformException {
      throw const PinIntegrityException('Kunci pengamanan PIN perangkat tidak valid.');
    }
  }

  Future<void> _verifyBinding(String hash, String salt, String binding) async {
    try {
      final valid = await _pinChannelInstance.invokeMethod<bool>('verify', {'data': '$hash.$salt', 'binding': binding});
      if (valid != true) throw const PinIntegrityException('Verifikasi PIN perangkat gagal.');
    } on PinIntegrityException {
      rethrow;
    } on MissingPluginException {
      throw const PinIntegrityException('Pengamanan PIN perangkat tidak tersedia.');
    } on PlatformException {
      throw const PinIntegrityException('Kunci pengamanan PIN perangkat tidak valid.');
    }
  }

  // Static so the isolate closures capture only sendable values, never `this`.
  static Future<String> _hashOffThread(String pin, List<int> salt) =>
      Isolate.run(() => PinHasher.hash(pin, salt));

  static Future<bool> _verifyOffThread(String pin, String hash, String salt) =>
      Isolate.run(() => PinHasher.verify(pin, storedHash: hash, storedSalt: salt));

  /// Verifies [current] through the shared attempt limiter.
  Future<void> requireCurrentPin(String current) async {
    final limiter = PinAttemptLimiter.instance;
    final wait = await limiter.remaining();
    if (wait != null) {
      throw PinException('Terlalu banyak percobaan. Coba lagi dalam ${wait.inSeconds + 1} detik.');
    }
    try {
      if (!await verifyPin(current)) {
        await limiter.recordFailure();
        throw const PinException('PIN saat ini salah.');
      }
    } on PinIntegrityException {
      rethrow;
    }
    await limiter.reset();
  }

  Future<void> changePin({required String current, required String next}) async {
    await requireCurrentPin(current);
    await setPin(next);
  }

  /// Removes the PIN and biometric unlock after verifying [current].
  Future<void> disable({required String current}) async {
    await requireCurrentPin(current);
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
/// the settings store the state survives killing the app.
///
/// A cooldown deadline is kept as (boot, deadline) on the device's
/// elapsed-since-boot clock ([ElapsedClock]): changing the device clock has no
/// effect and time asleep counts.
///
/// Reboot rule: the elapsed clock restarts at boot and how long the device was
/// off is unknown, so a deadline from another boot is never assumed to have
/// passed. The cooldown restarts in full from the first moment it is seen in
/// the new boot: a reboot never shortens a cooldown (it can lengthen it by at
/// most that cooldown). A cooldown seen to have ended is cleared, so a later
/// reboot does not bring it back.
///
/// Stored as JSON under SettingKeys.pinLimiter: `failures`, and while a
/// cooldown is set `boot`, `deadlineMs` and `cooldownMs`. Older versions
/// stored `until` (wall-clock epoch ms); on load it becomes the remaining wall
/// time, capped at the cooldown of that lockout, and is re-saved.
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
    this._clock = const SystemElapsedClock(),
    this._wall = DateTime.now,
  });

  static final instance = PinAttemptLimiter();

  final int maxAttempts;
  final List<Duration> cooldowns;
  final ElapsedClock _clock;
  // Only for migrating the old wall-clock format.
  final DateTime Function() _wall;
  int _failures = 0;
  _Deadline? _deadline;
  AppSettingsRepository? _store;
  Future<void> _loaded = Future.value();
  Future<void> _saving = Future.value();

  int get failures => _failures;

  /// Completes when every state change so far is saved.
  @visibleForTesting
  Future<void> get saved => _saving;

  /// Persists state in [store] and restores what an earlier process saved.
  /// Other calls wait for the restore.
  Future<void> bind(AppSettingsRepository store) {
    if (identical(_store, store)) return _loaded;
    _store = store;
    return _loaded = _loaded.then((_) => _restore(store));
  }

  Future<void> _restore(AppSettingsRepository store) async {
    try {
      final raw = await store.get(SettingKeys.pinLimiter);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final failures = (m['failures'] as num?)?.toInt() ?? 0;
      if (failures > _failures) _failures = failures;
      final now = await _clock.now();
      var save = false;
      _Deadline? saved;
      final (boot, deadlineMs, cooldownMs, until) = (m['boot'], m['deadlineMs'], m['cooldownMs'], m['until']);
      if (boot is String && deadlineMs is num && cooldownMs is num) {
        saved = (
          boot: boot,
          at: Duration(milliseconds: deadlineMs.toInt()),
          length: Duration(milliseconds: cooldownMs.toInt()),
        );
      } else if (until is num) {
        save = true;
        final length = _cooldownFor(failures);
        var left = DateTime.fromMillisecondsSinceEpoch(until.toInt()).difference(_wall());
        if (left > length) left = length;
        if (left > Duration.zero) saved = (boot: now.boot, at: now.elapsed + left, length: length);
      }
      if (saved != null) {
        // Keep whichever cooldown (saved or this process's) leaves longer.
        final restored = _inBoot(saved, now);
        final current = _deadline == null ? null : _inBoot(_deadline!, now);
        _deadline = current == null || restored.at > current.at ? restored : current;
        save = save || _deadline != saved;
      }
      if (save) _persist();
    } catch (e, s) {
      AppLogger.error('Status limiter PIN tidak terbaca', e, s);
    }
  }

  /// Remaining cooldown, or null when a new attempt is allowed.
  Future<Duration?> remaining() async {
    await _loaded;
    if (_deadline == null) return null;
    final now = await _clock.now();
    final d = _deadline;
    if (d == null) return null;
    final current = _inBoot(d, now);
    final left = current.at - now.elapsed;
    if (left > Duration.zero) {
      if (current != d) {
        _deadline = current;
        _persist();
      }
      return left;
    }
    // Seen ending: clear it so a later reboot cannot restart it.
    _deadline = null;
    _persist();
    return null;
  }

  /// Attempts left before the next cooldown.
  int get attemptsLeft => maxAttempts - (_failures % maxAttempts);

  Future<void> recordFailure() async {
    await _loaded;
    final now = await _clock.now();
    _failures++;
    if (_failures % maxAttempts == 0) {
      final length = _cooldownFor(_failures);
      _deadline = (boot: now.boot, at: now.elapsed + length, length: length);
    }
    _persist();
  }

  Future<void> reset() async {
    await _loaded;
    if (_failures == 0 && _deadline == null) return;
    _failures = 0;
    _deadline = null;
    _persist();
  }

  /// Cooldown of the lockout reached at [failures] consecutive failures.
  Duration _cooldownFor(int failures) {
    final level = failures ~/ maxAttempts - 1;
    return cooldowns[level.clamp(0, cooldowns.length - 1)];
  }

  /// [d] expressed on [now]'s clock. A deadline from another boot, or one set
  /// further ahead than its cooldown (impossible within one boot), restarts
  /// the full cooldown from [now] (see the reboot rule above).
  static _Deadline _inBoot(_Deadline d, ClockReading now) {
    if (d.boot == now.boot && d.at - d.length <= now.elapsed) return d;
    return (boot: now.boot, at: now.elapsed + d.length, length: d.length);
  }

  void _persist() {
    final store = _store;
    if (store == null) return;
    // Snapshot now; writes run in order.
    final d = _deadline;
    final json = _failures == 0 && d == null
        ? null
        : jsonEncode({
            'failures': _failures,
            if (d != null) ...{
              'boot': d.boot,
              'deadlineMs': d.at.inMilliseconds,
              'cooldownMs': d.length.inMilliseconds,
            },
          });
    _saving = _saving.then((_) => _write(store, json));
  }

  static Future<void> _write(AppSettingsRepository store, String? json) async {
    try {
      if (json == null) {
        await store.remove(SettingKeys.pinLimiter);
      } else {
        await store.set(SettingKeys.pinLimiter, json);
      }
    } catch (e, s) {
      AppLogger.error('Status limiter PIN gagal disimpan', e, s);
    }
  }
}

/// Cooldown end [at] on the elapsed clock of [boot]; [length] is the full
/// cooldown, used to restart it after a reboot.
typedef _Deadline = ({String boot, Duration at, Duration length});
