import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/folder_backup_platform.dart';
import '../domain/backup_service.dart';
import '../domain/encrypted_backup.dart';
import '../domain/folder_backup_service.dart';

/// "Backup terenkripsi ke folder": passphrase, SAF folder, schedule,
/// retention, status, manual run and switching it off. Long actions go
/// through [run] so the screen shows one progress indicator.
class FolderBackupSection extends ConsumerWidget {
  const FolderBackupSection({super.key, required this.busy, required this.run});

  final bool busy;
  final Future<void> Function(String label, Future<void> Function() action) run;

  FolderBackupService _service(WidgetRef ref) => ref.read(folderBackupServiceProvider);

  Future<void> _setPassphrase(BuildContext context, WidgetRef ref, {required bool change}) async {
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => _PassphraseDialog(change: change),
    );
    if (passphrase == null || !context.mounted) return;
    await run('Menyiapkan kunci backup…', () async {
      final service = _service(ref);
      final now = ref.read(clockProvider)();
      try {
        await service.setKey(await EncryptedBackup.deriveKey(passphrase, now: now));
      } catch (e, s) {
        AppLogger.error('Menyimpan kunci backup gagal', e, s);
        if (context.mounted) showSnack(context, 'Passphrase gagal disimpan.');
        return;
      }
      if (!context.mounted) return;
      ref.invalidate(backupKeyProvider);
      showSnack(context, change ? 'Passphrase diganti. Backup berikutnya memakai passphrase baru.' : 'Passphrase diatur.');
    });
  }

  Future<void> _pickFolder(BuildContext context, WidgetRef ref, {required bool hasKey}) async {
    final ({String uri, String name})? picked;
    try {
      picked = await ref.read(backupFolderAccessProvider).pick();
    } catch (e, s) {
      AppLogger.error('Memilih folder backup gagal', e, s);
      if (context.mounted) showSnack(context, 'Tidak dapat membuka pemilih folder.');
      return;
    }
    if (picked == null || !context.mounted) return;
    try {
      await _service(ref).setFolder(picked.uri, picked.name);
    } catch (e, s) {
      AppLogger.error('Menyimpan folder backup gagal', e, s);
      if (context.mounted) showSnack(context, 'Folder gagal disimpan.');
      return;
    }
    if (!context.mounted) return;
    ref.invalidate(folderWritableProvider);
    if (!hasKey) {
      await _setPassphrase(context, ref, change: false);
    } else {
      showSnack(context, 'Backup terenkripsi akan disimpan di ${picked.name}.');
    }
  }

  Future<void> _backupNow(BuildContext context, WidgetRef ref) => run('Mengenkripsi backup ke folder…', () async {
    try {
      final name = await _service(ref).backupNow(ref.read(clockProvider)());
      if (context.mounted) showSnack(context, '$name disimpan di folder backup.');
    } on BackupException catch (e) {
      if (context.mounted) showSnack(context, 'Backup folder gagal: ${e.message}');
    }
    if (context.mounted) ref.invalidate(folderWritableProvider);
  });

  Future<void> _disable(BuildContext context, WidgetRef ref) async {
    final ok = await confirmDialog(
      context,
      title: 'Matikan backup folder?',
      message: 'Izin folder dilepas dan kunci backup dihapus dari perangkat ini. File .finbro yang '
          'sudah ada tetap di folder dan masih bisa dibuka dengan passphrase-nya.',
      confirmLabel: 'Matikan',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await _service(ref).disable();
    } catch (e, s) {
      AppLogger.error('Mematikan backup folder gagal', e, s);
      if (context.mounted) showSnack(context, 'Backup folder gagal dimatikan.');
      return;
    }
    if (!context.mounted) return;
    ref.invalidate(backupKeyProvider);
    showSnack(context, 'Backup folder dimatikan.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final status = ref.watch(folderBackupStatusProvider);
    final keyValue = ref.watch(backupKeyProvider);
    final key = keyValue.value;
    final writable = ref.watch(folderWritableProvider).value;
    final hasKey = key != null;
    final service = _service(ref);
    final lastAt = status.lastSuccessAt;
    final lastErrorAt = status.lastErrorAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Backup terenkripsi ke folder'),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                enabled: !busy && !keyValue.isLoading,
                leading: const Icon(Icons.key_outlined),
                title: const Text('Passphrase'),
                subtitle: Text(
                  keyValue.isLoading
                      ? 'Memeriksa…'
                      : key != null
                          ? 'Diatur ${formatDay(key.createdAt)}'
                          : 'Belum diatur',
                ),
                trailing: Text(hasKey ? 'Ubah' : 'Atur', style: context.text.labelLarge!.copyWith(color: fin.primary)),
                onTap: () => _setPassphrase(context, ref, change: hasKey),
              ),
              ListTile(
                enabled: !busy && !keyValue.isLoading,
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Folder'),
                subtitle: Text(
                  !status.hasFolder
                      ? 'Belum dipilih'
                      : writable == false
                          ? '${status.folderName ?? 'Folder'} · izin akses hilang, pilih ulang'
                          : status.folderName ?? 'Folder dipilih',
                  style: writable == false ? TextStyle(color: fin.negative) : null,
                ),
                trailing: Text(
                  status.hasFolder ? 'Ganti' : 'Pilih',
                  style: context.text.labelLarge!.copyWith(color: fin.primary),
                ),
                onTap: () => _pickFolder(context, ref, hasKey: hasKey),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('Jadwal', style: context.text.bodySmall!.copyWith(color: fin.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SegmentedButton<BackupInterval>(
                  segments: [
                    for (final i in BackupInterval.values) ButtonSegment(value: i, label: SegmentLabel(i.label)),
                  ],
                  selected: {status.interval},
                  onSelectionChanged: busy ? null : (s) => service.setInterval(s.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Simpan backup terbaru di folder',
                  style: context.text.bodySmall!.copyWith(color: fin.muted),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (final k in FolderBackupService.keepChoices) ButtonSegment(value: k, label: SegmentLabel('$k')),
                  ],
                  selected: {status.keep},
                  onSelectionChanged: busy ? null : (s) => service.setKeep(s.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Backup folder terakhir', style: context.text.bodySmall!.copyWith(color: fin.muted)),
                    const SizedBox(height: 4),
                    Text(
                      lastAt == null ? 'Belum pernah' : '${formatDay(lastAt)} ${formatTime(lastAt)}',
                      style: context.text.titleSmall,
                    ),
                    if (status.failing && lastErrorAt != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline, size: 18, color: fin.negative),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Gagal ${formatDay(lastErrorAt)} ${formatTime(lastErrorAt)}: ${status.lastError}',
                              style: context.text.bodySmall!.copyWith(color: fin.negative),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: busy || !status.hasFolder || !hasKey ? null : () => _backupNow(context, ref),
          icon: const Icon(Icons.enhanced_encryption_outlined),
          label: const Text('Backup sekarang'),
        ),
        if (status.hasFolder || hasKey) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: busy ? null : () => _disable(context, ref),
            icon: Icon(Icons.power_settings_new, color: fin.negative),
            label: Text('Matikan backup folder', style: TextStyle(color: fin.negative)),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Backup dienkripsi (AES-256) dengan kunci dari passphrase Anda dan berjalan otomatis bila jadwalnya '
          'tiba: saat aplikasi dibuka, atau di latar belakang sekitar tiap 6 jam (bisa ditunda Android saat '
          'hemat baterai). Hanya file finbro-*.finbro di folder itu yang dirapikan.',
          style: context.text.bodySmall!.copyWith(color: fin.muted),
        ),
      ],
    );
  }
}

/// New passphrase with confirmation; pops the passphrase once it passes
/// [EncryptedBackup.passphraseProblem].
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.change});
  final bool change;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = EncryptedBackup.passphraseProblem(_passphrase.text, _confirmation.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(_passphrase.text);
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final toggle = IconButton(
      onPressed: () => setState(() => _obscure = !_obscure),
      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
    );
    return AlertDialog(
      title: Text(widget.change ? 'Ganti passphrase backup' : 'Atur passphrase backup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: fin.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Passphrase tidak disimpan dan tidak bisa dipulihkan. Bila lupa, backup terenkripsi '
                    'tidak dapat dibuka sama sekali.',
                    style: context.text.bodySmall,
                  ),
                ),
              ],
            ),
            if (widget.change) ...[
              const SizedBox(height: 8),
              Text(
                'Backup lama tetap memakai passphrase lama; simpan passphrase itu bila ingin membukanya.',
                style: context.text.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              controller: _passphrase,
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                helperText: 'Minimal ${EncryptedBackup.minPassphraseLength} karakter',
                suffixIcon: toggle,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmation,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: 'Ulangi passphrase', errorText: _error),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Batal')),
        FilledButton(onPressed: _submit, child: const Text('Simpan')),
      ],
    );
  }
}
