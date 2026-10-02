import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/app_theme.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../security/presentation/app_lock_gate.dart';
import '../domain/backup_service.dart';
import '../domain/csv_export.dart';
import 'restore_flow.dart';

/// Local backups and safety snapshots with size and time, newest first.
final localBackupsProvider = FutureProvider.autoDispose<List<({File file, int size, DateTime modified})>>(
  (ref) async {
    final files = await ref.watch(backupServiceProvider).localBackups();
    return [
      for (final f in files) (file: f, size: await f.length(), modified: await f.lastModified()),
    ];
  },
);

/// Saves [bytes] to a user-chosen location (Android SAF). Returns false when
/// the user cancelled.
Future<bool> saveExternally(String fileName, Uint8List bytes, String mimeType) async {
  final uri = await AppLockGate.runExempt(
    () => FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType, dialogTitle: 'Simpan $fileName'),
  );
  return uri != null;
}

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  String? _busy;

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = label);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _backup() => _run('Membuat backup…', () async {
    final now = ref.read(clockProvider)();
    final ({BackupPackage package, File file}) created;
    try {
      created = await ref.read(backupServiceProvider).createBackup(now);
    } catch (e, s) {
      AppLogger.error('Backup gagal', e, s);
      if (mounted) showSnack(context, 'Backup gagal: ${e is BackupException ? e.message : e}');
      return;
    }
    if (!mounted) return;
    ref.invalidate(localBackupsProvider);
    await _offerExternalCopy(created.package.fileName, created.package.bytes, 'application/zip');
  });

  Future<void> _offerExternalCopy(String name, Uint8List bytes, String mime) async {
    try {
      final saved = await saveExternally(name, bytes, mime);
      if (!mounted) return;
      showSnack(
        context,
        saved
            ? '$name disimpan.'
            : '$name tersimpan di penyimpanan aplikasi. Salinan eksternal dibatalkan.',
      );
    } catch (e, s) {
      AppLogger.error('Menyimpan salinan eksternal gagal', e, s);
      if (mounted) showSnack(context, '$name tersimpan di penyimpanan aplikasi; salinan eksternal gagal.');
    }
  }

  Future<void> _exportCsv() => _run('Menyiapkan CSV…', () async {
    final now = ref.read(clockProvider)();
    final String csv;
    try {
      csv = await buildTransactionsCsv(ref.read(databaseProvider));
    } catch (e, s) {
      AppLogger.error('Menyiapkan CSV gagal', e, s);
      if (mounted) showSnack(context, 'Export CSV gagal: $e');
      return;
    }
    if (!mounted) return;
    final name = transactionsCsvFileName(now);
    try {
      final saved = await saveExternally(name, utf8.encode(csv), 'text/csv');
      if (mounted) showSnack(context, saved ? '$name disimpan.' : 'Export CSV dibatalkan.');
    } catch (e, s) {
      AppLogger.error('Export CSV gagal', e, s);
      if (mounted) showSnack(context, 'Export CSV gagal: $e');
    }
  });

  Future<void> _backupActions(File file) async {
    final name = p.basename(file.path);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(name, style: context.text.titleSmall, overflow: TextOverflow.ellipsis)),
            ListTile(
              leading: const Icon(Icons.settings_backup_restore),
              title: const Text('Restore dari backup ini'),
              onTap: () => Navigator.pop(context, 'restore'),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Simpan salinan ke…'),
              onTap: () => Navigator.pop(context, 'save'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: context.fin.negative),
              title: Text('Hapus', style: TextStyle(color: context.fin.negative)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'restore':
        final bytes = await _readBackup(file);
        if (bytes == null || !mounted) return;
        await restoreFromBytes(context, ref, bytes);
      case 'save':
        final bytes = await _readBackup(file);
        if (bytes == null || !mounted) return;
        await _offerExternalCopy(name, bytes, 'application/zip');
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: 'Hapus backup?',
          message: '$name akan dihapus dari perangkat. Salinan di luar aplikasi tidak terpengaruh.',
          confirmLabel: 'Hapus',
          destructive: true,
        );
        if (!ok || !mounted) return;
        try {
          await file.delete();
        } catch (e, s) {
          AppLogger.error('Menghapus backup gagal', e, s);
          if (mounted) showSnack(context, 'Gagal menghapus $name.');
          return;
        }
        if (!mounted) return;
        ref.invalidate(localBackupsProvider);
        showSnack(context, '$name dihapus.');
    }
  }

  /// Bytes of a local backup, or null (after telling the user) when it is
  /// too large or cannot be read.
  Future<Uint8List?> _readBackup(File file) async {
    try {
      if (await file.length() > BackupService.maxBackupBytes) {
        if (mounted) showSnack(context, BackupService.oversizeMessage);
        return null;
      }
      return await file.readAsBytes();
    } catch (e, s) {
      AppLogger.error('Membaca file backup gagal', e, s);
      if (mounted) showSnack(context, 'File backup tidak dapat dibaca.');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final lastRaw = ref.watch(appSettingsProvider).value?[SettingKeys.lastBackupAt];
    final last = DateTime.tryParse(lastRaw ?? '');
    final backups = ref.watch(localBackupsProvider);
    final busy = _busy != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) ...[
            LinearProgressIndicator(minHeight: 2, color: fin.primary),
            const SizedBox(height: 8),
            Text(_busy!, style: context.text.bodySmall),
            const SizedBox(height: 8),
          ],
          FinCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backup terakhir', style: context.text.bodySmall!.copyWith(color: fin.muted)),
                const SizedBox(height: 4),
                Text(
                  last == null ? 'Belum pernah backup' : '${formatDay(last)} ${formatTime(last)}',
                  style: context.text.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Backup berisi database, semua lampiran, dan manifest (versi skema + checksum). '
                  'Simpan salinannya di luar perangkat agar aman bila ponsel hilang.',
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy ? null : _backup,
            icon: const Icon(Icons.backup_outlined),
            label: const Text('Buat backup'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : () => pickAndRestore(context, ref),
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('Restore dari file'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : _exportCsv,
            icon: const Icon(Icons.table_chart_outlined),
            label: const Text('Export CSV transaksi'),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Backup di perangkat'),
          AsyncView(
            value: backups,
            builder: (list) => list.isEmpty
                ? const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'Belum ada backup',
                    message: 'Backup dan snapshot keamanan tersimpan di sini.',
                  )
                : Card(
                    child: Column(
                      children: [
                        for (final b in list)
                          ListTile(
                            enabled: !busy,
                            leading: Icon(
                              p.basename(b.file.path).startsWith(BackupService.safetyPrefix)
                                  ? Icons.shield_outlined
                                  : Icons.archive_outlined,
                            ),
                            title: Text(
                              p.basename(b.file.path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${formatDay(b.modified)} ${formatTime(b.modified)} · ${_size(b.size)}'
                              '${p.basename(b.file.path).startsWith(BackupService.safetyPrefix) ? ' · snapshot keamanan' : ''}',
                            ),
                            trailing: const Icon(Icons.more_vert),
                            onTap: () => _backupActions(b.file),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            'Restore selalu membuat snapshot keamanan data saat ini sebelum mengganti database. '
            'Backup dari versi aplikasi yang lebih baru ditolak.',
            style: context.text.bodySmall!.copyWith(color: fin.muted),
          ),
        ],
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
