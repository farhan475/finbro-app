import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/root.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../security/presentation/app_lock_gate.dart';
import '../data/folder_backup_platform.dart';
import '../domain/backup_service.dart';
import '../domain/encrypted_backup.dart';
import '../domain/restore_session.dart';

/// Lets the user pick a backup zip, then validates it from disk.
Future<void> pickAndRestore(BuildContext context, WidgetRef ref) async {
  final PlatformFile? picked;
  try {
    picked = await AppLockGate.runExempt(() => FilePicker.pickFile(dialogTitle: 'Pilih file backup FinBro', type: FileType.custom, allowedExtensions: const ['zip']));
  } catch (e, s) {
    AppLogger.error('Memilih file backup gagal', e, s);
    if (context.mounted) showSnack(context, 'Tidak dapat membuka pemilih file.');
    return;
  }
  if (picked == null || !context.mounted) return;
  final file = picked.path == null ? null : File(picked.path!);
  if (file == null) { if (context.mounted) await _message(context, 'Backup ditolak', 'File tidak dapat dibaca.'); return; }
  await restoreFromFile(context, ref, file);
}

/// Lets the user pick an encrypted `.finbro` backup, decrypts it to a
/// temporary zip (with this device's key when it matches the file, else the
/// passphrase) and restores that through [restoreFromFile]. The picked copy
/// and the decrypted zip are deleted on every path.
Future<void> pickAndRestoreEncrypted(BuildContext context, WidgetRef ref) async {
  final File? picked;
  try {
    picked = await SafBackupFolderAccess.pickEncryptedFile(await getTemporaryDirectory());
  } on BackupException catch (e) {
    if (context.mounted) await _message(context, 'Backup ditolak', e.message);
    return;
  } catch (e, s) {
    AppLogger.error('Memilih backup terenkripsi gagal', e, s);
    if (context.mounted) showSnack(context, 'File backup terenkripsi tidak dapat dibuka.');
    return;
  }
  if (picked == null) return;
  final work = picked.parent;
  try {
    if (!context.mounted) return;
    final zip = await _decrypt(context, ref, picked, File(p.join(work.path, 'decrypted.zip')));
    if (zip == null || !context.mounted) return;
    await restoreFromFile(context, ref, zip);
  } finally {
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
}

/// Decrypts [encrypted] into [out]; null (after telling the user) when the
/// file is rejected or the user cancels the passphrase prompt. A wrong
/// passphrase re-prompts.
Future<File?> _decrypt(BuildContext context, WidgetRef ref, File encrypted, File out) async {
  final EncryptedHeader header;
  try {
    header = await EncryptedBackup.readHeader(encrypted);
  } on BackupException catch (e) {
    if (context.mounted) await _message(context, 'Backup ditolak', e.message);
    return null;
  } catch (e, s) {
    AppLogger.error('Membaca backup terenkripsi gagal', e, s);
    if (context.mounted) await _message(context, 'Backup ditolak', 'File backup terenkripsi tidak dapat dibaca.');
    return null;
  }

  // Backups made on this device with the current passphrase need no prompt.
  BackupKey? stored;
  try {
    stored = await ref.read(backupKeyStoreProvider).read();
  } catch (e, s) {
    AppLogger.error('Membaca kunci backup gagal', e, s);
  }
  String? error;
  if (stored != null && stored.fitsHeader(header) && context.mounted) {
    final key = stored;
    error = await _tryDecrypt(context, 'Mendekripsi backup…', () => EncryptedBackup.decryptWithKey(encrypted, out, key));
    if (error == null) return out;
    if (error != EncryptedBackup.wrongKeyMessage) {
      if (context.mounted) await _message(context, 'Backup ditolak', error);
      return null;
    }
    error = null; // the stored key did not open it after all: ask instead
  }

  while (true) {
    if (!context.mounted) return null;
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => _UnlockDialog(error: error),
    );
    if (passphrase == null || !context.mounted) return null;
    BackupKey? recovered;
    error = await _tryDecrypt(
      context,
      'Membuka backup terenkripsi…',
      () async => recovered = await EncryptedBackup.decryptWithPassphrase(encrypted, out, passphrase),
    );
    if (error == null) {
      // A device without a backup key (fresh install, new phone) adopts the
      // key of the backup it restores, so automatic folder backups continue
      // with the same passphrase. An existing, different key is never replaced.
      final key = recovered;
      if (stored == null && key != null) await _adoptKey(ref, key);
      return out;
    }
    if (error != EncryptedBackup.wrongKeyMessage) {
      if (context.mounted) await _message(context, 'Backup ditolak', error);
      return null;
    }
  }
}

Future<void> _adoptKey(WidgetRef ref, BackupKey key) async {
  try {
    await ref.read(folderBackupServiceProvider).setKey(key);
    AppLogger.info('Kunci backup terenkripsi disimpan dari backup yang direstore');
  } catch (e, s) {
    AppLogger.error('Menyimpan kunci backup gagal', e, s);
  }
}

/// Runs [decrypt] behind a progress dialog; null on success, else the
/// message to show.
Future<String?> _tryDecrypt(BuildContext context, String label, Future<Object?> Function() decrypt) async {
  _showProgress(context, label);
  try {
    await decrypt();
    return null;
  } on BackupException catch (e) {
    return e.message;
  } catch (e, s) {
    AppLogger.error('Mendekripsi backup gagal', e, s);
    return 'File backup terenkripsi tidak dapat dibuka.';
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

void _showProgress(BuildContext context, String label) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => PopScope(
    canPop: false,
    child: AlertDialog(
      content: Row(
        children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
        ],
      ),
    ),
  ),
);

Future<void> restoreFromFile(BuildContext context, WidgetRef ref, File zipFile) async {
  if (await zipFile.length() > BackupService.maxBackupBytes) {
    if (context.mounted) await _message(context, 'Backup ditolak', BackupService.oversizeMessage);
    return;
  }
  final ValidatedBackup backup;
  try {
    backup = await BackupService.validateFile(zipFile);
  } on BackupException catch (e) {
    AppLogger.error('Backup ditolak: ${e.message}');
    if (context.mounted) await _message(context, 'Backup ditolak', e.message);
    return;
  } catch (e, s) {
    AppLogger.error('Memeriksa file backup gagal', e, s);
    if (context.mounted) await _message(context, 'Backup ditolak', 'File backup tidak dapat diperiksa.');
    return;
  }
  if (!context.mounted) {
    await backup.dispose();
    return;
  }
  await _restoreValidated(context, ref, backup);
}

/// 09-security §6: validate manifest → preview → confirm → safety snapshot →
/// replace database (restoring attachments) → integrity check.
Future<void> _restoreValidated(BuildContext context, WidgetRef ref, ValidatedBackup backup) async {
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
  if (proceed != true || !context.mounted) {
    await backup.dispose();
    return;
  }

  final confirmed = await confirmDialog(
    context,
    title: 'Ganti semua data?',
    message: 'Semua data di aplikasi ini akan diganti dengan isi backup tanggal '
        '${formatDay(m.createdAt)}. Snapshot data saat ini dibuat dulu di folder backups '
        'sehingga bisa dipulihkan kembali.',
    confirmLabel: 'Restore',
    destructive: true,
  );
  if (!confirmed || !context.mounted) {
    await backup.dispose();
    return;
  }

  final service = ref.read(backupServiceProvider);
  final now = ref.read(clockProvider)();
  final snapshotName = BackupService.fileNameFor(now, prefix: BackupService.safetyPrefix);
  _showProgress(context, 'Membuat snapshot dan memulihkan data…');
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
        return FinBroRoot.replaceDatabase(context, (live) async {
          try {
            await replace(live);
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
  } finally {
    await backup.dispose();
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

/// Passphrase prompt for an encrypted backup; pops the entered passphrase.
class _UnlockDialog extends StatefulWidget {
  const _UnlockDialog({this.error});
  final String? error;

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isEmpty) return;
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Passphrase backup'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Masukkan passphrase yang dipakai saat backup ini dibuat.', style: context.text.bodySmall),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              widget.error!,
              style: context.text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          autofocus: true,
          controller: _controller,
          obscureText: _obscure,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Passphrase',
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            ),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Batal')),
      FilledButton(onPressed: _submit, child: const Text('Buka')),
    ],
  );
}
