import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/root.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../security/presentation/app_lock_gate.dart';
import '../domain/backup_service.dart';
import '../domain/restore_session.dart';

/// Lets the user pick a backup zip, then runs [restoreFromBytes].
Future<void> pickAndRestore(BuildContext context, WidgetRef ref) async {
  final PlatformFile? picked;
  try {
    picked = await AppLockGate.runExempt(
      () => FilePicker.pickFile(
        dialogTitle: 'Pilih file backup FinBro',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      ),
    );
  } catch (e, s) {
    AppLogger.error('Memilih file backup gagal', e, s);
    if (context.mounted) showSnack(context, 'Tidak dapat membuka pemilih file.');
    return;
  }
  if (picked == null || !context.mounted) return;
  final Uint8List? bytes;
  try {
    bytes = await _readCapped(picked, BackupService.maxBackupBytes);
  } catch (e, s) {
    AppLogger.error('Membaca file backup gagal', e, s);
    if (context.mounted) await _message(context, 'Backup ditolak', 'File tidak dapat dibaca.');
    return;
  }
  if (!context.mounted) return;
  if (bytes == null) {
    AppLogger.error('Backup ditolak: file melebihi ${BackupService.maxBackupBytes} byte');
    await _message(context, 'Backup ditolak', BackupService.oversizeMessage);
    return;
  }
  await restoreFromBytes(context, ref, bytes);
}

/// Bytes of [file], or null when it is larger than [maxBytes]: rejected from
/// the size the picker reports when known, otherwise while streaming, so an
/// oversized file is never read whole into memory.
Future<Uint8List?> _readCapped(PlatformFile file, int maxBytes) async {
  final size = file.lengthSync();
  if (size != null && size > maxBytes) return null;
  final out = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    out.add(chunk);
    if (out.length > maxBytes) return null;
  }
  return out.takeBytes();
}

/// 09-security §6: validate manifest → preview → confirm → safety snapshot →
/// replace database (restoring attachments) → integrity check (shown by
/// RestoreResultOverlay once the app has reopened the new database).
Future<void> restoreFromBytes(BuildContext context, WidgetRef ref, Uint8List bytes) async {
  final ValidatedBackup backup;
  try {
    backup = await BackupService.validateInBackground(bytes);
  } on BackupException catch (e) {
    AppLogger.error('Backup ditolak: ${e.message}');
    if (context.mounted) await _message(context, 'Backup ditolak', e.message);
    return;
  } catch (e, s) {
    AppLogger.error('Memeriksa file backup gagal', e, s);
    if (context.mounted) await _message(context, 'Backup ditolak', 'File backup tidak dapat diperiksa.');
    return;
  }
  if (!context.mounted) return;

  final m = backup.manifest;
  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Pratinjau backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PreviewRow('Tanggal backup', '${formatDay(m.createdAt)} ${formatTime(m.createdAt)}'),
          _PreviewRow('Transaksi', '${m.transactions}'),
          _PreviewRow('Akun', '${m.accounts}'),
          _PreviewRow('Lampiran', '${m.attachments}'),
          _PreviewRow('Versi skema', '${m.schemaVersion}'),
          if (m.schemaVersion < AppDatabase.currentSchemaVersion) ...[
            const SizedBox(height: 8),
            Text(
              'Backup dari versi lebih lama; data dimigrasikan otomatis saat dibuka.',
              style: context.text.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Lanjutkan')),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return;

  final confirmed = await confirmDialog(
    context,
    title: 'Ganti semua data?',
    message: 'Semua data di aplikasi ini akan diganti dengan isi backup tanggal '
        '${formatDay(m.createdAt)}. Snapshot data saat ini dibuat dulu di folder backups '
        'sehingga bisa dipulihkan kembali.',
    confirmLabel: 'Restore',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;

  final service = ref.read(backupServiceProvider);
  final now = ref.read(clockProvider)();
  final snapshotName = BackupService.fileNameFor(now, prefix: BackupService.safetyPrefix);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 16),
            Expanded(child: Text('Membuat snapshot dan memulihkan data…')),
          ],
        ),
      ),
    ),
  );
  try {
    await service.restore(
      backup,
      now: now,
      replaceDatabase: (replace) {
        if (!context.mounted) {
          throw const BackupException('Layar restore tertutup sebelum data diganti.');
        }
        // This screen is disposed while the DB is swapped; the outcome is
        // posted before FinBroRoot reopens so the new tree can show it.
        return FinBroRoot.replaceDatabase(context, (dbFile) async {
          try {
            await replace(dbFile);
            RestoreSession.post(RestoreSucceeded(manifest: m, snapshotName: snapshotName));
          } catch (e) {
            RestoreSession.post(RestoreFailed(
              message: e is BackupException ? e.message : 'Terjadi kesalahan: $e',
              snapshotName: snapshotName,
            ));
            rethrow;
          }
        });
      },
    );
  } catch (e, s) {
    AppLogger.error('Restore gagal', e, s);
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      await _message(context, 'Restore gagal', e is BackupException ? e.message : 'Terjadi kesalahan: $e');
    }
  }
}

Future<void> _message(BuildContext context, String title, String message) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
  ),
);

class _PreviewRow extends StatelessWidget {
  const _PreviewRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label, style: context.text.bodyMedium!.copyWith(color: context.fin.muted))),
        Text(value, style: context.text.bodyMedium),
      ],
    ),
  );
}
