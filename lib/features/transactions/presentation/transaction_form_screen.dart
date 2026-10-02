import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../security/presentation/app_lock_gate.dart';
import '../data/attachment_repository.dart';
import '../data/transaction_query_repository.dart';
import '../ledger_paths.dart';
import 'widgets/transaction_widgets.dart';

/// Create (`/transaction/new?type=`) or edit (`/transaction/:id/edit`) an
/// income, expense or transfer. Field order follows 06-ux §11:
/// Amount → Type → Category → Account → Date → Note → Attachment.
class TransactionFormScreen extends ConsumerStatefulWidget {
  const TransactionFormScreen({super.key, this.initialType, this.initialAccountId, this.transactionId});

  final TransactionType? initialType;

  /// Preselected account for new rows; defaults to the last used account.
  final String? initialAccountId;
  final String? transactionId;

  bool get isEdit => transactionId != null;

  @override
  ConsumerState<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends ConsumerState<TransactionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _amountFocus = FocusNode();

  late TransactionType _type;
  late DateTime _at;
  String? _categoryId;
  String? _accountId;
  String? _toAccountId;
  AttachmentKind _attachmentKind = AttachmentKind.receipt;

  /// Files imported in this session, not yet linked to a transaction.
  final List<AttachmentDraft> _pending = [];

  /// Existing attachments the user removed (applied on save).
  final Set<String> _removed = {};

  LedgerTransaction? _original;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType ?? TransactionType.expense;
    _at = ref.read(clockProvider)();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.transactionId;
      if (id != null) {
        final db = ref.read(databaseProvider);
        final tx = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (!mounted) return;
        if (tx == null) {
          _missing = true;
        } else {
          _original = tx;
          _type = tx.type;
          _amount.text = MoneyField.textFor(tx.amount);
          _categoryId = tx.categoryId;
          _accountId = tx.accountId;
          _toAccountId = tx.transferToAccountId;
          _at = tx.transactionAt;
          _note.text = tx.note ?? '';
        }
      } else {
        _accountId =
            widget.initialAccountId ?? await ref.read(transactionQueryRepositoryProvider).lastUsedAccountId();
      }
    } catch (e, s) {
      AppLogger.error('Gagal memuat form transaksi', e, s);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    // Imported files that were never saved must not linger in storage.
    if (_pending.isNotEmpty) AttachmentRepository.discardDrafts(List.of(_pending));
    _amount.dispose();
    _note.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  /// Active accounts, plus the edited row's accounts even when archived
  /// (history can still be corrected; ledger rejects new postings to them).
  List<Account> _accountChoices(List<Account> all) {
    final keep = {_original?.accountId, _original?.transferToAccountId};
    return [
      for (final a in all)
        if (a.isActive || keep.contains(a.id)) a,
    ];
  }

  String? _resolvedAccount(List<Account> choices) {
    if (choices.any((a) => a.id == _accountId)) return _accountId;
    return choices.firstOrNull?.id;
  }

  String? _resolvedDestination(List<Account> choices, String? source) {
    if (_toAccountId != source && choices.any((a) => a.id == _toAccountId)) return _toAccountId;
    return choices.firstWhereOrNull((a) => a.id != source)?.id;
  }

  CategoryType get _categoryType =>
      _type == TransactionType.income ? CategoryType.income : CategoryType.expense;

  void _setType(TransactionType t) {
    setState(() {
      if (t != TransactionType.transfer) {
        final cat = ref.read(categoryMapProvider)[_categoryId];
        final wanted = t == TransactionType.income ? CategoryType.income : CategoryType.expense;
        if (cat?.type != wanted) _categoryId = null;
      }
      _type = t;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (d == null) return;
    setState(() => _at = DateTime(d.year, d.month, d.day, _at.hour, _at.minute));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (t == null) return;
    setState(() => _at = DateTime(_at.year, _at.month, _at.day, t.hour, t.minute));
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      // The camera/gallery activity pauses the app; it must not re-lock it.
      final x = await AppLockGate.runExempt(
        () => ImagePicker().pickImage(source: source, imageQuality: 85, maxWidth: 2400),
      );
      if (x == null) return;
      final draft = await AttachmentStorage.import(File(x.path), _attachmentKind);
      if (!mounted) {
        await AttachmentRepository.discardDrafts([draft]);
        return;
      }
      setState(() => _pending.add(draft));
    } on PlatformException catch (e, s) {
      AppLogger.error('Gagal mengambil gambar', e, s);
      if (mounted) {
        showSnack(
          context,
          source == ImageSource.camera
              ? 'Kamera tidak bisa dibuka. Periksa izin kamera.'
              : 'Galeri tidak bisa dibuka. Periksa izin penyimpanan.',
        );
      }
    } catch (e, s) {
      AppLogger.error('Gagal menyimpan lampiran', e, s);
      if (mounted) showSnack(context, 'Lampiran gagal disimpan.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removePending(AttachmentDraft d) {
    setState(() => _pending.remove(d));
    AttachmentRepository.discardDrafts([d]);
  }

  Future<void> _save({required List<Account> choices, bool addAnother = false}) async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final accountId = _resolvedAccount(choices);
    if (accountId == null) {
      showSnack(context, 'Tambahkan account terlebih dahulu.');
      return;
    }
    final isTransfer = _type == TransactionType.transfer;
    // The save owns these files from here on: if the screen is disposed while
    // saving, dispose must not delete files that are about to be linked.
    final linking = List.of(_pending);
    _pending.clear();
    final draft = TransactionDraft(
      type: _type,
      amount: parseRupiah(_amount.text) ?? 0,
      accountId: accountId,
      categoryId: isTransfer ? null : _categoryId,
      transferToAccountId: isTransfer ? _resolvedDestination(choices, accountId) : null,
      transactionAt: _at,
      note: _note.text,
      sourceType: _original?.sourceType ?? SourceType.manual,
      recurringInstanceId: _original?.recurringInstanceId,
      attachments: linking,
    );

    setState(() => _saving = true);
    final ledger = ref.read(ledgerServiceProvider);
    var saved = false;
    try {
      final original = _original;
      if (original == null) {
        await ledger.create(draft);
      } else {
        await ledger.update(original.id, draft);
      }
      saved = true;
      if (original != null) await ref.read(attachmentRepositoryProvider).remove(_removed);
      _removed.clear();
      if (!mounted) return;
      if (addAnother) {
        setState(() {
          _amount.clear();
          _note.clear();
          _categoryId = null;
          _accountId = accountId;
          _at = ref.read(clockProvider)();
        });
        showSnack(context, 'Transaksi tersimpan. Lanjut catat berikutnya.');
        _amountFocus.requestFocus();
      } else {
        final messenger = ScaffoldMessenger.of(context);
        _close();
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(original == null ? 'Transaksi tersimpan.' : 'Perubahan tersimpan.')));
      }
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error('Gagal menyimpan transaksi', e, s);
      if (mounted) showSnack(context, 'Transaksi gagal disimpan. Coba lagi.');
    } finally {
      if (!saved) {
        // Not linked: hand the files back to the form, or drop them if it is gone.
        if (mounted) {
          _pending.insertAll(0, linking);
        } else {
          AttachmentRepository.discardDrafts(linking);
        }
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.activity);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isEdit ? 'Edit transaksi' : 'Tambah transaksi';
    if (_loading || !ref.watch(allAccountsProvider).hasValue || !ref.watch(allCategoriesProvider).hasValue) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(
          child: EmptyState(icon: Icons.search_off, title: 'Transaksi tidak ditemukan', message: 'Mungkin sudah dihapus.'),
        ),
      );
    }

    final choices = _accountChoices(ref.watch(allAccountsProvider).value!);
    if (choices.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Belum ada account',
            message: 'Transaksi perlu account sumber dana, misalnya Cash atau BCA.',
            actionLabel: 'Tambah account',
            onAction: () => context.push(LedgerPaths.accountNew),
          ),
        ),
      );
    }

    final accountId = _resolvedAccount(choices);
    final isTransfer = _type == TransactionType.transfer;
    final destinationId = isTransfer ? _resolvedDestination(choices, accountId) : null;

    return PopScope(
      // Leaving mid-save would race the posting; wait for it to finish.
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              tooltip: 'Simpan',
              icon: const Icon(Icons.check),
              onPressed: _saving ? null : () => _save(choices: choices),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _AmountInput(controller: _amount, focusNode: _amountFocus, autofocus: !widget.isEdit, type: _type),
              const SizedBox(height: 16),
              SegmentedButton<TransactionType>(
                segments: const [
                  ButtonSegment(value: TransactionType.income, label: SegmentLabel('Income')),
                  ButtonSegment(value: TransactionType.expense, label: SegmentLabel('Expense')),
                  ButtonSegment(value: TransactionType.transfer, label: SegmentLabel('Transfer')),
                ],
                selected: {_type},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _setType(s.first),
              ),
              if (_original?.status == TransactionStatus.draft) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    StatusBadge('Draft', color: context.fin.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Konfirmasi dari halaman detail agar dihitung ke saldo.', style: context.text.bodySmall),
                    ),
                  ],
                ),
              ],
              if (!isTransfer) ...[
                const SectionHeader('Kategori'),
                _CategoryPicker(
                  type: _categoryType,
                  selectedId: _categoryId,
                  keepId: _original?.categoryId,
                  onSelected: (id) => setState(() => _categoryId = id),
                ),
              ],
              SectionHeader(isTransfer ? 'Dari account' : 'Account'),
              _AccountPicker(
                accounts: choices,
                selectedId: accountId,
                onSelected: (id) => setState(() => _accountId = id),
              ),
              if (isTransfer) ...[
                const SectionHeader('Ke account'),
                if (choices.length < 2)
                  Text('Transfer butuh minimal dua account.', style: context.text.bodySmall)
                else
                  _AccountPicker(
                    accounts: [for (final a in choices) if (a.id != accountId) a],
                    selectedId: destinationId,
                    onSelected: (id) => setState(() => _toAccountId = id),
                  ),
              ],
              const SectionHeader('Tanggal & waktu'),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 18),
                      label: Text(formatDay(_at), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(formatTime(_at)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _note,
                maxLength: 200,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Catatan (opsional)'),
              ),
              const SectionHeader('Lampiran'),
              _attachmentSection(context),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : () => _save(choices: choices),
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Simpan'),
              ),
              if (!widget.isEdit) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _saving ? null : () => _save(choices: choices, addAnother: true),
                  child: const Text('Simpan & tambah lagi'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachmentSection(BuildContext context) {
    final existing = widget.transactionId == null
        ? const <Attachment>[]
        : [
            for (final a in ref.watch(transactionAttachmentsProvider(widget.transactionId!)).value ?? const <Attachment>[])
              if (!_removed.contains(a.id)) a,
          ];
    final thumbs = [
      for (final a in existing)
        AttachmentThumb(
          key: ValueKey(a.id),
          path: a.localPath,
          mimeType: a.mimeType,
          onTap: isImageMime(a.mimeType) ? () => showAttachmentViewer(context, a.localPath) : null,
          onRemove: () => setState(() => _removed.add(a.id)),
        ),
      for (final d in _pending)
        AttachmentThumb(
          key: ValueKey(d.localPath),
          path: d.localPath,
          mimeType: d.mimeType,
          onTap: isImageMime(d.mimeType) ? () => showAttachmentViewer(context, d.localPath) : null,
          onRemove: () => _removePending(d),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AttachmentKind>(
          segments: const [
            ButtonSegment(value: AttachmentKind.receipt, label: SegmentLabel('Struk'), icon: Icon(Icons.receipt_long_outlined)),
            ButtonSegment(value: AttachmentKind.document, label: SegmentLabel('Dokumen'), icon: Icon(Icons.description_outlined)),
          ],
          selected: {_attachmentKind},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _attachmentKind = s.first),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _picking ? null : () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('Kamera'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _picking ? null : () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Galeri'),
              ),
            ),
          ],
        ),
        if (thumbs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: thumbs),
        ],
      ],
    );
  }
}

/// Large amount input with rupiah grouping; keeps its own focus node so
/// "Simpan & tambah lagi" can jump straight back to it.
class _AmountInput extends StatelessWidget {
  const _AmountInput({required this.controller, required this.focusNode, required this.autofocus, required this.type});

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final TransactionType type;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final style = context.text.displaySmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return FinCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Nominal ${type.label}', style: context.text.labelMedium!.copyWith(color: fin.muted)),
          TextFormField(
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            keyboardType: TextInputType.number,
            inputFormatters: [RupiahInputFormatter()],
            style: style,
            decoration: InputDecoration(
              prefixText: 'Rp ',
              prefixStyle: style.copyWith(color: fin.muted),
              hintText: '0',
              hintStyle: style.copyWith(color: fin.border),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            validator: (text) {
              final v = parseRupiah(text ?? '');
              if (v == null || v <= 0) return 'Masukkan nominal lebih dari 0';
              return null;
            },
          ),
        ],
      ),
    );
  }
}

/// Category chips of one type: most used in the last 30 days first, then
/// the rest alphabetically.
class _CategoryPicker extends ConsumerWidget {
  const _CategoryPicker({required this.type, required this.selectedId, required this.keepId, required this.onSelected});

  final CategoryType type;
  final String? selectedId;

  /// Category of the edited row, shown even if since deactivated.
  final String? keepId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(allCategoriesProvider).value ?? const <Category>[];
    final recent = ref.watch(recentCategoryIdsProvider(type)).value ?? const <String>[];
    final rank = {for (final (i, id) in recent.indexed) id: i};
    final cats = [
      for (final c in all)
        if (c.type == type && (c.isActive || c.id == keepId)) c,
    ]..sort((a, b) {
        final ra = rank[a.id], rb = rank[b.id];
        if (ra != null && rb != null) return ra.compareTo(rb);
        if (ra != null) return -1;
        if (rb != null) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    if (cats.isEmpty) {
      return EmptyState(
        icon: Icons.category_outlined,
        title: 'Belum ada kategori aktif',
        actionLabel: 'Kelola kategori',
        onAction: () => context.push(Routes.categories),
      );
    }
    final fin = context.fin;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in cats)
          ChoiceChip(
            selected: c.id == selectedId,
            onSelected: (_) => onSelected(c.id),
            avatar: Icon(iconFor(c.icon), size: 18, color: c.id == selectedId ? fin.onPrimary : fin.text),
            label: Text(
              c.name,
              style: context.text.labelMedium!.copyWith(color: c.id == selectedId ? fin.onPrimary : fin.text),
            ),
            tooltip: rank.containsKey(c.id) ? 'Sering dipakai 30 hari terakhir' : null,
          ),
      ],
    );
  }
}

class _AccountPicker extends StatelessWidget {
  const _AccountPicker({required this.accounts, required this.selectedId, required this.onSelected});

  final List<Account> accounts;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in accounts)
          ChoiceChip(
            selected: a.id == selectedId,
            onSelected: (_) => onSelected(a.id),
            avatar: Icon(
              a.icon != null ? iconFor(a.icon) : accountTypeIcon(a.type),
              size: 18,
              color: a.id == selectedId ? fin.onPrimary : fin.text,
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                a.isActive ? a.name : '${a.name} (arsip)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.labelMedium!.copyWith(color: a.id == selectedId ? fin.onPrimary : fin.text),
              ),
            ),
          ),
      ],
    );
  }
}
