import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/fin_widgets.dart';

/// `/settings/help`: troubleshooting for reminders and data safety. Reminders use
/// inexact local alarms, so delivery can drift when the OS saves battery.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bantuan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          SectionHeader('Notifikasi tidak muncul'),
          _HelpItem(
            icon: Icons.notifications_active_outlined,
            title: 'Izinkan notifikasi',
            body: 'Buka Pengaturan HP → Aplikasi → FinBro → Notifikasi, lalu aktifkan semuanya.',
          ),
          _HelpItem(
            icon: Icons.battery_saver_outlined,
            title: 'Matikan pembatasan baterai',
            body: 'Di Pengaturan → Baterai → FinBro, pilih "Tanpa pembatasan". Mode hemat baterai '
                'dapat menunda pengingat beberapa menit.',
          ),
          _HelpItem(
            icon: Icons.power_settings_new,
            title: 'Xiaomi / Oppo / Vivo / Realme',
            body: 'Aktifkan "Mulai otomatis" (Autostart) untuk FinBro, dan kunci aplikasi di layar '
                'Recent agar tidak dimatikan sistem.',
          ),
          _HelpItem(
            icon: Icons.schedule,
            title: 'Waktu pengingat',
            body: 'Pengingat memakai alarm lokal yang tidak presisi: bisa terlambat beberapa menit '
                'saat HP dalam mode hemat daya. Pengingat dijadwalkan ulang setiap kali FinBro dibuka.',
          ),
          SizedBox(height: 8),
          SectionHeader('Keamanan data'),
          _HelpItem(
            icon: Icons.backup_outlined,
            title: 'Backup manual',
            body: 'Data hanya ada di HP ini. Menghapus aplikasi atau mengganti HP menghapus data. '
                'Buat backup di Pengaturan → Backup & Restore dan simpan di luar HP.',
          ),
          _HelpItem(
            icon: Icons.document_scanner_outlined,
            title: 'Hasil scan',
            body: 'Hasil scan struk selalu berupa draf. Periksa nominal dan tanggal sebelum menyimpan.',
          ),
        ],
      ),
    );
  }
}

class _HelpItem extends StatelessWidget {
  const _HelpItem({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return FinCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: context.fin.text),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                const SizedBox(height: 4),
                Text(body, style: context.text.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
