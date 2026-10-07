import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';

/// `/settings/rates`: manual kurs per currency — rupiah per 1 unit, stored
/// in the `exchange_rates` table and used for IDR equivalents everywhere.
class ExchangeRatesScreen extends ConsumerStatefulWidget {
  const ExchangeRatesScreen({super.key});

  @override
  ConsumerState<ExchangeRatesScreen> createState() => _ExchangeRatesScreenState();
}

class _ExchangeRatesScreenState extends ConsumerState<ExchangeRatesScreen> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _stored = <String, ExchangeRate>{};
  bool _loading = true;
  bool _saving = false;

  static final _currencies = Currency.values.where((c) => c != Currency.idr).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final codes = _currencies.map((c) => c.code).toList();
    final rows = await (db.select(db.exchangeRates)..where((r) => r.code.isIn(codes))).get();
    _stored
      ..clear()
      ..addAll({for (final r in rows) r.code: r});
    for (final c in _currencies) {
      final row = _stored[c.code];
      final text = row == null ? '' : formatRateInput(row.rateToIdr);
      (_controllers[c.code] ??= TextEditingController()).text = text;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Writes only the rates the user changed, so "Diperbarui" keeps meaning
  /// when each kurs was last edited.
  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (_saving || !_formKey.currentState!.validate()) return;
    final changed = <Currency, double>{
      for (final c in _currencies)
        if (parseRate(_controllers[c.code]!.text)! != _stored[c.code]?.rateToIdr)
          c: parseRate(_controllers[c.code]!.text)!,
    };
    if (changed.isEmpty) {
      showSnack(context, 'Tidak ada kurs yang berubah.');
      return;
    }
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    try {
      final now = DateTime.now();
      await db.transaction(() async {
        for (final MapEntry(key: c, value: rate) in changed.entries) {
          await db.into(db.exchangeRates).insertOnConflictUpdate(
            ExchangeRatesCompanion.insert(code: c.code, rateToIdr: rate, updatedAt: Value(now)),
          );
        }
      });
      if (!mounted) return;
      showSnack(context, changed.length == 1 ? 'Kurs ${changed.keys.single.code} disimpan.' : '${changed.length} kurs disimpan.');
      await _load();
    } catch (e, s) {
      AppLogger.error('Gagal menyimpan kurs', e, s);
      if (mounted) showSnack(context, 'Kurs gagal disimpan. Coba lagi.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Scaffold(
      appBar: AppBar(title: const Text('Kurs Mata Uang')),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Simpan kurs'),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  FinCard(
                    color: fin.surface2,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 20, color: fin.muted),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Isi berapa rupiah untuk 1 unit tiap mata uang. Kurs dipakai untuk '
                            'menghitung total saldo, budget dan laporan dalam rupiah. FinBro '
                            'bekerja offline, jadi kurs tidak diperbarui otomatis.',
                            style: context.text.bodySmall!.copyWith(color: fin.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Column(
                      children: [
                        for (final (i, c) in _currencies.indexed) ...[
                          if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: fin.border),
                          _RateRow(
                            currency: c,
                            controller: _controllers[c.code]!,
                            updatedAt: _stored[c.code]?.updatedAt,
                            enabled: !_saving,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// One currency: symbol badge, code + name + last edit, and the rupiah field.
class _RateRow extends StatelessWidget {
  const _RateRow({required this.currency, required this.controller, required this.updatedAt, required this.enabled});

  final Currency currency;
  final TextEditingController controller;
  final DateTime? updatedAt;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    // Large font scales: the field moves below the label so the rate is not cut ("Rp 16.2").
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 13;
    final label = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fin.surface2, shape: BoxShape.circle),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(currency.symbol, style: context.text.titleSmall),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(currency.code, style: context.text.titleSmall),
              Text(currency.displayName, style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                updatedAt == null ? 'Belum pernah diatur' : 'Diubah ${formatDay(updatedAt!)}',
                style: context.text.labelSmall!.copyWith(color: fin.muted),
              ),
            ],
          ),
        ),
      ],
    );
    final field = Semantics(
      label: 'Kurs 1 ${currency.code} dalam rupiah',
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        textAlign: TextAlign.end,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.next,
        style: context.text.titleSmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        decoration: const InputDecoration(isDense: true, prefixText: 'Rp ', hintText: '0', errorMaxLines: 2),
        validator: (v) {
          final r = parseRate(v ?? '');
          return r == null || r <= 0 ? 'Isi kurs > 0' : null;
        },
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [label, const SizedBox(height: 8), field],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: label),
                const SizedBox(width: 12),
                SizedBox(width: 128, child: field),
              ],
            ),
    );
  }
}
