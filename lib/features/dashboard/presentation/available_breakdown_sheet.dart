import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/finance/finance_service.dart';
import '../../../shared/widgets/fin_widgets.dart';

/// Explains how Available to Spend is derived (03 §4).
Future<void> showAvailableBreakdownSheet(BuildContext context, AvailableToSpend a) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Available to Spend', style: context.text.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Uang yang bisa dipakai setelah menyisihkan cadangan, kewajiban terjadwal, dan cash buffer.',
              style: context.text.bodySmall,
            ),
            const SizedBox(height: 16),
            _Line('Total Balance', 'Saldo semua account aktif', a.totalBalance),
            _Line('Goal reserve', 'Saldo goal aktif', -a.goalReserve),
            _Line('Family reserve', 'Sisa alokasi Family Support bulan ini', -a.familyReserve),
            _Line('User reserve', 'Cadangan manual di Planning', -a.userReserve),
            _Line(
              'Upcoming obligations',
              'Recurring expense terbuka s.d. akhir bulan',
              -a.upcomingObligations,
            ),
            _Line('Minimum cash buffer', 'Batas saldo minimum', -a.minimumCashBuffer),
            const Divider(height: 24),
            _Line('Available to Spend', null, a.value, emphasize: true),
            const SizedBox(height: 12),
            Text(
              'Total Balance − Reserved − Upcoming Obligations − Minimum Cash Buffer',
              style: context.text.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.hint, this.amount, {this.emphasize = false});
  final String label;
  final String? hint;
  final int amount;
  final bool emphasize;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: emphasize ? context.text.titleMedium : context.text.bodyMedium),
              if (hint != null) Text(hint!, style: context.text.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          fit: FlexFit.tight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: AmountText(amount, style: emphasize ? context.text.titleMedium : context.text.bodyMedium),
          ),
        ),
      ],
    ),
  );
}
