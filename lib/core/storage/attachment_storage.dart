import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/enums.dart';
import '../ledger/ledger_service.dart';
import '../utilities/ids.dart';

/// Receipt/screenshot files live in app-private storage (09-security §3).
abstract final class AttachmentStorage {
  static Future<Directory> directory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'attachments'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Whether [path] canonicalizes to a file strictly inside [attachmentsDir].
  /// Every delete/read of a `local_path` value from the database must pass
  /// this check: the column can come from an untrusted restored backup.
  static bool isWithin(String attachmentsDir, String path) =>
      path.isNotEmpty && p.isWithin(p.canonicalize(attachmentsDir), p.canonicalize(path));

  /// [isWithin] against the app's attachments [directory].
  static Future<bool> isManaged(String path) async =>
      isWithin((await directory()).path, path);

  /// Copies [source] into private storage and returns a ready-to-link draft
  /// including the SHA-256 hash used for duplicate detection ([imageHash])
  /// and the file checksum stored for integrity verification ([fileSha256]).
  /// Pass [imageHash] when the caller already hashed [source] to skip
  /// re-hashing.
  static Future<AttachmentDraft> import(File source, AttachmentKind kind, {String? imageHash}) async {
    final ext = p.extension(source.path).toLowerCase();
    final dir = await directory();
    final target = File(p.join(dir.path, '${newId()}${ext.isEmpty ? '.jpg' : ext}'));
    await source.copy(target.path);
    final hash = await hashFile(target);
    return AttachmentDraft(
      localPath: target.path,
      mimeType: _mime(ext),
      kind: kind,
      imageHash: imageHash ?? hash,
      fileSha256: hash,
    );
  }

  /// SHA-256 of [f], computed off the UI isolate.
  static Future<String> hashFile(File f) {
    final path = f.path;
    return Isolate.run(() => sha256.convert(File(path).readAsBytesSync()).toString());
  }

  static String _mime(String ext) => switch (ext) {
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    '.pdf' => 'application/pdf',
    _ => 'image/jpeg',
  };
}
