import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
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
  final _updated = <String, DateTime?>{};
  bool _loading = true;
  bool _saving = false;

  List<Currency> get _currencies => Currency.values.where((c) => c != Currency.idr).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final codes = _currencies.map((c) => c.code).toList();
    final rows = await (db.select(db.exchangeRates)..where((r) => r.code.isIn(codes))).get();
    final byCode = {for (final r in rows) r.code: r};
    for (final c in _currencies) {
      final row = byCode[c.code];
      _updated[c.code] = row?.updatedAt;
      _controllers.putIfAbsent(
        c.code,
        () => TextEditingController(text: row == null ? '' : _rateText(row.rateToIdr)),
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  static String _rateText(double rate) {
    final s = rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 2);
    return s.replaceAll('.', ',');
  }

  static double? _parseRate(String input) {
    final cleaned = input.trim().replaceAll(RegExp(r'[^0-9.,]'), '').replaceAll(',', '.');
    return cleaned.isEmpty ? null : double.tryParse(cleaned);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    try {
      final now = DateTime.now();
      await db.transaction(() async {
        for (final c in _currencies) {
          final rate = _parseRate(_controllers[c.code]!.text)!;
          await db.into(db.exchangeRates).insertOnConflictUpdate(
            ExchangeRatesCompanion.insert(code: c.code, rateToIdr: rate, updatedAt: Value(now)),
          );
        }
      });
      if (!mounted) return;
      showSnack(context, 'Kurs disimpan.');
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
    return Scaffold(
      appBar: AppBar(title: const Text('Kurs Mata Uang')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Text('Nilai tukar manual: rupiah per 1 unit mata uang.', style: context.text.bodySmall),
                  const SizedBox(height: 8),
                  FinCard(
                    child: Column(
                      children: [
                        for (final (i, c) in _currencies.indexed) ...[
                          if (i > 0) const Divider(),
                          TextFormField(
                            controller: _controllers[c.code],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: '${c.displayName} — 1 ${c.code} = ... Rp',
                              prefixText: 'Rp ',
                              hintText: 'mis. 16250',
                            ),
                            validator: (v) {
                              final r = _parseRate(v ?? '');
                              if (r == null || r <= 0) return 'Masukkan kurs yang valid (> 0)';
                              return null;
                            },
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _updated[c.code] == null
                                  ? 'Belum pernah diatur'
                                  : 'Diperbarui ${formatDay(_updated[c.code]!)}',
                              style: context.text.bodySmall,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
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
