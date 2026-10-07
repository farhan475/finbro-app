import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/fin_widgets.dart';

/// `/settings/help`: troubleshooting for reminders and data safety. Reminders use
/// exact alarms when allowed, else inexact ones that drift when the OS saves battery.
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
            body: 'Aktifkan "Pengingat tepat waktu" di Pengaturan → Notifikasi dan izinkan "Alarm & '
                'pengingat" agar pengingat muncul tepat di jamnya. Tanpa izin itu, pengingat bisa '
                'terlambat beberapa menit saat HP dalam mode hemat daya. Pengingat dijadwalkan ulang '
                'setiap kali FinBro dibuka dan di latar belakang sekitar tiap 6 jam.',
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
            icon: Icons.enhanced_encryption_outlined,
            title: 'Backup terenkripsi otomatis',
            body: 'Di Backup & Restore → Backup terenkripsi ke folder, pilih folder (mis. folder yang disinkronkan) '
                'dan atur passphrase. FinBro membuat backup harian/mingguan saat aplikasi dibuka atau di latar '
                'belakang (sekitar tiap 6 jam; Android bisa menundanya saat hemat baterai). '
                'Passphrase tidak bisa dipulihkan; tanpa passphrase backup tidak bisa direstore.',
          ),
          _HelpItem(
            icon: Icons.document_scanner_outlined,
            title: 'Hasil scan',
            body: 'Hasil scan struk selalu berupa draf. Periksa nominal dan tanggal sebelum menyimpan.',
          ),
          SizedBox(height: 8),
          SectionHeader('Pertanyaan umum'),
          _HelpItem(
            icon: Icons.swap_horiz,
            title: 'Apakah transfer dihitung sebagai pemasukan/pengeluaran?',
            body: 'Tidak. Transfer hanya memindahkan uang antar account, jadi total saldo tidak berubah '
                'dan tidak masuk ke arus kas.',
          ),
          _HelpItem(
            icon: Icons.widgets_outlined,
            title: 'Widget layar utama',
            body: 'Tambahkan dari Lainnya → Pengaturan → Widget layar utama (atau tahan layar utama → Widget → '
                'FinBro). Widget menampilkan Total Balance dan grafiknya bulan ini; perbesar ke atas untuk '
                'Income/Expense, lalu Available to Spend, budget dan jadwal terdekat. Ketuk bagiannya untuk '
                'membuka layar terkait. Diperbarui saat data berubah dan sekitar tiap 30 menit. Selama PIN aktif '
                'atau saldo disembunyikan, angkanya disamarkan. Di Xiaomi/Oppo/Vivo, aktifkan Autostart agar '
                'widget tetap diperbarui saat FinBro tidak dibuka.',
          ),
          _HelpItem(
            icon: Icons.savings_outlined,
            title: 'Apa itu Available to Spend?',
            body: 'Sisa uang yang aman dipakai: total saldo dikurangi dana yang dicadangkan, kewajiban '
                'terjadwal, dan minimum cash buffer. Rinciannya bisa dibuka dari kartu di Home.',
          ),
          _HelpItem(
            icon: Icons.fact_check_outlined,
            title: 'Saldo tidak sama dengan saldo asli',
            body: 'Buka detail account, masukkan saldo sebenarnya, dan lihat selisihnya terhadap saldo '
                'hitungan FinBro.',
          ),
          _HelpItem(
            icon: Icons.phone_android_outlined,
            title: 'Pindah ke HP baru',
            body: 'Buat backup di HP lama, pindahkan berkasnya, lalu pilih Restore di HP baru.',
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
