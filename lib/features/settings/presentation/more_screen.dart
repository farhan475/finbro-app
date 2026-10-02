import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes.dart';
import '../../../app/shell.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../domain/demo_data.dart';
import 'settings_widgets.dart';

/// "More" tab: feature shortcuts, settings, reliability banners.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(userNameProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, navBarClearance(context)),
          children: [
            Row(
              children: [
                const FinBroMark(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'FinBro' : name,
                        style: context.text.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text('Finance Brother App', style: context.text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const ReliabilityBanners(),
            const SettingsSection(
              title: 'Fitur',
              children: [
                NavTile(icon: Icons.flag_outlined, title: 'Tujuan Keuangan', route: Routes.goals),
                NavTile(icon: Icons.account_balance_wallet_outlined, title: 'Akun', route: Routes.accounts),
                NavTile(icon: Icons.category_outlined, title: 'Kategori', route: Routes.categories),
                NavTile(icon: Icons.autorenew, title: 'Transaksi Berulang', route: Routes.recurring),
                NavTile(icon: Icons.calendar_month_outlined, title: 'Kalender', route: Routes.calendar),
                NavTile(icon: Icons.monitor_heart_outlined, title: 'Financial Health', route: Routes.health),
                NavTile(icon: Icons.document_scanner_outlined, title: 'Scan', route: Routes.scan),
                NavTile(icon: Icons.receipt_long_outlined, title: 'Impor Mutasi Bank', route: Routes.statementImport),
              ],
            ),
            const SettingsGroup(),
            if (kDebugMode) const _DeveloperSection(),
          ],
        ),
      ),
    );
  }
}

/// Debug builds only: sample data and full wipe.
class _DeveloperSection extends ConsumerStatefulWidget {
  const _DeveloperSection();

  @override
  ConsumerState<_DeveloperSection> createState() => _DeveloperSectionState();
}

class _DeveloperSectionState extends ConsumerState<_DeveloperSection> {
  bool _busy = false;

  Future<void> _seed() async {
    setState(() => _busy = true);
    try {
      final n = await ref.read(demoDataProvider).seed(ref.read(clockProvider)());
      if (mounted) showSnack(context, 'Data demo dibuat: $n transaksi.');
    } catch (e, s) {
      AppLogger.error('Data demo gagal', e, s);
      if (mounted) showSnack(context, 'Data demo gagal: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wipe() async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus semua data?',
      message: 'Semua akun, transaksi, budget, goals, lampiran, dan pengaturan dihapus permanen. '
          'Aplikasi kembali ke onboarding.',
      confirmLabel: 'Hapus semua',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(demoDataProvider).wipeAll();
    } catch (e, s) {
      AppLogger.error('Hapus semua data gagal', e, s);
      if (mounted) showSnack(context, 'Gagal menghapus data: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return SettingsSection(
      title: 'Developer (debug)',
      children: [
        if (_busy) LinearProgressIndicator(minHeight: 2, color: fin.primary),
        ListTile(
          enabled: !_busy,
          leading: const Icon(Icons.science_outlined),
          title: const Text('Isi data demo'),
          subtitle: const Text('Akun, 3 bulan transaksi, budget, goals'),
          onTap: _seed,
        ),
        ListTile(
          enabled: !_busy,
          leading: Icon(Icons.delete_forever_outlined, color: fin.negative),
          title: Text('Hapus semua data', style: TextStyle(color: fin.negative)),
          onTap: _wipe,
        ),
      ],
    );
  }
}
