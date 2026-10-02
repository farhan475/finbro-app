import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../transactions/data/transaction_query_repository.dart';
import '../data/merchant_mapping_repository.dart';
import '../domain/date_time_parser.dart';
import '../domain/duplicate_detector.dart';
import '../domain/merchant_text.dart';
import '../domain/provider_detector.dart';
import '../domain/scan_models.dart';

/// Editable draft from a scan. Low-confidence amount/date are highlighted
/// with a text label (not color only). Saving is the only DB write.
class ScanReviewView extends ConsumerStatefulWidget {
  const ScanReviewView({
    super.key,
    required this.imagePath,
    required this.parse,
    required this.onSaved,
    required this.onRetake,
    this.ocrError,
  });

  final String imagePath;
  final ScanParse parse;
  final String? ocrError;
  final VoidCallback onSaved;
  final VoidCallback onRetake;

  @override
  ConsumerState<ScanReviewView> createState() => _ScanReviewViewState();
}

class _ScanReviewViewState extends ConsumerState<ScanReviewView> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _merchant = TextEditingController();

  late TransactionType _type;
  late DateTime _at;
  String? _categoryId;
  String? _accountId;
  MerchantSuggestion? _suggestion;
  bool _saving = false;

  /// SHA-256 of the scanned image, computed once (off the UI isolate) and
  /// reused for duplicate detection and the attachment import.
  String? _imageHash;

  /// Fields the user edited; their confidence badge no longer applies.
  final Set<String> _touched = {};

  ScanParse get _p => widget.parse;

  @override
  void initState() {
    super.initState();
    _type = _p.direction.value == TransactionType.income ? TransactionType.income : TransactionType.expense;
    _at = _p.dateTime ?? ref.read(clockProvider)();
    final amount = _p.amount.value;
    if (amount != null && amount > 0) _amount.text = MoneyField.textFor(amount);
    final merchant = _p.merchant.value;
    if (merchant != null) _merchant.text = prettifyMerchant(merchant);
    // Only a real text change (not focus/cursor moves) clears the OCR badge.
    final prefill = _amount.text;
    _amount.addListener(() {
      if (_amount.text != prefill) _touch('amount');
    });
    _loadDefaults();
  }

  void _touch(String field) {
    if (_touched.contains(field)) return;
    setState(() => _touched.add(field));
  }

  Future<void> _loadDefaults() async {
    final accounts = await ref.read(allAccountsProvider.future);
    final active = [for (final a in accounts) if (a.isActive) a];
    String? accountId;
    final provider = _p.provider.value;
    if (provider != null) accountId = accountForProvider(active, provider)?.id;
    if (accountId == null && _p.paidInCash) {
      accountId = active.where((a) => a.type == AccountType.cash).firstOrNull?.id;
    }
    accountId ??= await ref.read(transactionQueryRepositoryProvider).lastUsedAccountId();
    if (accountId != null && !active.any((a) => a.id == accountId)) accountId = null;
    accountId ??= active.firstOrNull?.id;

    final merchant = _p.merchant.value;
    if (merchant != null) {
      final s = await ref.read(merchantMappingRepositoryProvider).suggest(merchant, type: _categoryType);
      if (!mounted) return;
      _suggestion = s;
      final normalized = s?.normalizedMerchant;
      if (normalized != null && !_touched.contains('merchant')) _merchant.text = normalized;
      _categoryId ??= s?.categoryId;
    }
    if (!mounted) return;
    setState(() => _accountId ??= accountId);
  }

  CategoryType get _categoryType =>
      _type == TransactionType.income ? CategoryType.income : CategoryType.expense;

  Future<void> _pickDateTime() async {
    final now = ref.read(clockProvider)();
    final date = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: scanFirstDate,
      lastDate: scanLastDate(now),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (!mounted) return;
    setState(() {
      _at = DateTime(date.year, date.month, date.day, time?.hour ?? _at.hour, time?.minute ?? _at.minute);
      _touched.add('date');
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final amount = parseRupiah(_amount.text)!;
    final accountId = _accountId;
    if (accountId == null) {
      showSnack(context, 'Pilih account.');
      return;
    }
    if (_categoryId == null) {
      showSnack(context, 'Pilih kategori.');
      return;
    }
    setState(() => _saving = true);
    try {
      final image = File(widget.imagePath);
      final hash = _imageHash ??= await AttachmentStorage.hashFile(image);
      final merchant = _merchant.text.trim();
      final duplicates = await ref.read(duplicateDetectorProvider).find(
        amount: amount,
        transactionAt: _at,
        merchant: merchant.isEmpty ? null : merchant,
        categoryId: _categoryId,
        imageHash: hash,
      );
      if (duplicates.isNotEmpty && mounted && !await _confirmDuplicates(duplicates)) {
        setState(() => _saving = false);
        return;
      }

      final attachment = await AttachmentStorage.import(image, _p.source.attachmentKind, imageHash: hash);
      final reference = _p.reference.value;
      final note = [
        if (merchant.isNotEmpty) merchant,
        if (reference != null) 'Ref $reference',
      ].join(' · ');
      try {
        await ref.read(ledgerServiceProvider).create(
          TransactionDraft(
            type: _type,
            amount: amount,
            accountId: accountId,
            categoryId: _categoryId,
            transactionAt: _at,
            note: note,
            sourceType: _p.source.sourceType,
            attachments: [attachment],
          ),
        );
      } catch (_) {
        // Transaction not created: remove the orphaned private copy.
        await File(attachment.localPath).delete().catchError((_) => File(attachment.localPath));
        rethrow;
      }

      final rawMerchant = _p.merchant.value;
      if (rawMerchant != null && merchant.isNotEmpty) {
        await ref.read(merchantMappingRepositoryProvider).remember(
          rawMerchant: rawMerchant,
          normalizedMerchant: merchant,
          categoryId: _categoryId,
        );
      }
      if (!mounted) return;
      showSnack(context, 'Transaksi dari scan tersimpan.');
      widget.onSaved();
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error('Gagal menyimpan hasil scan', e, s);
      if (mounted) showSnack(context, 'Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDuplicates(List<DuplicateCandidate> list) async {
    final categories = ref.read(categoryMapProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kemungkinan duplikat'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('Transaksi serupa sudah tercatat:', style: context.text.bodyMedium),
              const SizedBox(height: 8),
              for (final d in list.take(5))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${formatRupiah(d.transaction.amount)} · ${categories[d.transaction.categoryId]?.name ?? d.transaction.type.label}',
                        style: context.text.titleSmall,
                      ),
                      Text(
                        [
                          '${formatDay(d.transaction.transactionAt)} ${formatTime(d.transaction.transactionAt)}',
                          ?d.transaction.note,
                        ].join(' · '),
                        style: context.text.bodySmall,
                      ),
                      Text(d.reasons.map((r) => r.label).join('; '), style: context.text.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tetap simpan')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _viewImage() {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(child: Image.file(File(widget.imagePath))),
              ),
            ),
            SafeArea(
              child: IconButton(
                tooltip: 'Tutup',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final categories = ref.watch(activeCategoriesProvider(_categoryType));
    final accounts = ref.watch(activeAccountsProvider);
    final status = _p.status.value;
    final provider = _p.provider.value;
    final breakdown = _p.breakdown;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (widget.ocrError != null) ...[
            _Notice(icon: Icons.info_outline, text: widget.ocrError!),
            const SizedBox(height: 12),
          ],
          GestureDetector(
            onTap: _viewImage,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Container(
                height: 180,
                color: fin.surface2,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(widget.imagePath),
                      fit: BoxFit.cover,
                      // Decode at screen width, not the photo's full resolution.
                      cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round(),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: fin.surface, borderRadius: BorderRadius.circular(10)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.zoom_in, size: 16, color: fin.text),
                            const SizedBox(width: 4),
                            Text('Perbesar', style: context.text.labelMedium),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Draft — belum tersimpan. Periksa setiap field sebelum konfirmasi.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 16),
          SegmentedButton<TransactionType>(
            segments: const [
              ButtonSegment(value: TransactionType.expense, label: SegmentLabel('Expense')),
              ButtonSegment(value: TransactionType.income, label: SegmentLabel('Income')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _categoryId = null;
              _touched.add('type');
            }),
          ),
          const SizedBox(height: 16),
          _ConfidenceLabel(field: 'Nominal', confidence: _touched.contains('amount') ? null : _p.amount),
          const SizedBox(height: 6),
          _Highlight(
            active: !_touched.contains('amount') && _p.amount.confidence != FieldConfidence.high,
            child: MoneyField(controller: _amount, large: true),
          ),
          if (!breakdown.isEmpty) ...[
            const SizedBox(height: 8),
            _BreakdownText(breakdown),
          ],
          const SizedBox(height: 16),
          _ConfidenceLabel(field: 'Tanggal & waktu', confidence: _touched.contains('date') ? null : _p.date),
          const SizedBox(height: 6),
          _Highlight(
            active: !_touched.contains('date') && _p.date.confidence != FieldConfidence.high,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.input),
              onTap: _pickDateTime,
              child: InputDecorator(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.calendar_today_outlined, size: 20)),
                child: Text('${formatWeekday(_at)} ${_at.year} · ${formatTime(_at)}'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _ConfidenceLabel(
            field: _p.source == ScanSource.receipt ? 'Merchant' : 'Penerima / merchant',
            confidence: _touched.contains('merchant') ? null : _p.merchant,
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _merchant,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Disimpan sebagai catatan'),
            onChanged: (_) => _touch('merchant'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Kategori',
              helperText: _suggestion?.categoryId != null && _suggestion!.categoryId == _categoryId
                  ? [_suggestion!.source.label, ?_suggestion!.seedMerchant].join(' · ')
                  : null,
            ),
            items: [
              for (final c in categories)
                DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
            validator: (v) => v == null ? 'Pilih kategori' : null,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: accounts.any((a) => a.id == _accountId) ? _accountId : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Account',
              helperText: provider != null ? 'Terdeteksi: ${provider.label}' : null,
            ),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _accountId = v),
            validator: (v) => v == null ? 'Pilih account' : null,
          ),
          if (status != null || _p.reference.value != null || _p.items.isNotEmpty) ...[
            const SizedBox(height: 16),
            FinCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (status != null)
                    _InfoRow(
                      'Status',
                      status.label,
                      color: status == PaymentStatus.success ? fin.positive : fin.warning,
                    ),
                  if (_p.reference.value != null) _InfoRow('Referensi', _p.reference.value!),
                  if (_p.items.isNotEmpty) _InfoRow('Item terbaca', '${_p.items.length} baris'),
                ],
              ),
            ),
            if (status == PaymentStatus.failed || status == PaymentStatus.pending) ...[
              const SizedBox(height: 8),
              _Notice(
                icon: Icons.warning_amber_outlined,
                text: 'Status transaksi di gambar: ${status!.label}. Pastikan uang benar-benar berpindah.',
              ),
            ],
          ],
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Teks hasil OCR', style: context.text.titleSmall),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: fin.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.input),
                  ),
                  child: SelectableText(
                    _p.rawText.trim().isEmpty ? '(kosong)' : _p.rawText,
                    style: context.text.bodySmall!.copyWith(fontFamily: 'monospace', color: fin.text),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fin.onPrimary),
                  )
                : const Text('Konfirmasi & Simpan'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _saving ? null : widget.onRetake, child: const Text('Scan ulang')),
        ],
      ),
    );
  }
}

/// Field label with confidence text; `confidence == null` hides the badge.
class _ConfidenceLabel extends StatelessWidget {
  const _ConfidenceLabel({required this.field, required this.confidence});
  final String field;
  final Extracted<Object?>? confidence;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final c = confidence;
    final (label, color, icon) = switch (c) {
      null => (null, fin.muted, null),
      _ when !c.isPresent => ('Tidak terbaca', fin.warning, Icons.error_outline),
      _ => switch (c.confidence) {
        FieldConfidence.high => (c.confidence.label, fin.muted, Icons.check_circle_outline),
        FieldConfidence.medium => (c.confidence.label, fin.warning, Icons.help_outline),
        FieldConfidence.low => (c.confidence.label, fin.warning, Icons.error_outline),
      },
    };
    return Row(
      children: [
        Expanded(child: Text(field, style: context.text.labelMedium)),
        if (label != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: context.text.labelSmall!.copyWith(color: color)),
        ],
      ],
    );
  }
}

/// Warning outline around a field that needs checking.
class _Highlight extends StatelessWidget {
  const _Highlight({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 200),
    padding: EdgeInsets.all(active ? 3 : 0),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(AppRadius.input + 3),
      border: active ? Border.all(color: context.fin.warning, width: 1.5) : null,
    ),
    child: child,
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => FinCard(
    color: context.fin.surface2,
    padding: const EdgeInsets.all(12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: context.fin.warning),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: context.text.bodySmall!.copyWith(color: context.fin.text))),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label, style: context.text.bodySmall)),
        Flexible(
          fit: FlexFit.tight,
          child: Text(
            value,
            style: context.text.labelLarge!.copyWith(color: color),
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

class _BreakdownText extends StatelessWidget {
  const _BreakdownText(this.b);
  final ReceiptBreakdown b;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (b.subtotal != null) 'Subtotal ${formatRupiah(b.subtotal!)}',
      if (b.discount != null) 'Diskon ${formatRupiah(b.discount!)}',
      if (b.tax != null) 'Pajak ${formatRupiah(b.tax!)}',
      if (b.service != null) 'Service ${formatRupiah(b.service!)}',
      if (b.cash != null) 'Dibayar ${formatRupiah(b.cash!)}',
      if (b.change != null) 'Kembali ${formatRupiah(b.change!)}',
    ];
    return Text(parts.join(' · '), style: context.text.bodySmall);
  }
}
