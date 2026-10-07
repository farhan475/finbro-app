import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Salted, iterated SHA-256 for the app-lock PIN. The PIN itself is never
/// stored; only `hash` (hex), optional device binding, and `salt` (base64)
/// go into app_settings. Android validates the binding through Keystore.
abstract final class PinHasher {
  static const iterations = 10000;
  static const saltLength = 16;
  static final _pinPattern = RegExp(r'^\d{4,6}$');

  static bool isValidPin(String pin) => _pinPattern.hasMatch(pin);

  static Uint8List newSalt([Random? random]) {
    final r = random ?? Random.secure();
    return Uint8List.fromList(List.generate(saltLength, (_) => r.nextInt(256)));
  }

  static String encodeSalt(List<int> salt) => base64Encode(salt);

  static Uint8List decodeSalt(String salt) => base64Decode(salt);

  /// sha256(salt ‖ pin), then [iterations]−1 rounds of sha256(digest ‖ salt).
  static String hash(String pin, List<int> salt, {int iterations = iterations}) {
    var digest = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;
    for (var i = 1; i < iterations; i++) {
      digest = sha256.convert([...digest, ...salt]).bytes;
    }
    return _hex(digest);
  }
  /// Returns the hash portion of a stored verifier. New Android verifiers
  /// append a device-keystore binding after a dot; legacy hashes are unchanged.
  static String hashPart(String storedHash) => storedHash.split('.').first;

  /// Returns the optional device-keystore binding from a stored verifier.
  static String? bindingPart(String storedHash) {
    final separator = storedHash.indexOf('.');
    if (separator < 1 || separator == storedHash.length - 1) return null;
    return storedHash.substring(separator + 1);
  }

  /// Stores a hash and its device-local binding without storing the PIN.
  static String withBinding(String hash, String binding) => '$hash.$binding';

  static bool verify(String pin, {required String storedHash, required String storedSalt}) {
    final List<int> salt;
    try {
      salt = decodeSalt(storedSalt);
    } catch (_) {
      return false;
    }
    final hash = hashPart(storedHash);
    final candidate = hashPin(pin, salt);
    if (candidate.length != hash.length) return false;
    var diff = 0;
    for (var i = 0; i < candidate.length; i++) {
      diff |= candidate.codeUnitAt(i) ^ hash.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Hashes a PIN using the default work factor.
  static String hashPin(String pin, List<int> salt) => hash(pin, salt);

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
