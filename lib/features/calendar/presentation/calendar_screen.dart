import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../recurring/data/recurring_repository.dart';
import '../../recurring/domain/due_dates.dart';
import '../../recurring/presentation/instance_widgets.dart';
import '../data/calendar_repository.dart';
import 'calendar_widgets.dart';
import 'day_sheet.dart';

/// `/calendar` ("Kalender"): month grid with activity state per day,
/// scheduled recurring overlay, and the upcoming list.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late DateTime _month = monthStart(ref.read(clockProvider)());

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(calendarMonthProvider(_month));
    final upcoming = ref.watch(openInstancesProvider);
    final today = dateOnly(ref.watch(clockProvider)());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kalender'),
        actions: [
          IconButton(
            tooltip: 'Transaksi berulang',
            icon: const Icon(Icons.event_repeat),
            onPressed: () => context.push(Routes.recurring),
          ),
          IconButton(
            tooltip: 'Pengaturan notifikasi',
            icon: const Icon(Icons.notifications_none),
            onPressed: () => context.push(Routes.notificationSettings),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          FinCard(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    MonthSwitcher(
                      month: _month,
                      label: formatMonth(_month),
                      onChanged: (m) => setState(() => _month = monthStart(m)),
                    ),
                    const Spacer(),
                    if (_month != monthStart(today))
                      TextButton(
                        onPressed: () => setState(() => _month = monthStart(today)),
                        child: const Text('Hari ini'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (final w in weekdayShort)
                      Expanded(
                        child: Center(
                          child: Text(w, style: context.text.labelSmall?.copyWith(color: context.fin.muted)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                AsyncView(
                  value: month,
                  builder: (m) => _MonthGrid(month: m, today: today),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const CalendarLegend(),
          const SizedBox(height: 16),
          SectionHeader('Upcoming', actionLabel: 'Semua', onAction: () => context.push(Routes.recurring)),
          AsyncView(
            value: upcoming,
            builder: (list) {
              if (list.isEmpty) {
                return EmptyState(
                  icon: Icons.event_available_outlined,
                  title: 'Tidak ada jadwal',
                  message: 'Tambahkan salary, tagihan, atau langganan sebagai transaksi berulang.',
                  actionLabel: 'Tambah jadwal',
                  onAction: () => context.push('${Routes.recurring}/new'),
                );
              }
              final shown = list.take(8).toList();
              return FinCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      InstanceTile(shown[i]),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.today});
  final CalendarMonth month;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final first = month.month;
    final leading = first.weekday - 1;
    final daysInMonth = monthEnd(first).day;
    final cells = ((leading + daysInMonth + 6) ~/ 7) * 7;
    return Column(
      children: [
        for (var row = 0; row < cells ~/ 7; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final n = row * 7 + col - leading + 1;
                      if (n < 1 || n > daysInMonth) return const SizedBox(height: 52);
                      final date = DateTime(first.year, first.month, n);
                      return _DayCell(day: month.day(date), today: today);
                    },
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.today});
  final CalendarDay day;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final date = day.date;
    final isToday = date == today;
    final future = date.isAfter(today);
    final showActivity = !future || day.status != ActivityStatus.unknown;
    final income = day.hasScheduledIncome;
    final expense = day.hasScheduledExpense;
    final semantics = [
      formatDay(date),
      if (showActivity) activityLabel(day.status, future: future),
      if (income) 'income terjadwal',
      if (expense) 'expense terjadwal',
    ].join(', ');

    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => showCalendarDaySheet(context, date),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 52,
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: isToday ? fin.surface2 : null,
            border: isToday ? Border.all(color: fin.text) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${date.day}',
                style: context.text.bodyMedium?.copyWith(
                  fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                  color: future ? fin.muted : fin.text,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 11,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (showActivity) ActivityMarker(day.status),
                    if (income) ...[const SizedBox(width: 2), const ScheduledMarker(income: true)],
                    if (expense) ...[const SizedBox(width: 2), const ScheduledMarker(income: false)],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
