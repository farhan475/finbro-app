import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:cryptography/cryptography.dart'
    show Mac, SecretBox, SecretBoxAuthenticationError, SecretKey, SecretKeyData;
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

/// Parsed, not yet authenticated header of a `.finbro` file, with the chunk
/// layout implied by the file length.
class EncryptedHeader {
  const EncryptedHeader({
    required this.bytes,
    required this.params,
    required this.salt,
    required this.noncePrefix,
    required this.chunkSize,
    required this.chunkCount,
    required this.lastChunkLength,
  });

  /// The raw header (associated data of every chunk).
  final Uint8List bytes;
  final KdfParams params;
  final Uint8List salt;
  final Uint8List noncePrefix;

  /// Plaintext bytes per chunk; every chunk but the last is full.
  final int chunkSize;
  final int chunkCount;

  /// Stored length (ciphertext ‖ tag) of the last chunk.
  final int lastChunkLength;
}

/// `.finbro` container: header + the backup zip ([BackupService.buildPackage]
/// output) as a sequence of AES-256-GCM chunks, so encryption and decryption
/// stream file to file and never hold the zip in memory. Layout, big-endian:
///
/// | offset | size | field                                   |
/// |--------|------|-----------------------------------------|
/// | 0      | 8    | magic `FINBROEN`                        |
/// | 8      | 2    | format version (2)                      |
/// | 10     | 1    | KDF id (1 = Argon2id v1.3)              |
/// | 11     | 4    | Argon2id memory (KiB)                   |
/// | 15     | 4    | Argon2id iterations                     |
/// | 19     | 1    | Argon2id parallelism                    |
/// | 20     | 1    | salt length (16)                        |
/// | 21     | 16   | salt                                    |
/// | 37     | 1    | nonce prefix length (7)                 |
/// | 38     | 7    | nonce prefix                            |
/// | 45     | 4    | chunk size (plaintext bytes per chunk)  |
/// | 49     | …    | chunks: ciphertext ‖ 16-byte GCM tag    |
///
/// Every chunk holds `chunk size` plaintext bytes except the last (0 to
/// `chunk size`; an empty zip is one tag-only chunk). Chunk `i` uses nonce
/// `prefix ‖ uint32 i ‖ last-flag` (STREAM construction) and the whole
/// header as associated data, so changing a header byte, reordering,
/// dropping, truncating or appending chunks all fail authentication. Crypto
/// runs on background isolates.
abstract final class EncryptedBackup {
  static const extension = '.finbro';
  static const mimeType = 'application/octet-stream';
  static const formatVersion = 2;
  static const kdfArgon2id = 1;
  static const keyLength = 32;
  static const saltLength = 16;
  static const noncePrefixLength = 7;
  static const tagLength = 16;
  static const headerLength = 49;
  static const minPassphraseLength = 8;
  static final magic = Uint8List.fromList(ascii.encode('FINBROEN'));

  static const defaultChunkSize = 1024 * 1024;

  // Accepted chunk sizes when reading a header (bounds memory per chunk and
  // the tag overhead in [maxFileBytes]).
  static const minChunkSize = 64 * 1024;
  static const maxChunkSize = 16 * 1024 * 1024;

  /// Largest `.finbro` accepted: the zip limit plus header and the tags of
  /// the smallest allowed chunk size.
  static const maxFileBytes =
      BackupService.maxBackupBytes + headerLength + tagLength * (BackupService.maxBackupBytes ~/ minChunkSize + 1);

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

  /// Encrypts the backup zip [zip] into [out] with [key] (fresh random nonce
  /// prefix), chunk by chunk on a background isolate. [out] is removed when
  /// encryption fails.
  static Future<void> encrypt(File zip, File out, BackupKey key, {int chunkSize = defaultChunkSize}) async {
    if (chunkSize < minChunkSize || chunkSize > maxChunkSize) {
      throw ArgumentError.value(chunkSize, 'chunkSize');
    }
    if (await zip.length() > BackupService.maxBackupBytes) {
      throw const BackupException(BackupService.oversizeMessage);
    }
    final prefix = _random(noncePrefixLength);
    final header = _header(key.params, key.salt, prefix, chunkSize);
    final keyBytes = key.key;
    final inPath = zip.path;
    final outPath = out.path;
    await _cleanOnError(out, () => Isolate.run(() => _encryptSync(inPath, outPath, header, prefix, chunkSize, keyBytes)));
  }

  /// Parses and bounds-checks the header and chunk layout of [file]. Throws
  /// [BackupException] for anything that is not a supported `.finbro`.
  static Future<EncryptedHeader> readHeader(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      return _parseHeader(await raf.read(headerLength), length);
    } finally {
      await raf.close();
    }
  }

  /// Decrypts [file] into [out] with an already derived [key] on a
  /// background isolate. Throws [BackupException] ([wrongKeyMessage]) when
  /// authentication fails; [out] is removed on any failure.
  static Future<void> decryptWithKey(File file, File out, BackupKey key) async {
    final header = await readHeader(file);
    if (!key.fitsHeader(header)) throw const BackupException(wrongKeyMessage);
    final keyBytes = key.key;
    final inPath = file.path;
    final outPath = out.path;
    await _cleanOnError(out, () => Isolate.run(() => _decryptSync(inPath, outPath, header, keyBytes)));
  }

  /// Derives the key with the salt and parameters stored in [file]'s header
  /// and decrypts it into [out], both on one background isolate. Returns the
  /// key (usable for further backups with the same passphrase).
  static Future<BackupKey> decryptWithPassphrase(File file, File out, String passphrase, {DateTime? now}) async {
    final header = await readHeader(file);
    final created = now ?? DateTime.now();
    final inPath = file.path;
    final outPath = out.path;
    final keyBytes = await _cleanOnError(out, () => Isolate.run(() async {
      final keyBytes = await _derive(passphrase, header.salt, header.params);
      _decryptSync(inPath, outPath, header, keyBytes);
      return keyBytes;
    }));
    return BackupKey(key: keyBytes, salt: header.salt, params: header.params, createdAt: created);
  }

  static EncryptedHeader _parseHeader(Uint8List head, int fileLength) {
    if (fileLength > maxFileBytes) throw const BackupException(oversizeMessage);
    if (head.length < magic.length ||
        !const ListEquality<int>().equals(head.sublist(0, magic.length), magic)) {
      throw const BackupException(notEncryptedMessage);
    }
    if (head.length < 11) throw const BackupException(truncatedMessage);
    final data = ByteData.sublistView(head);
    final version = data.getUint16(8);
    if (version != formatVersion) {
      throw BackupException(
        'Format backup terenkripsi versi $version tidak didukung aplikasi ini. '
        'Perbarui FinBro lalu coba lagi.',
      );
    }
    final kdf = head[10];
    if (kdf != kdfArgon2id) {
      throw BackupException(
        'Metode kunci (KDF $kdf) pada file backup tidak dikenal. Perbarui FinBro lalu coba lagi.',
      );
    }
    if (head.length < headerLength || fileLength < headerLength + tagLength) {
      throw const BackupException(truncatedMessage);
    }
    final params = KdfParams(
      memoryKiB: data.getUint32(11),
      iterations: data.getUint32(15),
      parallelism: head[19],
    );
    final chunkSize = data.getUint32(45);
    if (!params.isValid ||
        head[20] != saltLength ||
        head[37] != noncePrefixLength ||
        chunkSize < minChunkSize ||
        chunkSize > maxChunkSize) {
      throw const BackupException(badParamsMessage);
    }
    // Chunk layout from the body length: full chunks, then a shorter last
    // one unless the body ends exactly on a chunk boundary.
    final body = fileLength - headerLength;
    final full = chunkSize + tagLength;
    final rest = body % full;
    if (rest > 0 && rest < tagLength) throw const BackupException(truncatedMessage);
    final chunkCount = body ~/ full + (rest > 0 ? 1 : 0);
    if (body - chunkCount * tagLength > BackupService.maxBackupBytes) {
      throw const BackupException(oversizeMessage);
    }
    return EncryptedHeader(
      bytes: Uint8List.fromList(head.sublist(0, headerLength)),
      params: params,
      salt: Uint8List.fromList(head.sublist(21, 21 + saltLength)),
      noncePrefix: Uint8List.fromList(head.sublist(38, 38 + noncePrefixLength)),
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      lastChunkLength: rest > 0 ? rest : full,
    );
  }

  static void _encryptSync(
    String inPath,
    String outPath,
    Uint8List header,
    Uint8List prefix,
    int chunkSize,
    Uint8List keyBytes,
  ) {
    final aes = DartAesGcm.with256bits();
    final secret = SecretKeyData(keyBytes);
    final input = File(inPath).openSync();
    final output = File(outPath).openSync(mode: FileMode.writeOnly);
    try {
      final length = input.lengthSync();
      if (length > BackupService.maxBackupBytes) throw const BackupException(BackupService.oversizeMessage);
      final count = length == 0 ? 1 : (length + chunkSize - 1) ~/ chunkSize;
      output.writeFromSync(header);
      for (var i = 0; i < count; i++) {
        final want = min(chunkSize, length - i * chunkSize);
        final clear = input.readSync(want);
        if (clear.length != want) throw const BackupException('File backup berubah saat dienkripsi.');
        final box = aes.encryptSync(clear, secretKeyData: secret, nonce: _chunkNonce(prefix, i, i == count - 1), aad: header);
        output
          ..writeFromSync(box.cipherText)
          ..writeFromSync(box.mac.bytes);
      }
      output.flushSync();
    } finally {
      input.closeSync();
      output.closeSync();
    }
  }

  static void _decryptSync(String inPath, String outPath, EncryptedHeader header, Uint8List keyBytes) {
    final aes = DartAesGcm.with256bits();
    final secret = SecretKeyData(keyBytes);
    final input = File(inPath).openSync();
    final output = File(outPath).openSync(mode: FileMode.writeOnly);
    try {
      input.setPositionSync(headerLength);
      for (var i = 0; i < header.chunkCount; i++) {
        final last = i == header.chunkCount - 1;
        final length = last ? header.lastChunkLength : header.chunkSize + tagLength;
        final chunk = input.readSync(length);
        if (chunk.length != length) throw const BackupException(truncatedMessage);
        final box = SecretBox(
          Uint8List.sublistView(chunk, 0, length - tagLength),
          nonce: _chunkNonce(header.noncePrefix, i, last),
          mac: Mac(Uint8List.sublistView(chunk, length - tagLength)),
        );
        output.writeFromSync(aes.decryptSync(box, secretKeyData: secret, aad: header.bytes));
      }
      // The file grew after its header was read: never accept extra bytes.
      if (input.positionSync() != input.lengthSync()) throw const BackupException(wrongKeyMessage);
      output.flushSync();
    } on SecretBoxAuthenticationError {
      throw const BackupException(wrongKeyMessage);
    } finally {
      input.closeSync();
      output.closeSync();
    }
  }

  static Future<T> _cleanOnError<T>(File out, Future<T> Function() run) async {
    try {
      return await run();
    } catch (_) {
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static Uint8List _chunkNonce(Uint8List prefix, int index, bool last) {
    final n = Uint8List(12)..setAll(0, prefix);
    ByteData.sublistView(n).setUint32(noncePrefixLength, index);
    n[11] = last ? 1 : 0;
    return n;
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

  static Uint8List _header(KdfParams params, Uint8List salt, Uint8List prefix, int chunkSize) {
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
    b[37] = noncePrefixLength;
    b.setAll(38, prefix);
    d.setUint32(45, chunkSize);
    return b;
  }

  static Uint8List _random(int length) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
  }
}
