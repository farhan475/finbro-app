import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../categories/presentation/icon_choice.dart';
import '../data/account_repository.dart';

/// Icon keys offered for accounts (subset of [iconRegistry]).
const _accountIconKeys = ['bank', 'ewallet', 'cash', 'savings', 'card', 'phone', 'home', 'other'];

/// Create (`/accounts/new`) or edit (`/accounts/:id/edit`) an account
/// (FR-ACC-001): name, type, opening balance, optional icon.
class AccountFormScreen extends ConsumerStatefulWidget {
  const AccountFormScreen({super.key, this.accountId});
  final String? accountId;

  @override
  ConsumerState<AccountFormScreen> createState() => _AccountFormScreenState();
}

class _AccountFormScreenState extends ConsumerState<AccountFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _opening = TextEditingController(text: '0');
  AccountType _type = AccountType.bank;
  String? _icon;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;

  bool get _isEdit => widget.accountId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.accountId;
    if (id != null) {
      final db = ref.read(databaseProvider);
      final a = await (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingleOrNull();
      if (!mounted) return;
      if (a == null) {
        _missing = true;
      } else {
        _name.text = a.name;
        _type = a.type;
        _icon = a.icon;
        _opening.text = MoneyField.textFor(a.openingBalance);
      }
    }
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(accountRepositoryProvider);
    final opening = parseRupiah(_opening.text) ?? 0;
    try {
      if (_isEdit) {
        await repo.update(widget.accountId!, name: _name.text, type: _type, openingBalance: opening, icon: _icon);
      } else {
        await repo.create(name: _name.text, type: _type, openingBalance: opening, icon: _icon);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.accounts);
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_isEdit ? 'Account diperbarui.' : 'Account ditambahkan.')));
    } on AccountException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e, s) {
      AppLogger.error('Gagal menyimpan account', e, s);
      if (mounted) showSnack(context, 'Account gagal disimpan. Coba lagi.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? 'Edit account' : 'Tambah account';
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: EmptyState(icon: Icons.search_off, title: 'Account tidak ditemukan')),
      );
    }
    final fin = context.fin;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TextFormField(
              controller: _name,
              autofocus: !_isEdit,
              maxLength: AccountRepository.maxNameLength,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nama account', hintText: 'mis. BCA, GoPay, Cash'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Nama account wajib diisi' : null,
            ),
            const SectionHeader('Jenis'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in AccountType.values)
                  ChoiceChip(
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                    avatar: Icon(accountTypeIcon(t), size: 18, color: _type == t ? fin.onPrimary : fin.text),
                    label: Text(t.label, style: context.text.labelMedium!.copyWith(color: _type == t ? fin.onPrimary : fin.text)),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            MoneyField(controller: _opening, label: 'Saldo awal', allowZero: true),
            const SizedBox(height: 6),
            Text(
              _isEdit
                  ? 'Mengubah saldo awal akan menghitung ulang saldo account.'
                  : 'Saldo saat mulai mencatat. Saldo selanjutnya dihitung dari transaksi.',
              style: context.text.bodySmall,
            ),
            const SectionHeader('Ikon (opsional)'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                IconChoice(
                  icon: accountTypeIcon(_type),
                  label: 'Sesuai jenis',
                  selected: _icon == null,
                  onTap: () => setState(() => _icon = null),
                ),
                for (final key in _accountIconKeys)
                  IconChoice(
                    icon: iconFor(key),
                    label: key,
                    selected: _icon == key,
                    onTap: () => setState(() => _icon = key),
                  ),
              ],
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }
}
