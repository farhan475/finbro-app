import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../shared/widgets/fin_widgets.dart';
import 'settings_widgets.dart';

/// `/settings`: the settings group on its own page.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pengaturan')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: const [ReliabilityBanners(), SettingsGroup()],
    ),
  );
}

/// `/settings/appearance`: light / dark / system theme.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appSettingsProvider.select((s) => s.value?[SettingKeys.themeMode])) ?? 'system';
    final icons = {'system': Icons.brightness_auto_outlined, 'light': Icons.light_mode_outlined, 'dark': Icons.dark_mode_outlined};
    return Scaffold(
      appBar: AppBar(title: const Text('Tampilan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionHeader('Tema'),
          Card(
            child: Column(
              children: [
                for (final e in themeModeLabels.entries)
                  ListTile(
                    leading: Icon(icons[e.key]),
                    title: Text(e.value),
                    selected: current == e.key,
                    trailing: current == e.key ? const Icon(Icons.check) : null,
                    onTap: () => ref.read(appSettingsRepositoryProvider).set(SettingKeys.themeMode, e.key),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'FinBro memakai tampilan monokrom dengan aksen hijau untuk seleksi, progress dan grafik; '
            'warna status dipakai untuk data (positif, negatif, peringatan).',
            style: context.text.bodySmall!.copyWith(color: context.fin.muted),
          ),
        ],
      ),
    );
  }
}
