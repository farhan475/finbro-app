import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../backup/domain/integrity_check.dart';
import '../../security/domain/app_lock_service.dart';
import '../domain/startup_checks.dart';

/// Paths owned by the settings slice that are not cross-feature routes.
abstract final class SettingsPaths {
  static const appearance = '/settings/appearance';
  static const about = '/settings/about';
  static const help = '/settings/help';
}

const themeModeLabels = {'system': 'Ikuti sistem', 'light': 'Terang', 'dark': 'Gelap'};

/// Titled card holding navigation tiles.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionHeader(title),
      Card(child: Column(children: children)),
      const SizedBox(height: 8),
    ],
  );
}

class NavTile extends StatelessWidget {
  const NavTile({super.key, required this.icon, required this.title, required this.route, this.subtitle});
  final IconData icon;
  final String title;
  final String route;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: context.fin.text),
    title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: Icon(Icons.chevron_right, color: context.fin.muted),
    onTap: () => context.push(route),
  );
}

/// "Pengaturan" group shared by the More tab and `/settings`.
class SettingsGroup extends ConsumerWidget {
  const SettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).value ?? const {};
    final lock = ref.watch(appLockConfigProvider);
    final lastBackup = DateTime.tryParse(settings[SettingKeys.lastBackupAt] ?? '');
    return SettingsSection(
      title: 'Pengaturan',
      children: [
        const NavTile(icon: Icons.donut_large_outlined, title: 'Planning & alokasi', route: Routes.planning),
        const NavTile(icon: Icons.notifications_none, title: 'Notifikasi', route: Routes.notificationSettings),
        NavTile(
          icon: Icons.contrast,
          title: 'Tampilan',
          subtitle: themeModeLabels[settings[SettingKeys.themeMode]] ?? themeModeLabels['system'],
          route: SettingsPaths.appearance,
        ),
        NavTile(
          icon: Icons.lock_outline,
          title: 'Keamanan',
          subtitle: lock.pinEnabled ? 'App lock aktif' : 'App lock nonaktif',
          route: Routes.security,
        ),
        NavTile(
          icon: Icons.backup_outlined,
          title: 'Backup & Restore',
          subtitle: lastBackup == null ? 'Belum pernah backup' : 'Terakhir ${formatDay(lastBackup)}',
          route: Routes.backup,
        ),
        const NavTile(icon: Icons.currency_exchange, title: 'Kurs Mata Uang', route: Routes.rates),
        const NavTile(icon: Icons.article_outlined, title: 'Log aplikasi', route: Routes.log),
        const NavTile(icon: Icons.help_outline, title: 'Bantuan', route: SettingsPaths.help),
        const NavTile(icon: Icons.info_outline, title: 'Tentang', route: SettingsPaths.about),
      ],
    );
  }
}

/// Integrity problems (after abnormal termination/restore) and the gentle
/// backup reminder. Shown on Home, More and Settings; each visible card
/// carries its own bottom gap so callers need no conditional spacing.
class ReliabilityBanners extends ConsumerWidget {
  const ReliabilityBanners({super.key, this.showLogAction = true});
  final bool showLogAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final report = ref.watch(integrityReportProvider);
    final remind = ref.watch(backupReminderProvider);
    final lastBackup = DateTime.tryParse(ref.watch(appSettingsProvider).value?[SettingKeys.lastBackupAt] ?? '');
    final days = lastBackup == null ? null : ref.watch(clockProvider)().difference(lastBackup).inDays;
    return Column(
      children: [
        if (report != null && !report.ok)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FinCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: fin.warning),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Integrity check menemukan masalah', style: context.text.titleSmall)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Dicek ${formatDay(report.checkedAt)} ${formatTime(report.checkedAt)}',
                    style: context.text.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  for (final line in report.summary.take(4)) Text('• $line', style: context.text.bodySmall),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => ref.read(startupChecksProvider).dismissReport(),
                        style: TextButton.styleFrom(foregroundColor: fin.muted),
                        child: const Text('Tutup'),
                      ),
                      if (showLogAction)
                        TextButton(
                          onPressed: () => context.push(Routes.log),
                          style: TextButton.styleFrom(foregroundColor: fin.text),
                          child: const Text('Lihat detail'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (remind)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FinCard(
              onTap: () => context.push(Routes.backup),
              child: Row(
                children: [
                  Icon(Icons.backup_outlined, color: fin.text),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          days == null ? 'Belum ada backup' : 'Backup terakhir $days hari lalu',
                          style: context.text.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Data hanya tersimpan di perangkat ini. Buat backup dan simpan salinannya di tempat lain.',
                          style: context.text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: fin.muted),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
