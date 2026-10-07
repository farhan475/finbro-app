import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
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
  final _kurs = TextEditingController();
  AccountType _type = AccountType.bank;
  Currency _currency = Currency.idr;
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
        _currency = Currency.fromCode(a.currency);
        _opening.text = MoneyField.textFor(a.openingBalance, _currency);
      }
    }
    if (_currency != Currency.idr) await _loadKurs(_currency);
    setState(() => _loading = false);
  }

  /// Prefills the kurs field from the `exchange_rates` row of [c]; blank when
  /// no rate was ever stored. Ignored when the user picked another currency
  /// meanwhile.
  Future<void> _loadKurs(Currency c) async {
    final db = ref.read(databaseProvider);
    final row = await (db.select(db.exchangeRates)..where((r) => r.code.equals(c.code))).getSingleOrNull();
    if (!mounted || _currency != c) return;
    _kurs.text = row == null ? '' : _kursText(row.rateToIdr);
  }

  static String _kursText(double rate) {
    final s = rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 2);
    return s.replaceAll('.', ',');
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    _kurs.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(accountRepositoryProvider);
    final opening = parseMoney(_opening.text, _currency) ?? 0;
    try {
      if (_currency != Currency.idr) {
        await _upsertKurs(_currency, _parseKurs(_kurs.text)!);
      }
      if (_isEdit) {
        await repo.update(
          widget.accountId!,
          name: _name.text,
          type: _type,
          openingBalance: opening,
          icon: _icon,
          currency: _currency,
        );
      } else {
        await repo.create(name: _name.text, type: _type, openingBalance: opening, icon: _icon, currency: _currency);
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

  /// The form always upserts the shown kurs for a non-IDR account
  /// (approved flow): the field doubles as the exchange-rate editor.
  Future<void> _upsertKurs(Currency c, double rate) async {
    final db = ref.read(databaseProvider);
    await db.into(db.exchangeRates).insertOnConflictUpdate(
      ExchangeRatesCompanion.insert(code: c.code, rateToIdr: rate, updatedAt: Value(DateTime.now())),
    );
  }

  static double? _parseKurs(String input) {
    final cleaned = input.trim().replaceAll(RegExp(r'[^0-9.,]'), '').replaceAll(',', '.');
    return cleaned.isEmpty ? null : double.tryParse(cleaned);
  }

  int? get _idrPreview {
    if (_currency == Currency.idr) return null;
    final rate = _parseKurs(_kurs.text);
    final opening = parseMoney(_opening.text, _currency);
    if (rate == null || rate <= 0 || opening == null) return null;
    return toIdr(opening, _currency, rate);
  }

  /// Changing the currency re-renders the opening balance via
  /// [MoneyField.switchCurrency] (kept when exact, else cleared) and shows the
  /// stored kurs of the new currency — never the previous currency's kurs,
  /// which saving would otherwise store as the new currency's rate.
  Future<void> _setCurrency(Currency c) async {
    MoneyField.switchCurrency(_opening, _currency, c);
    setState(() {
      _currency = c;
      _kurs.clear();
    });
    if (c == Currency.idr) return;
    await _loadKurs(c);
    if (mounted) setState(() {});
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
            MoneyField(controller: _opening, label: 'Saldo awal', allowZero: true, currency: _currency),
            const SizedBox(height: 6),
            Text(
              _isEdit
                  ? 'Mengubah saldo awal akan menghitung ulang saldo account.'
                  : 'Saldo saat mulai mencatat. Saldo selanjutnya dihitung dari transaksi.',
              style: context.text.bodySmall,
            ),
            const SectionHeader('Mata uang'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in Currency.values)
                  ChoiceChip(
                    selected: _currency == c,
                    onSelected: (_) => _setCurrency(c),
                    label: Text(
                      '${c.symbol} ${c.code}',
                      style: context.text.labelMedium!.copyWith(color: _currency == c ? fin.onPrimary : fin.text),
                    ),
                  ),
              ],
            ),
            if (_currency != Currency.idr) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _kurs,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Kurs (1 ${_currency.code} = ... Rp)',
                  hintText: 'mis. 16250',
                  prefixText: 'Rp ',
                ),
                onChanged: (_) => setState(() {}),
                validator: (v) {
                  final r = _parseKurs(v ?? '');
                  if (r == null || r <= 0) return 'Masukkan kurs yang valid (> 0)';
                  return null;
                },
              ),
              if (_idrPreview != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('≈ ${formatRupiah(_idrPreview!)}', style: context.text.bodySmall),
                ),
            ],
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
