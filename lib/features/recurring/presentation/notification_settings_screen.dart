import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../calendar/domain/daily_check_service.dart';
import '../domain/recurring_engine.dart';

/// `Routes.notificationSettings`: daily check, monthly review, budget alert
/// and exact-delivery toggles. Every change reschedules the affected reminders.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  Future<void> _setBool(WidgetRef ref, String key, bool value) async {
    await ref.read(appSettingsRepositoryProvider).setBool(key, value);
    await _reschedule(ref);
  }

  Future<void> _reschedule(WidgetRef ref) async {
    try {
      await ref.read(dailyCheckServiceProvider).reschedule(ref.read(clockProvider)());
    } catch (e, s) {
      AppLogger.error('Penjadwalan ulang pengingat gagal', e, s);
    }
  }

  Future<void> _pickTime(BuildContext context, WidgetRef ref, TimeOfDay current) async {
    final t = await showTimePicker(context: context, initialTime: current, helpText: 'Jam daily check');
    if (t == null) return;
    await ref.read(appSettingsRepositoryProvider).set(SettingKeys.dailyCheckTime, formatTimeOfDay(t));
    await _reschedule(ref);
  }

  Future<void> _requestPermission(BuildContext context, WidgetRef ref) async {
    final granted = await NotificationService.instance.requestPermission();
    if (granted) await _reschedule(ref);
    if (context.mounted) {
      showSnack(
        context,
        granted ? 'Notifikasi diizinkan' : 'Izin tidak diberikan atau tidak didukung di perangkat ini',
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifikasi')),
      body: AsyncView(
        value: settings,
        builder: (s) {
          bool flag(String key) => (s[key] ?? 'true') == 'true';
          final daily = flag(SettingKeys.dailyCheckEnabled);
          final time = parseTimeOfDay(s[SettingKeys.dailyCheckTime]);
          final fin = context.fin;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                'Semua pengingat adalah notifikasi lokal dan tetap berjalan tanpa internet.',
                style: context.text.bodySmall,
              ),
              const SizedBox(height: 12),
              FinCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Daily check'),
                      subtitle: const Text('Tanya setiap malam bila belum ada transaksi atau status hari ini'),
                      value: daily,
                      onChanged: (v) => _setBool(ref, SettingKeys.dailyCheckEnabled, v),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      enabled: daily,
                      title: const Text('Jam daily check'),
                      trailing: Text(formatTimeOfDay(time), style: context.text.titleSmall),
                      onTap: daily ? () => _pickTime(context, ref, time) : null,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Monthly review'),
                      subtitle: const Text('Pengingat review di hari terakhir setiap bulan, 19:00'),
                      value: flag(SettingKeys.monthlyReviewEnabled),
                      onChanged: (v) => _setBool(ref, SettingKeys.monthlyReviewEnabled, v),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Budget alert'),
                      subtitle: const Text('Peringatan saat pemakaian budget melewati ambang'),
                      value: flag(SettingKeys.budgetAlertsEnabled),
                      onChanged: (v) => _setBool(ref, SettingKeys.budgetAlertsEnabled, v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Pengingat transaksi berulang (H, H-1, H-3) diatur di masing-masing jadwal.',
                style: context.text.bodySmall?.copyWith(color: fin.muted),
              ),
              const SizedBox(height: 12),
              _ExactRemindersCard(enabled: flag(SettingKeys.exactReminders)),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => _requestPermission(context, ref),
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Izinkan notifikasi'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Whether Android currently allows exact alarms. Re-read on every resume:
/// the user grants/revokes it in the system "Alarm & pengingat" screen.
final exactAlarmsAllowedProvider = FutureProvider.autoDispose<bool>(
  (ref) => NotificationService.instance.canScheduleExact(),
);

/// "Pengingat tepat waktu": setting toggle, current Android permission and
/// a shortcut to the system permission screen.
class _ExactRemindersCard extends ConsumerStatefulWidget {
  const _ExactRemindersCard({required this.enabled});
  final bool enabled;

  @override
  ConsumerState<_ExactRemindersCard> createState() => _ExactRemindersCardState();
}

class _ExactRemindersCardState extends ConsumerState<_ExactRemindersCard> {
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(exactAlarmsAllowedProvider));

  @override
  void initState() {
    super.initState();
    _lifecycle; // Starts listening.
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Recurring, daily check and monthly review reminders pick the new mode
  /// up through their payload diffs.
  Future<void> _rescheduleAll() async {
    final now = ref.read(clockProvider)();
    try {
      await ref.read(recurringEngineProvider).sync(now);
      await ref.read(dailyCheckServiceProvider).reschedule(now);
    } catch (e, s) {
      AppLogger.error('Penjadwalan ulang pengingat gagal', e, s);
    }
  }

  Future<void> _setEnabled(bool value) async {
    await ref.read(appSettingsRepositoryProvider).setBool(SettingKeys.exactReminders, value);
    await _rescheduleAll();
  }

  Future<void> _requestPermission() async {
    final granted = await NotificationService.instance.requestExactPermission();
    if (!mounted) return;
    ref.invalidate(exactAlarmsAllowedProvider);
    if (granted) await _rescheduleAll();
    if (mounted) {
      showSnack(context, granted ? 'Pengingat tepat waktu diizinkan' : 'Izin alarm tepat waktu belum diberikan');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final allowed = ref.watch(exactAlarmsAllowedProvider).value;
    return FinCard(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pengingat tepat waktu'),
            subtitle: const Text('Gaji, transaksi berulang, daily check, dan monthly review muncul tepat di jamnya'),
            value: widget.enabled,
            onChanged: _setEnabled,
          ),
          if (widget.enabled) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                allowed == true ? Icons.check_circle_outline : Icons.alarm_off_outlined,
                color: allowed == true ? fin.positive : fin.warning,
              ),
              title: Text(switch (allowed) {
                null => 'Memeriksa izin Android…',
                true => 'Diizinkan Android',
                false => 'Belum diizinkan Android',
              }),
              subtitle: allowed == false
                  ? const Text('Tanpa izin "Alarm & pengingat", pengingat bisa terlambat beberapa menit.')
                  : null,
            ),
            if (allowed == false) ...[
              OutlinedButton.icon(
                onPressed: _requestPermission,
                icon: const Icon(Icons.alarm_on_outlined, size: 18),
                label: const Text('Izinkan alarm tepat waktu'),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              'Alarm tepat waktu sedikit lebih boros baterai. Beberapa merek HP (Xiaomi, Oppo, Vivo, '
              'Realme) tetap bisa menahan notifikasi bila FinBro dibatasi penghemat baterai; lihat Bantuan.',
              style: context.text.bodySmall?.copyWith(color: fin.muted),
            ),
          ] else
            Text(
              'Mati: pengingat memakai alarm hemat baterai dan bisa terlambat beberapa menit.',
              style: context.text.bodySmall?.copyWith(color: fin.muted),
            ),
        ],
      ),
    );
  }
}
