import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../security/presentation/app_lock_gate.dart';
import '../domain/csv_statement_parser.dart';
import '../domain/import_service.dart';
import '../domain/statement_models.dart';

/// Limit of one statement file read into memory (what the parsers assume).
const _maxStatementBytes = 20 * 1024 * 1024;

/// Entry screen for `/import`: pick the target account, then the CSV file.
class StatementImportEntryScreen extends ConsumerStatefulWidget {
  const StatementImportEntryScreen({super.key});

  @override
  ConsumerState<StatementImportEntryScreen> createState() => _StatementImportEntryScreenState();
}

class _StatementImportEntryScreenState extends ConsumerState<StatementImportEntryScreen> {
  Account? _account;

  Future<void> _pickFile(Account account) async {
    final PlatformFile? picked;
    try {
      picked = await AppLockGate.runExempt(
        () => FilePicker.pickFile(
          dialogTitle: 'Pilih file CSV mutasi rekening',
          type: FileType.custom,
          allowedExtensions: const ['csv', 'txt'],
        ),
      );
    } catch (e, s) {
      AppLogger.error('Memilih file mutasi gagal', e, s);
      if (mounted) showSnack(context, 'Tidak dapat membuka pemilih file.');
      return;
    }
    if (picked == null || picked.path == null || !mounted) return;

    final Uint8List bytes;
    try {
      final file = File(picked.path!);
      if (file.lengthSync() > _maxStatementBytes) {
        throw const StatementImportException(StatementErrors.tooLarge);
      }
      bytes = await file.readAsBytes();
    } on StatementImportException catch (e) {
      if (mounted) showSnack(context, e.message);
      return;
    } catch (e, s) {
      AppLogger.error('Membaca file mutasi gagal', e, s);
      if (mounted) showSnack(context, StatementErrors.unreadable);
      return;
    }

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatementImportReviewScreen(account: account, bytes: bytes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final accounts = ref.watch(activeAccountsProvider);
    final selected = _account;
    return Scaffold(
      appBar: AppBar(title: const Text('Impor Mutasi Bank')),
      body: accounts.isEmpty
          ? _EmptyAccounts(onAdd: () => Navigator.of(context).pop())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Impor mutasi rekening dari file CSV.', style: context.text.bodyMedium),
                const SizedBox(height: 12),
                if (accounts.length > 1) ...[
                  Text('Akun tujuan', style: context.text.labelLarge),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: selected?.id,
                    items: [
                      for (final a in accounts)
                        DropdownMenuItem<String>(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (id) => setState(
                      () => _account = accounts.where((x) => x.id == id).firstOrNull,
                    ),
                  ),
                ] else
                  Text('Akun: ${accounts.single.name}', style: context.text.bodyMedium),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: accounts.isEmpty ? null : () => _pickFile(accounts.single),
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Pilih file CSV'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Format yang didukung: ekspor CSV dari BCA, Mandiri, BNI, BRI, '
                  'Jago, SeaBank dan blu. Baris yang sudah ada sebelumnya ditandai '
                  'sebagai kemungkinan duplikat sebelum diimpor.',
                  style: context.text.bodySmall?.copyWith(color: fin.muted),
                ),
              ],
            ),
    );
  }
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.account_balance_outlined, size: 40),
          const SizedBox(height: 12),
          Text(
            'Tambahkan akun bank atau e-wallet dulu untuk mengimpor mutasinya.',
            textAlign: TextAlign.center,
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onAdd, child: const Text('Kembali')),
        ],
      ),
    ),
  );
}

/// Review screen: parsed rows, editable categories, duplicate warnings and a
/// column-mapping editor shown when auto-detection was not confident.
class StatementImportReviewScreen extends ConsumerStatefulWidget {
  const StatementImportReviewScreen({super.key, required this.account, required this.bytes});

  final Account account;
  final Uint8List bytes;

  @override
  ConsumerState<StatementImportReviewScreen> createState() => _StatementImportReviewScreenState();
}

class _StatementImportReviewScreenState extends ConsumerState<StatementImportReviewScreen> {
  late final StatementImportService _service;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(statementImportServiceProvider);
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      await _service.load(widget.bytes, accountId: widget.account.id, now: ref.read(clockProvider)());
    } on StatementImportException catch (e) {
      _error = e.message;
    } catch (e, s) {
      AppLogger.error('Menganalisa file mutasi gagal', e, s);
      _error = StatementErrors.unreadable;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remap(ColumnMapping mapping) async {
    setState(() => _busy = true);
    try {
      await _service.remap(mapping, now: ref.read(clockProvider)());
    } on StatementImportException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    setState(() => _busy = true);
    try {
      final result = await _service.commit(now: ref.read(clockProvider)());
      if (!mounted) return;
      final message = switch (result) {
        ImportResult(imported: 0, skipped: 0) => 'Tidak ada baris yang diimpor.',
        ImportResult(skipped: 0) => '${result.imported} transaksi diimpor.',
        _ => '${result.imported} diimpor, ${result.skipped} gagal. Cek catatan error untuk detail.',
      };
      showSnack(context, message);
      Navigator.of(context)..pop()..pop();
    } catch (e, s) {
      AppLogger.error('Impor mutasi gagal', e, s);
      if (mounted) showSnack(context, 'Impor gagal. Coba lagi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tinjau Mutasi')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onBack: () => Navigator.of(context).pop())
              : _buildReview(context),
    );
  }

  Widget _buildReview(BuildContext context) {
    final fin = context.fin;
    final analysis = _service.analysis!;
    final candidates = _service.candidates!;
    final dupes = candidates.where((c) => c.isDuplicate).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.account.name} · ${analysis.formatLabel}',
                      style: context.text.titleMedium,
                    ),
                  ),
                  if (!analysis.confident)
                    TextButton.icon(
                      onPressed: _busy ? null : () => _openMappingEditor(analysis),
                      icon: const Icon(Icons.table_chart_outlined, size: 18),
                      label: const Text('Atur kolom'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${candidates.length} baris terbaca'
                '${dupes > 0 ? ' · $dupes kemungkinan duplikat' : ''}'
                '${_service.skippedLines > 0 ? ' · ${_service.skippedLines} baris dilewati' : ''}',
                style: context.text.bodySmall?.copyWith(color: fin.muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: candidates.length,
            itemBuilder: (context, i) => _RowTile(
              key: ValueKey(i),
              index: i,
              candidate: candidates[i],
              service: _service,
              enabled: !_busy,
              onChanged: () => setState(() {}),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _commit,
                child: Text('Impor ${candidates.length - _service.excluded.length} transaksi'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openMappingEditor(CsvAnalysis analysis) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _MappingSheet(analysis: analysis, onApply: _remap),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});
  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: context.text.bodyMedium),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onBack, child: const Text('Kembali')),
        ],
      ),
    ),
  );
}

/// One parsed statement row with include/exclude, category picker and the
/// duplicate warning. Mutations go through [service]; the parent repaints
/// via [onChanged].
class _RowTile extends ConsumerWidget {
  const _RowTile({
    super.key,
    required this.index,
    required this.candidate,
    required this.service,
    required this.enabled,
    required this.onChanged,
  });

  final int index;
  final ImportCandidate candidate;
  final StatementImportService service;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final row = candidate.row;
    final excluded = service.excluded.contains(index);
    final categoryId = service.categoryIds[index] ?? service.suggestCategory(row);
    final income = row.direction == StatementDirection.credit;

    return Opacity(
      opacity: excluded ? 0.45 : 1,
      child: ListTile(
        onTap: enabled
            ? () {
                excluded ? service.excluded.remove(index) : service.excluded.add(index);
                onChanged();
              }
            : null,
        title: Text(
          row.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(decoration: excluded ? TextDecoration.lineThrough : null),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatDay(row.date)),
            if (candidate.isDuplicate)
              Text(
                'Kemungkinan duplikat: transaksi serupa sudah ada',
                style: TextStyle(color: fin.warning, fontWeight: FontWeight.w600),
              ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${income ? '+' : '-'}${formatRupiah(row.amount)}',
              style: TextStyle(
                color: income ? fin.positive : fin.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!excluded)
              GestureDetector(
                onTap: enabled ? () => _pickCategory(context, ref, categoryId) : null,
                child: Text(
                  'Kategori: ${_categoryName(ref, categoryId)} ›',
                  style: context.text.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _categoryName(WidgetRef ref, String? id) {
    if (id == null) return '-';
    return ref.read(categoryMapProvider)[id]?.name ?? '-';
  }

  Future<void> _pickCategory(BuildContext context, WidgetRef ref, String? current) async {
    final row = candidate.row;
    final type = row.direction == StatementDirection.credit ? CategoryType.income : CategoryType.expense;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Pilih kategori'),
        children: [
          for (final c in ref.read(activeCategoriesProvider(type)))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c.id),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (picked != null) {
      service.categoryIds[index] = picked;
      onChanged();
    }
  }
}

/// Column-mapping editor shown when auto-detection was not confident.
class _MappingSheet extends StatefulWidget {
  const _MappingSheet({required this.analysis, required this.onApply});
  final CsvAnalysis analysis;
  final void Function(ColumnMapping) onApply;

  @override
  State<_MappingSheet> createState() => _MappingSheetState();
}

class _MappingSheetState extends State<_MappingSheet> {
  late ColumnMapping _mapping = widget.analysis.mapping;

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Atur kolom', style: context.text.titleMedium),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < a.columnCount; i++) _roleDropdown(a, i),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _mapping.isComplete
                    ? () {
                        Navigator.of(context).pop();
                        widget.onApply(_mapping);
                      }
                    : null,
                child: const Text('Terapkan'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleDropdown(CsvAnalysis a, int i) {
    final role = _mapping.roleOf(i);
    final sampleRow = a.headerRow != null ? a.headerRow! + 1 : 0;
    final sample = sampleRow < a.table.length ? a.table[sampleRow].elementAtOrNull(i) ?? '' : '';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(a.columnName(i), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sample, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
      trailing: DropdownButton<ColumnRole?>(
        value: role,
        hint: const Text('—'),
        items: [
          const DropdownMenuItem<ColumnRole?>(child: Text('—')),
          for (final r in ColumnRole.values)
            DropdownMenuItem<ColumnRole?>(value: r, child: Text(r.label, style: const TextStyle(fontSize: 13))),
        ],
        onChanged: (r) => setState(() => _mapping = _mapping.withRole(i, r)),
      ),
    );
  }
}
