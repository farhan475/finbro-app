import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../shared/widgets/fin_widgets.dart';

/// Keep in sync with `version:` in pubspec.yaml.
const appVersion = '1.0.0 (1)';
const appTagline = 'Better plan, brighter future';
const offlineStatement =
    'Semua data tersimpan hanya di perangkat ini. FinBro tidak memerlukan akun, server, '
    'atau koneksi internet untuk fungsi inti, dan tidak mengirim data ke mana pun.';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Scaffold(
      appBar: AppBar(title: const Text('Tentang')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          const Center(child: FinBroWordmark()),
          const SizedBox(height: 16),
          Text(
            appTagline.toUpperCase(),
            textAlign: TextAlign.center,
            style: context.text.labelMedium!.copyWith(letterSpacing: 3, color: fin.muted),
          ),
          const SizedBox(height: 32),
          FinCard(
            child: Column(
              children: [
                _row(context, 'Versi', appVersion),
                _row(context, 'Skema database', '${AppDatabase.currentSchemaVersion}'),
              ],
            ),
          ),
          FinCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_off_outlined, color: fin.text),
                const SizedBox(width: 12),
                Expanded(child: Text(offlineStatement, style: context.text.bodyMedium)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'FinBro',
              applicationVersion: appVersion,
              applicationLegalese: appTagline,
            ),
            style: TextButton.styleFrom(foregroundColor: fin.text),
            child: const Text('Lisensi open source'),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label, style: context.text.bodyMedium!.copyWith(color: context.fin.muted))),
        Text(value, style: context.text.bodyMedium),
      ],
    ),
  );
}
