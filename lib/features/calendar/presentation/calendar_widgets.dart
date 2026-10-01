import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';

/// Activity state marker; the shape (not only color) carries the meaning:
/// ACTIVE = filled dot, NO_ACTIVITY = dash, UNKNOWN = hollow ring.
class ActivityMarker extends StatelessWidget {
  const ActivityMarker(this.status, {super.key});
  final ActivityStatus status;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return switch (status) {
      ActivityStatus.active => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: fin.text, shape: BoxShape.circle),
      ),
      ActivityStatus.noActivity => Container(
        width: 10,
        height: 2,
        decoration: BoxDecoration(color: fin.muted, borderRadius: BorderRadius.circular(1)),
      ),
      ActivityStatus.unknown => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: fin.muted.withValues(alpha: 0.6)),
        ),
      ),
    };
  }
}

/// ↑ scheduled income / ↓ scheduled expense overlay marker.
class ScheduledMarker extends StatelessWidget {
  const ScheduledMarker({super.key, required this.income, this.size = 11});
  final bool income;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Icon(
      income ? Icons.arrow_upward : Icons.arrow_downward,
      size: size,
      color: income ? fin.positive : fin.negative,
    );
  }
}

String activityLabel(ActivityStatus s, {required bool future}) => switch (s) {
  ActivityStatus.active => 'Ada transaksi',
  ActivityStatus.noActivity => 'Tidak ada aktivitas',
  ActivityStatus.unknown => future ? 'Belum ada data' : 'Belum dicek',
};

class CalendarLegend extends StatelessWidget {
  const CalendarLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(Widget marker, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 12, child: Center(child: marker)),
        const SizedBox(width: 6),
        Text(label, style: context.text.bodySmall),
      ],
    );
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        item(const ActivityMarker(ActivityStatus.active), 'Ada transaksi'),
        item(const ActivityMarker(ActivityStatus.noActivity), 'Tidak ada aktivitas'),
        item(const ActivityMarker(ActivityStatus.unknown), 'Belum dicek'),
        item(const ScheduledMarker(income: true), 'Income terjadwal'),
        item(const ScheduledMarker(income: false), 'Expense terjadwal'),
      ],
    );
  }
}
