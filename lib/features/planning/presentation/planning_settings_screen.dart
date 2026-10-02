import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/planning_repository.dart';

/// Financial planning settings (03 §4, §14, §18–19): bucket percentages,
/// Emergency Fund target, cash buffer and reserve, with live previews.
class PlanningSettingsScreen extends ConsumerWidget {
  const PlanningSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(planningSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Financial Planning')),
      body: AsyncView(value: settings, builder: (s) => _PlanningForm(settings: s)),
    );
  }
}

const _buckets = [
  PlanningBucket.essential,
  PlanningBucket.family,
  PlanningBucket.emergency,
  PlanningBucket.savings,
  PlanningBucket.development,
  PlanningBucket.personal,
];

class _PlanningForm extends ConsumerStatefulWidget {
  const _PlanningForm({required this.settings});
  final PlanningSetting settings;

  @override
  ConsumerState<_PlanningForm> createState() => _PlanningFormState();
}

class _PlanningFormState extends ConsumerState<_PlanningForm> {
  late final Map<PlanningBucket, TextEditingController> _percent = {
    for (final e in widget.settings.plan.percents.entries)
      e.key: TextEditingController(text: '${e.value}')..addListener(_changed),
  };
  late bool _flexible = widget.settings.flexibleResidualMode;
  late int _targetMonths = widget.settings.targetEmergencyMonths.clamp(1, 12);
  late int _lookback = emergencyLookbackOptions.contains(widget.settings.emergencyLookbackMonths)
      ? widget.settings.emergencyLookbackMonths
      : emergencyLookbackOptions.first;
  late final _buffer = TextEditingController(text: MoneyField.textFor(widget.settings.minimumCashBuffer));
  late final _reserve = TextEditingController(text: MoneyField.textFor(widget.settings.userReserve));
  final _simIncome = TextEditingController();
  bool _saving = false;

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    _simIncome.addListener(_changed);
  }

  @override
  void dispose() {
    for (final c in _percent.values) {
      c.dispose();
    }
    _buffer.dispose();
    _reserve.dispose();
    _simIncome.dispose();
    super.dispose();
  }

  int _pct(PlanningBucket b) => int.tryParse(_percent[b]!.text) ?? 0;

  AllocationPlan get _plan => AllocationPlan(
    essential: _pct(PlanningBucket.essential),
    family: _pct(PlanningBucket.family),
    emergency: _pct(PlanningBucket.emergency),
    savings: _pct(PlanningBucket.savings),
    development: _pct(PlanningBucket.development),
    personal: _pct(PlanningBucket.personal),
    flexibleResidual: _flexible,
  );

  Future<void> _save() async {
    final plan = _plan;
    final error = plan.validate();
    if (error != null) {
      showSnack(context, error);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(planningRepositoryProvider).save(
        plan: plan,
        targetEmergencyMonths: _targetMonths,
        emergencyLookbackMonths: _lookback,
        minimumCashBuffer: parseRupiah(_buffer.text) ?? 0,
        userReserve: parseRupiah(_reserve.text) ?? 0,
      );
      if (mounted) showSnack(context, 'Pengaturan planning disimpan.');
    } on LedgerValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    final plan = _plan;
    final error = plan.validate();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const SectionHeader('Alokasi income'),
        Text(
          'Planning bucket terpisah dari kategori transaksi. Total harus 100%, '
          'kecuali mode Flexible Residual aktif.',
          style: muted,
        ),
        const SizedBox(height: 12),
        FinCard(
          child: Column(
            children: [
              for (final b in _buckets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(b.label, style: context.text.bodyMedium)),
                      SizedBox(
                        width: 92,
                        child: TextField(
                          controller: _percent[b],
                          textAlign: TextAlign.end,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(3),
                          ],
                          decoration: const InputDecoration(suffixText: '%', isDense: true),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(child: Text('Total', style: context.text.titleSmall)),
                  Text('${plan.total}%', style: context.text.titleSmall),
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  error ??
                      (plan.total < 100
                          ? 'Sisa ${100 - plan.total}% masuk ${PlanningBucket.flexible.label}.'
                          : 'Alokasi valid.'),
                  style: error == null ? muted : muted.copyWith(color: fin.negative),
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Flexible Residual'),
          subtitle: const Text('Izinkan total < 100%; sisanya masuk Flexible/Unallocated.'),
          value: _flexible,
          onChanged: (v) => setState(() => _flexible = v),
        ),
        const SizedBox(height: 8),
        const SectionHeader('Proposal alokasi'),
        _AllocationPreview(plan: plan, planError: error, simIncome: _simIncome),
        const SizedBox(height: 16),
        const SectionHeader('Emergency Fund'),
        DropdownButtonFormField<int>(
          initialValue: _targetMonths,
          decoration: const InputDecoration(labelText: 'Target coverage'),
          items: [
            for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text('$m bulan')),
          ],
          onChanged: (v) => setState(() => _targetMonths = v ?? _targetMonths),
        ),
        const SizedBox(height: 16),
        Text('Rata-rata essential expense dari', style: muted),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            for (final m in emergencyLookbackOptions)
              ButtonSegment(value: m, label: SegmentLabel('$m bulan')),
          ],
          selected: {_lookback},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _lookback = s.first),
        ),
        const SizedBox(height: 8),
        Text('Hanya bulan yang sudah selesai yang dihitung.', style: muted),
        const SizedBox(height: 16),
        const SectionHeader('Cadangan'),
        MoneyField(controller: _buffer, label: 'Minimum cash buffer', allowZero: true, validator: (_) => null),
        const SizedBox(height: 4),
        Text('Uang tunai minimum yang tidak dihitung sebagai Available to Spend.', style: muted),
        const SizedBox(height: 12),
        MoneyField(controller: _reserve, label: 'User reserve', allowZero: true, validator: (_) => null),
        const SizedBox(height: 4),
        Text('Cadangan manual yang dimasukkan ke Reserved Money.', style: muted),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving || error != null ? null : _save,
          child: const Text('Simpan'),
        ),
        const SizedBox(height: 24),
        const SectionHeader('Available to Spend'),
        const _AvailableExplanation(),
      ],
    );
  }
}

class _AllocationPreview extends ConsumerWidget {
  const _AllocationPreview({required this.plan, required this.planError, required this.simIncome});
  final AllocationPlan plan;
  final String? planError;
  final TextEditingController simIncome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    final monthIncome = ref.watch(currentMonthIncomeProvider).value;
    final simulated = parseRupiah(simIncome.text);
    final income = simulated ?? monthIncome ?? 0;
    final allocation = planError == null && income > 0 ? allocateIncome(income, plan) : null;

    return FinCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: simIncome,
            keyboardType: TextInputType.number,
            inputFormatters: [RupiahInputFormatter()],
            decoration: const InputDecoration(
              labelText: 'Simulasi income (opsional)',
              prefixText: 'Rp ',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            simulated != null
                ? 'Simulasi dari nominal yang Anda ketik.'
                : 'Income confirmed bulan ini: ${monthIncome == null ? '…' : formatRupiah(monthIncome)}',
            style: muted,
          ),
          const SizedBox(height: 12),
          if (planError != null)
            Text('Perbaiki persentase untuk melihat proposal.', style: muted)
          else if (allocation == null)
            Text(
              'Belum ada income confirmed bulan ini. Ketik nominal untuk simulasi.',
              style: muted,
            )
          else ...[
            for (final b in [..._buckets, PlanningBucket.flexible])
              if (b != PlanningBucket.flexible || allocation[b]! > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          b == PlanningBucket.flexible ? b.label : '${b.label} · ${plan.percents[b]}%',
                          style: context.text.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      AmountText(allocation[b]!, style: context.text.bodyMedium),
                    ],
                  ),
                ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(child: Text('Total', style: context.text.titleSmall)),
                AmountText(income, style: context.text.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Ini proposal perencanaan, bukan transaksi. Anda tetap bebas mengubahnya.',
              style: muted,
            ),
          ],
        ],
      ),
    );
  }
}

class _AvailableExplanation extends ConsumerWidget {
  const _AvailableExplanation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final muted = context.text.bodySmall!.copyWith(color: fin.muted);
    return AsyncView(
      value: ref.watch(availableBreakdownProvider),
      builder: (AvailableToSpend a) => FinCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _line(context, 'Total Balance', 'Saldo semua account aktif', a.totalBalance),
            _line(context, 'Saldo tujuan aktif', 'Reserved: dana yang disisihkan untuk goals', -a.goalReserve),
            _line(context, 'Sisa alokasi Family Support', 'Reserved: alokasi bulan ini − yang sudah dikirim', -a.familyReserve),
            _line(context, 'User reserve', 'Reserved: cadangan manual', -a.userReserve),
            _line(context, 'Upcoming obligations', 'Tagihan berulang belum dibayar s.d. akhir bulan', -a.upcomingObligations),
            _line(context, 'Minimum cash buffer', 'Batas aman uang tunai', -a.minimumCashBuffer),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(child: Text('Available to Spend', style: context.text.titleSmall)),
                AmountText(a.value, style: context.text.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Available to Spend = Total Balance − Reserved − Upcoming Obligations − '
              'Minimum Cash Buffer. Dihitung dari pengaturan yang tersimpan.',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String title, String source, int amount) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.bodyMedium),
              Text(source, style: context.text.bodySmall!.copyWith(color: context.fin.muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        AmountText(amount, style: context.text.bodyMedium),
      ],
    ),
  );
}
