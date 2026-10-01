import 'dart:io';

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

  /// Copies [source] into private storage and returns a ready-to-link draft
  /// including the SHA-256 hash used for duplicate detection.
  static Future<AttachmentDraft> import(File source, AttachmentKind kind) async {
    final bytes = await source.readAsBytes();
    final ext = p.extension(source.path).toLowerCase();
    final dir = await directory();
    final target = File(p.join(dir.path, '${newId()}${ext.isEmpty ? '.jpg' : ext}'));
    await target.writeAsBytes(bytes, flush: true);
    return AttachmentDraft(
      localPath: target.path,
      mimeType: _mime(ext),
      kind: kind,
      imageHash: sha256.convert(bytes).toString(),
    );
  }

  static Future<String> hashFile(File f) async =>
      sha256.convert(await f.readAsBytes()).toString();

  static String _mime(String ext) => switch (ext) {
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    '.pdf' => 'application/pdf',
    _ => 'image/jpeg',
  };
}
