import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../backup/domain/integrity_check.dart';
import '../domain/startup_checks.dart';

/// Local error log (newest last) plus the latest integrity report.
class LogScreen extends ConsumerStatefulWidget {
  const LogScreen({super.key});

  @override
  ConsumerState<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends ConsumerState<LogScreen> {
  final _scroll = ScrollController();
  String? _log;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final text = await AppLogger.read();
    if (!mounted) return;
    setState(() => _log = text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus log?',
      message: 'Isi log aplikasi akan dikosongkan.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok) return;
    await AppLogger.clear();
    await _load();
  }

  Future<void> _checkNow() async {
    setState(() => _checking = true);
    try {
      final report = await ref.read(startupChecksProvider).checkNow(ref.read(clockProvider)());
      if (mounted) showSnack(context, report.ok ? 'Integrity check: OK' : 'Ditemukan ${report.summary.length} masalah');
    } catch (e, s) {
      AppLogger.error('Integrity check manual gagal', e, s);
      if (mounted) showSnack(context, 'Integrity check gagal: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    await _load();
  }

  Future<void> _deleteOrphans(IntegrityReport report) async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus file tanpa transaksi?',
      message: '${report.orphanFiles.length} file lampiran tidak terhubung ke transaksi mana pun '
          'dan akan dihapus permanen.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok) return;
    final n = await deleteOrphanFiles(report);
    AppLogger.info('File lampiran yatim dihapus: $n');
    if (mounted) showSnack(context, '$n file dihapus.');
    await _checkNow();
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final report = ref.watch(integrityReportProvider);
    final log = _log;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log aplikasi'),
        actions: [
          IconButton(tooltip: 'Muat ulang', onPressed: _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'Hapus log', onPressed: _clear, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: FinCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Integrity check', style: context.text.titleSmall),
                  const SizedBox(height: 4),
                  if (report == null)
                    Text('Belum ada hasil tersimpan.', style: context.text.bodySmall)
                  else ...[
                    Text(
                      '${formatDay(report.checkedAt)} ${formatTime(report.checkedAt)} · '
                      '${report.ok ? 'OK' : '${report.summary.length} masalah'}',
                      style: context.text.bodySmall!.copyWith(color: report.ok ? fin.positive : fin.warning),
                    ),
                    for (final line in report.summary) Text('• $line', style: context.text.bodySmall),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _checking ? null : _checkNow,
                        style: TextButton.styleFrom(foregroundColor: fin.text),
                        child: Text(_checking ? 'Memeriksa…' : 'Periksa sekarang'),
                      ),
                      if (report != null && report.orphanFiles.isNotEmpty)
                        TextButton(
                          onPressed: _checking ? null : () => _deleteOrphans(report),
                          style: TextButton.styleFrom(foregroundColor: fin.negative),
                          child: const Text('Hapus file tanpa transaksi'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: log == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : log.trim().isEmpty
                    ? const EmptyState(
                        icon: Icons.article_outlined,
                        title: 'Log kosong',
                        message: 'Error dan peristiwa penting aplikasi dicatat di sini, hanya di perangkat.',
                      )
                    : Scrollbar(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            log.trimRight(),
                            style: context.text.bodySmall!.copyWith(
                              fontFamily: 'monospace',
                              fontFamilyFallback: const ['Courier', 'monospace'],
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
