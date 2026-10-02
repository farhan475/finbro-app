import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/seed.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/formatting/money.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../accounts/data/account_repository.dart';
import '../../calendar/domain/daily_check_service.dart';
import '../../planning/data/planning_repository.dart';

/// First-run flow: welcome → name → accounts → planning → reminder.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _CreatedAccount {
  const _CreatedAccount(this.name, this.type, this.openingBalance);
  final String name;
  final AccountType type;
  final int openingBalance;
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _pageCount = 5;
  static const _quickAccounts = [
    ('BCA', AccountType.bank),
    ('GoPay', AccountType.ewallet),
    ('SeaBank', AccountType.bank),
    ('Jago', AccountType.bank),
    ('Cash', AccountType.cash),
  ];

  final _pages = PageController();
  int _page = 0;
  bool _busy = false;

  final _name = TextEditingController();
  final _accountForm = GlobalKey<FormState>();
  final _accountName = TextEditingController();
  final _opening = TextEditingController();
  AccountType _accountType = AccountType.bank;
  final List<_CreatedAccount> _created = [];

  PlanningSetting? _planning;
  int _emergencyMonths = 3;
  final _buffer = TextEditingController(text: '0');

  /// Editable bucket percentages, initialised from planning_settings.
  AllocationPlan? _plan;

  TimeOfDay _checkTime = const TimeOfDay(hour: 20, minute: 30);
  bool _dailyCheck = true;

  @override
  void initState() {
    super.initState();
    _loadPlanning();
  }

  @override
  void dispose() {
    for (final c in [_name, _accountName, _opening, _buffer]) {
      c.dispose();
    }
    _pages.dispose();
    super.dispose();
  }

  AppDatabase get _db => ref.read(databaseProvider);

  Future<void> _loadPlanning() async {
    final row = await (_db.select(_db.planningSettings)..where((p) => p.id.equals(planningSettingsId)))
        .getSingleOrNull();
    if (!mounted || row == null) return;
    setState(() {
      _planning = row;
      _plan = row.plan;
      _emergencyMonths = row.targetEmergencyMonths;
      _buffer.text = MoneyField.textFor(row.minimumCashBuffer);
    });
  }

  void _adjust(PlanningBucket bucket, int delta) {
    final p = _plan;
    if (p == null) return;
    int v(PlanningBucket b, int current) => b == bucket ? (current + delta).clamp(0, 100) : current;
    setState(
      () => _plan = AllocationPlan(
        essential: v(PlanningBucket.essential, p.essential),
        family: v(PlanningBucket.family, p.family),
        emergency: v(PlanningBucket.emergency, p.emergency),
        savings: v(PlanningBucket.savings, p.savings),
        development: v(PlanningBucket.development, p.development),
        personal: v(PlanningBucket.personal, p.personal),
        flexibleResidual: p.flexibleResidual,
      ),
    );
  }

  bool get _canContinue => switch (_page) {
    1 => _name.text.trim().isNotEmpty,
    2 => _created.isNotEmpty,
    3 => _plan?.validate() == null,
    _ => true,
  };

  Future<void> _next() async {
    if (!_canContinue || _busy) return;
    setState(() => _busy = true);
    try {
      final settings = ref.read(appSettingsRepositoryProvider);
      switch (_page) {
        case 1:
          await settings.set(SettingKeys.userName, _name.text.trim());
        case 3:
          final row = _planning!;
          await ref.read(planningRepositoryProvider).save(
            plan: _plan!,
            targetEmergencyMonths: _emergencyMonths,
            emergencyLookbackMonths: row.emergencyLookbackMonths,
            minimumCashBuffer: parseRupiah(_buffer.text) ?? 0,
            userReserve: row.userReserve,
          );
        case 4:
          await _finish();
          return;
      }
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      await _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } catch (e, s) {
      AppLogger.error('Onboarding gagal disimpan', e, s);
      if (mounted) showSnack(context, 'Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    // Read everything up front: saving onboardingDone makes the router
    // redirect away, which may dispose this screen mid-way.
    final settings = ref.read(appSettingsRepositoryProvider);
    final dailyCheck = ref.read(dailyCheckServiceProvider);
    final now = ref.read(clockProvider)();
    await settings.set(SettingKeys.dailyCheckTime, formatTimeOfDay(_checkTime));
    await settings.setBool(SettingKeys.dailyCheckEnabled, _dailyCheck);
    await settings.setBool(SettingKeys.onboardingDone, true);
    AppLogger.info('Onboarding selesai');
    if (mounted) context.go(Routes.home);
    // Lifecycle reschedules skip everything before onboarding is done; apply
    // the chosen time/toggle now instead of waiting for the next resume.
    try {
      await dailyCheck.reschedule(now);
    } catch (e, s) {
      AppLogger.error('Penjadwalan daily check setelah onboarding gagal', e, s);
    }
  }

  Future<void> _addAccount() async {
    if (!_accountForm.currentState!.validate()) return;
    final name = _accountName.text.trim();
    final opening = parseRupiah(_opening.text) ?? 0;
    try {
      await ref.read(accountRepositoryProvider).create(
        name: name,
        type: _accountType,
        openingBalance: opening,
      );
    } on AccountException catch (e) {
      if (mounted) showSnack(context, e.message);
      return;
    }
    if (!mounted) return;
    setState(() {
      _created.add(_CreatedAccount(name, _accountType, opening));
      _accountName.clear();
      _opening.clear();
    });
  }

  Future<void> _requestPermission() async {
    final ok = await NotificationService.instance.requestPermission();
    if (mounted) showSnack(context, ok ? 'Notifikasi diizinkan.' : 'Izin notifikasi belum diberikan.');
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  if (_page > 0)
                    IconButton(
                      tooltip: 'Kembali',
                      onPressed: _busy
                          ? null
                          : () => _pages.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                      icon: const Icon(Icons.arrow_back),
                    )
                  else
                    const SizedBox(width: 48),
                  Expanded(
                    child: Text(
                      'Langkah ${_page + 1} dari $_pageCount',
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall!.copyWith(color: fin.muted),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (p) => setState(() => _page = p),
                children: [_welcome(), _namePage(), _accountsPage(), _planningPage(), _reminderPage()],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _canContinue && !_busy ? _next : null,
                  child: Text(switch (_page) {
                    0 => 'Mulai',
                    4 => 'Selesai',
                    _ => 'Lanjut',
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _padded(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
    children: children,
  );

  Widget _welcome() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const FinBroWordmark(markSize: 72),
          const SizedBox(height: 16),
          Text('Better plan, brighter future', style: context.text.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Text(
            'Semua data keuanganmu tersimpan offline di perangkat ini. Tanpa akun online, '
            'tanpa sinkronisasi, tanpa iklan.',
            style: context.text.bodyMedium!.copyWith(color: context.fin.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Widget _namePage() => _padded([
    Text('Siapa namamu?', style: context.text.headlineSmall),
    const SizedBox(height: 8),
    Text('Dipakai untuk menyapa di aplikasi.', style: context.text.bodySmall),
    const SizedBox(height: 16),
    TextField(
      controller: _name,
      maxLength: 40,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(labelText: 'Nama'),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _next(),
    ),
  ]);

  Widget _accountsPage() => _padded([
    Text('Tambah akun', style: context.text.headlineSmall),
    const SizedBox(height: 8),
    Text('Minimal satu akun beserta saldo awalnya.', style: context.text.bodySmall),
    const SizedBox(height: 12),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (name, type) in _quickAccounts)
          ActionChip(
            label: Text(name),
            onPressed: () => setState(() {
              _accountName.text = name;
              _accountType = type;
            }),
          ),
      ],
    ),
    const SizedBox(height: 12),
    Form(
      key: _accountForm,
      child: Column(
        children: [
          TextFormField(
            controller: _accountName,
            maxLength: AccountRepository.maxNameLength,
            decoration: const InputDecoration(labelText: 'Nama akun'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Masukkan nama akun' : null,
          ),
          DropdownButtonFormField<AccountType>(
            initialValue: _accountType,
            decoration: const InputDecoration(labelText: 'Jenis'),
            items: [
              for (final t in AccountType.values) DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (t) => setState(() => _accountType = t ?? _accountType),
          ),
          const SizedBox(height: 12),
          MoneyField(controller: _opening, label: 'Saldo awal', allowZero: true),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _addAccount,
              icon: const Icon(Icons.add),
              label: const Text('Tambah akun'),
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    if (_created.isEmpty)
      const EmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: 'Belum ada akun',
        message: 'Pilih salah satu cepat di atas atau ketik nama akun.',
      )
    else
      for (final a in _created)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: IconAvatar(accountTypeIcon(a.type)),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(a.type.label),
          trailing: FittedBox(child: Text(formatRupiah(a.openingBalance))),
        ),
  ]);

  Widget _planningPage() {
    final fin = context.fin;
    final p = _plan;
    final error = p?.validate();
    return _padded([
      Text('Planning', style: context.text.headlineSmall),
      const SizedBox(height: 8),
      Text(
        'Alokasi setiap Income masuk. Default ini titik awal, bukan aturan; total harus 100%. '
        'Bisa diubah lagi di Pengaturan → Planning & alokasi.',
        style: context.text.bodySmall,
      ),
      const SizedBox(height: 12),
      if (p != null)
        FinCard(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Column(
            children: [
              for (final (bucket, pct) in p.percents.entries.map((e) => (e.key, e.value)))
                Row(
                  children: [
                    Expanded(child: Text(bucket.label)),
                    IconButton(
                      tooltip: 'Kurangi ${bucket.label}',
                      onPressed: pct <= 0 ? null : () => _adjust(bucket, -5),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text('$pct%', style: context.text.titleSmall, textAlign: TextAlign.center),
                    ),
                    IconButton(
                      tooltip: 'Tambah ${bucket.label}',
                      onPressed: pct >= 100 ? null : () => _adjust(bucket, 5),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Row(
                  children: [
                    Expanded(child: Text('Total', style: context.text.titleSmall)),
                    Text(
                      '${p.total}%',
                      style: context.text.titleSmall!.copyWith(color: error == null ? fin.text : fin.negative),
                    ),
                  ],
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: Text(error, style: context.text.bodySmall!.copyWith(color: fin.negative)),
                ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(
        initialValue: _emergencyMonths,
        decoration: const InputDecoration(labelText: 'Target Emergency Fund'),
        items: [
          for (final m in const [1, 2, 3, 6, 9, 12]) DropdownMenuItem(value: m, child: Text('$m bulan pengeluaran essential')),
        ],
        onChanged: (m) => setState(() => _emergencyMonths = m ?? _emergencyMonths),
      ),
      const SizedBox(height: 12),
      MoneyField(controller: _buffer, label: 'Minimum cash buffer', allowZero: true),
    ]);
  }

  Widget _reminderPage() => _padded([
    Text('Pengingat harian', style: context.text.headlineSmall),
    const SizedBox(height: 8),
    Text(
      'FinBro mengingatkan untuk mencatat transaksi jika hari itu belum ada aktivitas.',
      style: context.text.bodySmall,
    ),
    const SizedBox(height: 12),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Daily check'),
      value: _dailyCheck,
      onChanged: (v) => setState(() => _dailyCheck = v),
    ),
    ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: _dailyCheck,
      title: const Text('Jam pengingat'),
      trailing: Text(formatTimeOfDay(_checkTime), style: context.text.titleMedium),
      onTap: () async {
        final t = await showTimePicker(context: context, initialTime: _checkTime);
        if (t != null && mounted) setState(() => _checkTime = t);
      },
    ),
    const SizedBox(height: 8),
    OutlinedButton.icon(
      onPressed: _requestPermission,
      icon: const Icon(Icons.notifications_active_outlined),
      label: const Text('Izinkan notifikasi'),
    ),
  ]);
}
