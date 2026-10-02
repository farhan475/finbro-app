import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretBoxAuthenticationError, SecretKey;
import 'package:cryptography/dart.dart';

import 'backup_service.dart';

/// Argon2id cost parameters, stored in every `.finbro` header so files stay
/// readable after the defaults change.
class KdfParams {
  const KdfParams({required this.memoryKiB, required this.iterations, required this.parallelism});

  /// RFC 9106 §4 second recommended option (64 MiB, t=3, p=4). Pure-Dart
  /// Argon2id runs it in ~1.1 s on a 2015 laptop i5 (x64 AOT, 4 isolates);
  /// mid-range phones land around 1–3 s, paid only when a passphrase is set
  /// or typed (automatic backups reuse the stored key). PBKDF2-SHA256 at
  /// 600k iterations took 5.8 s on the same machine and is weaker against
  /// GPUs, so Argon2id is used.
  static const recommended = KdfParams(memoryKiB: 64 * 1024, iterations: 3, parallelism: 4);

  // Accepted range when reading a header (bounds memory/time of a hostile file).
  static const maxMemoryKiB = 256 * 1024;
  static const maxIterations = 16;
  static const maxParallelism = 16;

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  bool get isValid =>
      parallelism >= 1 &&
      parallelism <= maxParallelism &&
      iterations >= 1 &&
      iterations <= maxIterations &&
      memoryKiB >= 8 * parallelism &&
      memoryKiB <= maxMemoryKiB;

  Map<String, Object> toJson() => {'m': memoryKiB, 't': iterations, 'p': parallelism};

  factory KdfParams.fromJson(Map<String, dynamic> j) =>
      KdfParams(memoryKiB: j['m'] as int, iterations: j['t'] as int, parallelism: j['p'] as int);

  @override
  bool operator ==(Object other) =>
      other is KdfParams &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism;

  @override
  int get hashCode => Object.hash(memoryKiB, iterations, parallelism);

  @override
  String toString() => 'Argon2id(m=${memoryKiB}KiB, t=$iterations, p=$parallelism)';
}

/// AES-256 key derived from a passphrase, with the salt and parameters that
/// produced it. Stored in secure storage so automatic backups need no prompt;
/// the passphrase itself is never stored.
class BackupKey {
  BackupKey({required this.key, required this.salt, required this.params, required this.createdAt});

  final Uint8List key;
  final Uint8List salt;
  final KdfParams params;
  final DateTime createdAt;

  /// Whether this key was derived with the salt and parameters of [header]
  /// (only then can it decrypt the file).
  bool fitsHeader(EncryptedHeader header) =>
      params == header.params && const ListEquality<int>().equals(salt, header.salt);

  String encode() => jsonEncode({
    'v': 1,
    'key': base64Encode(key),
    'salt': base64Encode(salt),
    'kdf': params.toJson(),
    'createdAt': createdAt.toIso8601String(),
  });

  /// Null for anything that is not a well-formed stored key.
  static BackupKey? tryDecode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['v'] != 1) return null;
      final key = base64Decode(j['key'] as String);
      if (key.length != EncryptedBackup.keyLength) return null;
      return BackupKey(
        key: key,
        salt: base64Decode(j['salt'] as String),
        params: KdfParams.fromJson(j['kdf'] as Map<String, dynamic>),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Parsed, not yet authenticated header of a `.finbro` file.
class EncryptedHeader {
  const EncryptedHeader({required this.params, required this.salt, required this.nonce});
  final KdfParams params;
  final Uint8List salt;
  final Uint8List nonce;
}

/// `.finbro` container: header + AES-256-GCM of the backup zip
/// ([BackupService.buildPackage] output). Layout, big-endian:
///
/// | offset | size | field                                   |
/// |--------|------|-----------------------------------------|
/// | 0      | 8    | magic `FINBROEN`                        |
/// | 8      | 2    | format version (1)                      |
/// | 10     | 1    | KDF id (1 = Argon2id v1.3)              |
/// | 11     | 4    | Argon2id memory (KiB)                   |
/// | 15     | 4    | Argon2id iterations                     |
/// | 19     | 1    | Argon2id parallelism                    |
/// | 20     | 1    | salt length (16)                        |
/// | 21     | 16   | salt                                    |
/// | 37     | 1    | nonce length (12)                       |
/// | 38     | 12   | nonce                                   |
/// | 50     | n+16 | ciphertext ‖ GCM tag                    |
///
/// The whole header is GCM associated data: changing any header byte fails
/// authentication. Crypto runs on background isolates.
abstract final class EncryptedBackup {
  static const extension = '.finbro';
  static const mimeType = 'application/octet-stream';
  static const formatVersion = 1;
  static const kdfArgon2id = 1;
  static const keyLength = 32;
  static const saltLength = 16;
  static const nonceLength = 12;
  static const tagLength = 16;
  static const headerLength = 50;
  static const minPassphraseLength = 8;
  static final magic = Uint8List.fromList(ascii.encode('FINBROEN'));

  /// Largest `.finbro` accepted: the zip limit plus the container overhead.
  static const maxFileBytes = BackupService.maxBackupBytes + headerLength + tagLength;

  static const wrongKeyMessage =
      'Passphrase salah, atau file backup terenkripsi rusak/telah diubah.';
  static const notEncryptedMessage = 'File ini bukan backup terenkripsi FinBro (.finbro).';
  static const truncatedMessage = 'File backup terenkripsi rusak: isinya tidak lengkap.';
  static const badParamsMessage =
      'Parameter kunci pada file backup tidak valid. File rusak atau telah diubah.';
  static const oversizeMessage =
      'File backup terenkripsi terlalu besar (maksimal ${BackupService.maxBackupBytes ~/ (1024 * 1024)} MB).';

  /// Null when [passphrase] is acceptable, else the reason in Indonesian.
  static String? passphraseProblem(String passphrase, String confirmation) {
    if (passphrase.runes.length < minPassphraseLength) {
      return 'Passphrase minimal $minPassphraseLength karakter.';
    }
    if (passphrase != confirmation) return 'Konfirmasi passphrase tidak sama.';
    return null;
  }

  /// Derives a new key from [passphrase] with a fresh random salt (unless
  /// [salt] is given), on a background isolate.
  static Future<BackupKey> deriveKey(
    String passphrase, {
    KdfParams params = KdfParams.recommended,
    Uint8List? salt,
    DateTime? now,
  }) {
    final s = salt ?? _random(saltLength);
    final created = now ?? DateTime.now();
    return Isolate.run(() async => BackupKey(
      key: await _derive(passphrase, s, params),
      salt: s,
      params: params,
      createdAt: created,
    ));
  }

  /// Encrypts [zip] with [key] (fresh random nonce) on a background isolate.
  static Future<Uint8List> encrypt(Uint8List zip, BackupKey key) async {
    if (zip.length > BackupService.maxBackupBytes) {
      throw const BackupException(BackupService.oversizeMessage);
    }
    final nonce = _random(nonceLength);
    final header = _header(key.params, key.salt, nonce);
    final keyBytes = key.key;
    return Isolate.run(() async {
      final box = await DartAesGcm.with256bits().encrypt(
        zip,
        secretKey: SecretKey(keyBytes),
        nonce: nonce,
        aad: header,
      );
      return (BytesBuilder(copy: false)
            ..add(header)
            ..add(box.cipherText)
            ..add(box.mac.bytes))
          .takeBytes();
    });
  }

  /// Parses and bounds-checks the header of [file]. Throws [BackupException]
  /// for anything that is not a supported `.finbro`.
  static EncryptedHeader readHeader(Uint8List file) {
    if (file.length > maxFileBytes) throw const BackupException(oversizeMessage);
    if (file.length < magic.length ||
        !const ListEquality<int>().equals(file.sublist(0, magic.length), magic)) {
      throw const BackupException(notEncryptedMessage);
    }
    if (file.length < 11) throw const BackupException(truncatedMessage);
    final data = ByteData.sublistView(file);
    final version = data.getUint16(8);
    if (version != formatVersion) {
      throw BackupException(
        'Format backup terenkripsi versi $version tidak didukung aplikasi ini. '
        'Perbarui FinBro lalu coba lagi.',
      );
    }
    final kdf = file[10];
    if (kdf != kdfArgon2id) {
      throw BackupException(
        'Metode kunci (KDF $kdf) pada file backup tidak dikenal. Perbarui FinBro lalu coba lagi.',
      );
    }
    if (file.length < headerLength + tagLength) throw const BackupException(truncatedMessage);
    final params = KdfParams(
      memoryKiB: data.getUint32(11),
      iterations: data.getUint32(15),
      parallelism: file[19],
    );
    if (!params.isValid || file[20] != saltLength || file[37] != nonceLength) {
      throw const BackupException(badParamsMessage);
    }
    return EncryptedHeader(
      params: params,
      salt: Uint8List.fromList(file.sublist(21, 21 + saltLength)),
      nonce: Uint8List.fromList(file.sublist(38, 38 + nonceLength)),
    );
  }

  /// Decrypts [file] with an already derived [key] on a background isolate.
  /// Throws [BackupException] ([wrongKeyMessage]) when authentication fails.
  static Future<Uint8List> decryptWithKey(Uint8List file, BackupKey key) async {
    final header = readHeader(file);
    if (!key.fitsHeader(header)) throw const BackupException(wrongKeyMessage);
    final keyBytes = key.key;
    return Isolate.run(() => _open(file, header, keyBytes));
  }

  /// Derives the key with the salt and parameters stored in [file]'s header
  /// and decrypts it, both on one background isolate. Returns the zip and
  /// the key (usable for further backups with the same passphrase).
  static Future<({Uint8List zip, BackupKey key})> decryptWithPassphrase(
    Uint8List file,
    String passphrase, {
    DateTime? now,
  }) async {
    final header = readHeader(file);
    final created = now ?? DateTime.now();
    return Isolate.run(() async {
      final keyBytes = await _derive(passphrase, header.salt, header.params);
      final zip = await _open(file, header, keyBytes);
      return (
        zip: zip,
        key: BackupKey(key: keyBytes, salt: header.salt, params: header.params, createdAt: created),
      );
    });
  }

  static Future<Uint8List> _open(Uint8List file, EncryptedHeader header, Uint8List keyBytes) async {
    final body = Uint8List.sublistView(file, headerLength);
    final box = SecretBox(
      Uint8List.sublistView(body, 0, body.length - tagLength),
      nonce: header.nonce,
      mac: Mac(Uint8List.sublistView(body, body.length - tagLength)),
    );
    try {
      final clear = await DartAesGcm.with256bits().decrypt(
        box,
        secretKey: SecretKey(keyBytes),
        aad: Uint8List.sublistView(file, 0, headerLength),
      );
      return clear is Uint8List ? clear : Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const BackupException(wrongKeyMessage);
    }
  }

  static Future<Uint8List> _derive(String passphrase, Uint8List salt, KdfParams params) async {
    final key = await DartArgon2id(
      memory: params.memoryKiB,
      iterations: params.iterations,
      parallelism: params.parallelism,
      hashLength: keyLength,
    ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  }

  static Uint8List _header(KdfParams params, Uint8List salt, Uint8List nonce) {
    final b = Uint8List(headerLength);
    final d = ByteData.sublistView(b);
    b.setAll(0, magic);
    d.setUint16(8, formatVersion);
    b[10] = kdfArgon2id;
    d.setUint32(11, params.memoryKiB);
    d.setUint32(15, params.iterations);
    b[19] = params.parallelism;
    b[20] = saltLength;
    b.setAll(21, salt);
    b[37] = nonceLength;
    b.setAll(38, nonce);
    return b;
  }

  static Uint8List _random(int length) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
  }
}
