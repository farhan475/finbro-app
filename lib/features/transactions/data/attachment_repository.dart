import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';

final attachmentRepositoryProvider = Provider<AttachmentRepository>(
  (ref) => AttachmentRepository(ref.watch(databaseProvider)),
);

/// Unlinking attachments from a saved transaction. Attachments never affect
/// balances, so this does not go through LedgerService; linking new files
/// does (via `TransactionDraft.attachments`).
class AttachmentRepository {
  AttachmentRepository(this.db);

  final AppDatabase db;

  Future<void> remove(Iterable<String> attachmentIds) async {
    final ids = attachmentIds.toList();
    if (ids.isEmpty) return;
    final rows = await (db.select(db.attachments)..where((a) => a.id.isIn(ids))).get();
    await (db.delete(db.attachments)..where((a) => a.id.isIn(ids))).go();
    await deleteFiles(rows.map((a) => a.localPath));
  }

  /// Deletes private copies that were imported but never linked (form
  /// cancelled) or whose rows were removed. Paths outside the attachments
  /// directory (e.g. from a restored backup) are never touched.
  static Future<void> deleteFiles(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        if (!await AttachmentStorage.isManaged(path)) {
          AppLogger.info('Attachment di luar penyimpanan aplikasi tidak dihapus: $path');
          continue;
        }
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e, s) {
        AppLogger.error('Gagal menghapus attachment $path', e, s);
      }
    }
  }

  static Future<void> discardDrafts(Iterable<AttachmentDraft> drafts) =>
      deleteFiles(drafts.map((d) => d.localPath));
}
