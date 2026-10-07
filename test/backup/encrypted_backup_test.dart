import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:finbro_app/features/backup/domain/backup_service.dart';
import 'package:finbro_app/features/backup/domain/encrypted_backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // Cheap Argon2id parameters; the format stores them in the header.
  const fastKdf = KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);
  const chunk = EncryptedBackup.minChunkSize;
  late Directory tmp;
  late BackupKey key;

  setUpAll(() async {
    key = await EncryptedBackup.deriveKey('rahasia-panjang', params: fastKdf);
  });

  setUp(() async => tmp = await Directory.systemTemp.createTemp('finbro-enc-test-'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> plain(int length, {int seed = 1}) async {
    final r = Random(seed);
    final f = File(p.join(tmp.path, 'plain-$length.zip'));
    await f.writeAsBytes(Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256))));
    return f;
  }

  Future<File> sealed(File source) async {
    final out = File(p.join(tmp.path, '${p.basenameWithoutExtension(source.path)}${EncryptedBackup.extension}'));
    await EncryptedBackup.encrypt(source, out, key, chunkSize: chunk);
    return out;
  }

  File target() => File(p.join(tmp.path, 'out-${DateTime.now().microsecondsSinceEpoch}.zip'));

  Future<void> expectRejected(Future<void> Function() run, String message) async {
    await expectLater(run, throwsA(isA<BackupException>().having((e) => e.message, 'message', message)));
  }

  test('file round-trip is byte-identical across chunk boundaries', () async {
    for (final length in [0, 1, chunk - 1, chunk, chunk + 1, 2 * chunk + 17]) {
      final source = await plain(length, seed: length);
      final enc = await sealed(source);
      final out = target();
      await EncryptedBackup.decryptWithKey(enc, out, key);
      expect(await out.readAsBytes(), await source.readAsBytes(), reason: 'length $length');
    }
  });

  test('passphrase decrypts and yields a key that fits the file; a wrong one is rejected', () async {
    final source = await plain(chunk + 5);
    final enc = await sealed(source);

    final wrongOut = target();
    await expectRejected(
      () => EncryptedBackup.decryptWithPassphrase(enc, wrongOut, 'rahasia-salah'),
      EncryptedBackup.wrongKeyMessage,
    );
    expect(await wrongOut.exists(), isFalse, reason: 'partial output is removed');

    final out = target();
    final recovered = await EncryptedBackup.decryptWithPassphrase(enc, out, 'rahasia-panjang');
    expect(await out.readAsBytes(), await source.readAsBytes());
    expect(recovered.key, key.key);
    expect(recovered.fitsHeader(await EncryptedBackup.readHeader(enc)), isTrue);
  });

  test('a key derived from another passphrase or salt is rejected', () async {
    final enc = await sealed(await plain(10));
    final other = await EncryptedBackup.deriveKey('rahasia-panjang', params: fastKdf);
    await expectRejected(() => EncryptedBackup.decryptWithKey(enc, target(), other), EncryptedBackup.wrongKeyMessage);
  });

  test('tampering, dropping or appending chunks fails authentication', () async {
    final source = await plain(3 * chunk); // three full chunks
    final enc = await sealed(source);
    final bytes = await enc.readAsBytes();
    const full = chunk + EncryptedBackup.tagLength;

    Future<File> variant(String name, Uint8List data) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes(data);
      return f;
    }

    final flipped = Uint8List.fromList(bytes)..[EncryptedBackup.headerLength + 100] ^= 1;
    final noncePrefix = Uint8List.fromList(bytes)..[40] ^= 1;
    // Drops the final chunk: what remains ends on a chunk boundary, but its
    // last chunk was not sealed as the final one.
    final truncated = Uint8List.sublistView(bytes, 0, bytes.length - full);
    final swapped = Uint8List.fromList(bytes)
      ..setRange(EncryptedBackup.headerLength, EncryptedBackup.headerLength + full,
          bytes.sublist(EncryptedBackup.headerLength + full, EncryptedBackup.headerLength + 2 * full))
      ..setRange(EncryptedBackup.headerLength + full, EncryptedBackup.headerLength + 2 * full,
          bytes.sublist(EncryptedBackup.headerLength, EncryptedBackup.headerLength + full));
    final appended = Uint8List.fromList([...bytes, ...bytes.sublist(bytes.length - full)]);

    for (final (name, data) in [
      ('flipped', flipped),
      ('nonce', noncePrefix),
      ('truncated', truncated),
      ('swapped', swapped),
      ('appended', appended),
    ]) {
      final out = target();
      await expectRejected(
        () async => EncryptedBackup.decryptWithKey(await variant('$name.finbro', data), out, key),
        EncryptedBackup.wrongKeyMessage,
      );
      expect(await out.exists(), isFalse, reason: name);
    }
  });

  test('non-.finbro and cut-off files are rejected before any key work', () async {
    final zip = await plain(200);
    await expectRejected(() => EncryptedBackup.readHeader(zip), EncryptedBackup.notEncryptedMessage);

    final enc = await sealed(await plain(chunk + 100));
    final bytes = await enc.readAsBytes();
    // Last chunk shorter than a tag.
    final cut = File(p.join(tmp.path, 'cut.finbro'))
      ..writeAsBytesSync(bytes.sublist(0, EncryptedBackup.headerLength + chunk + EncryptedBackup.tagLength + 5));
    await expectRejected(() => EncryptedBackup.readHeader(cut), EncryptedBackup.truncatedMessage);
  });
}
