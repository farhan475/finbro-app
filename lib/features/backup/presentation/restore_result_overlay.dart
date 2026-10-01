import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../domain/integrity_check.dart';
import '../domain/restore_session.dart';

/// Shows the outcome of a restore once the provider tree is rebuilt on the
/// reopened database, running the post-restore integrity check first.
/// Mounted by AppLockGate above the Navigator, so it draws its own scrim.
class RestoreResultOverlay extends ConsumerStatefulWidget {
  const RestoreResultOverlay({super.key});

  @override
  ConsumerState<RestoreResultOverlay> createState() => _RestoreResultOverlayState();
}

class _RestoreResultOverlayState extends ConsumerState<RestoreResultOverlay> {
  RestoreOutcome? _outcome;
  IntegrityReport? _report;
  String? _checkError;

  @override
  void initState() {
    super.initState();
    _outcome = RestoreSession.take();
    if (_outcome is RestoreSucceeded) _check();
  }

  Future<void> _check() async {
    try {
      final report = await runIntegrityCheck(
        ref.read(databaseProvider),
        await AttachmentStorage.directory(),
        now: ref.read(clockProvider)(),
        trigger: 'restore',
      );
      await saveIntegrityReport(ref.read(appSettingsRepositoryProvider), report);
      if (mounted) setState(() => _report = report);
    } catch (e, s) {
      AppLogger.error('Integrity check setelah restore gagal', e, s);
      if (mounted) setState(() => _checkError = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    if (outcome == null) return const SizedBox.shrink();
    final fin = context.fin;
    final (title, lines, color) = switch (outcome) {
      RestoreSucceeded(:final manifest, :final snapshotName) => (
        'Restore selesai',
        [
          'Backup ${formatDay(manifest.createdAt)} ${formatTime(manifest.createdAt)}',
          '${manifest.transactions} transaksi · ${manifest.accounts} akun · ${manifest.attachments} lampiran',
          'Snapshot data sebelumnya: $snapshotName',
        ],
        fin.text,
      ),
      RestoreFailed(:final message, :final snapshotName) => (
        'Restore gagal',
        [message, 'Data sebelumnya tetap dipakai. Snapshot: $snapshotName'],
        fin.negative,
      ),
    };
    final report = _report;
    return Material(
      color: Colors.black54,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.text.titleLarge!.copyWith(color: color)),
                    const SizedBox(height: 12),
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(l, style: context.text.bodyMedium),
                      ),
                    if (outcome is RestoreSucceeded) ...[
                      const SizedBox(height: 12),
                      Text('Integrity check', style: context.text.titleSmall),
                      const SizedBox(height: 6),
                      if (_checkError != null)
                        Text('Tidak dapat dijalankan: $_checkError', style: TextStyle(color: fin.negative))
                      else if (report == null)
                        const LinearProgressIndicator(minHeight: 2)
                      else if (report.ok)
                        Text('OK — database dan lampiran konsisten.', style: TextStyle(color: fin.positive))
                      else
                        for (final p in report.summary)
                          Text('• $p', style: TextStyle(color: fin.warning)),
                    ],
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: outcome is RestoreSucceeded && report == null && _checkError == null
                            ? null
                            : () => setState(() => _outcome = null),
                        child: const Text('Tutup'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
