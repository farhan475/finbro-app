import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../calendar/domain/daily_check_service.dart';

/// `Routes.notificationSettings`: daily check, monthly review and budget
/// alert toggles. Every change reschedules the daily/monthly reminders.
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
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
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
