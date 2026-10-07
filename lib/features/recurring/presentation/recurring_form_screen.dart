import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/seed.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/recurring_repository.dart';
import '../domain/due_dates.dart';

/// `/recurring/:id/edit`: loads the rule, then shows the form.
class RecurringEditScreen extends ConsumerWidget {
  const RecurringEditScreen({super.key, required this.ruleId});
  final String ruleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(recurringRuleDetailProvider(ruleId));
    return detail.when(
      data: (d) => d == null
          ? Scaffold(
              appBar: AppBar(),
              body: const EmptyState(icon: Icons.event_busy_outlined, title: 'Transaksi berulang tidak ditemukan'),
            )
          : RecurringFormScreen(ruleId: ruleId, initial: RecurringRuleDraft.fromRule(d.rule)),
      loading: () => Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
      error: (e, _) => Scaffold(appBar: AppBar(), body: Center(child: Text('Terjadi kesalahan: $e'))),
    );
  }
}

/// Create (`/recurring/new`, optional `?preset=salary`) or edit a rule.
class RecurringFormScreen extends ConsumerStatefulWidget {
  const RecurringFormScreen({super.key, this.ruleId, this.initial, this.salaryPreset = false});

  final String? ruleId;
  final RecurringRuleDraft? initial;
  final bool salaryPreset;

  @override
  ConsumerState<RecurringFormScreen> createState() => _RecurringFormScreenState();
}

class _RecurringFormScreenState extends ConsumerState<RecurringFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _interval = TextEditingController(text: '30');

  TransactionType _type = TransactionType.expense;
  String? _accountId;
  String? _categoryId;
  RecurringFrequency _frequency = RecurringFrequency.monthly;
  late int _dayOfWeek;
  late int _dayOfMonth;
  late int _monthOfYear;
  late DateTime _start;
  DateTime? _end;
  bool _reminder = true;
  int _offset = 1;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  bool _autoConfirm = false;
  bool _busy = false;

  bool get _editing => widget.ruleId != null;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(ref.read(clockProvider)());
    _start = today;
    _dayOfWeek = today.weekday;
    _dayOfMonth = today.day;
    _monthOfYear = today.month;
    final d = widget.initial;
    if (d != null) {
      _type = d.type;
      _name.text = d.name;
      _amount.text = MoneyField.textFor(d.amount, _currencyOf(ref.read(accountMapProvider), d.accountId));
      _accountId = d.accountId;
      _categoryId = d.categoryId;
      _frequency = d.frequency;
      _dayOfWeek = d.dayOfWeek ?? d.startDate.weekday;
      _dayOfMonth = d.dayOfMonth ?? d.startDate.day;
      _monthOfYear = d.monthOfYear ?? d.startDate.month;
      _interval.text = '${d.intervalDays ?? 30}';
      _start = d.startDate;
      _end = d.endDate;
      _reminder = d.reminderEnabled;
      _offset = d.reminderOffsetDays;
      _time = parseTimeOfDay(d.reminderTime, fallback: _time);
      _autoConfirm = d.autoConfirm;
    } else if (widget.salaryPreset) {
      _applySalaryPreset();
    }
    _interval.addListener(() => setState(() {}));
  }

  static Currency _currencyOf(Map<String, Account> accounts, String? id) =>
      Currency.fromCode(accounts[id]?.currency ?? 'IDR');

  void _applySalaryPreset() {
    _type = TransactionType.income;
    _name.text = 'Salary';
    _categoryId = SystemCategories.salary;
    _frequency = RecurringFrequency.monthly;
    _dayOfMonth = 25;
    _reminder = true;
    _offset = 1;
    _autoConfirm = false;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _interval.dispose();
    super.dispose();
  }

  RecurrenceSpec? get _spec {
    final interval = int.tryParse(_interval.text);
    if (_frequency == RecurringFrequency.custom && (interval == null || interval < 1)) return null;
    return RecurrenceSpec(
      frequency: _frequency,
      startDate: _start,
      endDate: _end,
      dayOfWeek: _dayOfWeek,
      dayOfMonth: _dayOfMonth,
      monthOfYear: _monthOfYear,
      intervalDays: interval,
    );
  }

  Future<void> _pickDate({required bool end}) async {
    final initial = end ? (_end ?? _start) : _start;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: end ? _start : DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (end) {
        _end = picked;
      } else {
        _start = picked;
        if (_end != null && _end!.isBefore(picked)) _end = null;
      }
    });
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time);
    if (t != null) setState(() => _time = t);
  }

  Future<void> _toggleAutoConfirm(bool v) async {
    if (v) {
      final ok = await confirmDialog(
        context,
        title: 'Aktifkan auto-confirm?',
        message:
            'Setiap jadwal akan otomatis dicatat sebagai transaksi confirmed pada tanggal jatuh tempo '
            '(saat aplikasi dibuka), tanpa menunggu konfirmasi Anda. Saldo account langsung berubah. '
            'Jadwal sebelum rule dibuat tetap menunggu konfirmasi. Anda tetap bisa mengedit atau '
            'menghapus transaksinya; jadwal yang transaksinya dihapus dianggap dilewati.',
        confirmLabel: 'Aktifkan',
      );
      if (!ok) return;
    }
    setState(() => _autoConfirm = v);
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final draft = RecurringRuleDraft(
      type: _type,
      name: _name.text,
      amount: parseMoney(_amount.text, _currencyOf(ref.read(accountMapProvider), _accountId)) ?? 0,
      accountId: _accountId!,
      categoryId: _categoryId!,
      frequency: _frequency,
      startDate: _start,
      endDate: _end,
      dayOfWeek: _dayOfWeek,
      dayOfMonth: _dayOfMonth,
      monthOfYear: _monthOfYear,
      intervalDays: int.tryParse(_interval.text),
      reminderEnabled: _reminder,
      reminderOffsetDays: _offset,
      reminderTime: formatTimeOfDay(_time),
      autoConfirm: _autoConfirm,
    );
    setState(() => _busy = true);
    try {
      final repo = ref.read(recurringRepositoryProvider);
      if (_editing) {
        await repo.update(widget.ruleId!, draft);
      } else {
        await repo.create(draft);
      }
      if (!mounted) return;
      showSnack(context, _editing ? 'Perubahan disimpan' : '${draft.name.trim()} dijadwalkan');
      context.pop();
    } on LedgerValidationException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final accounts = ref.watch(activeAccountsProvider);
    final accountMap = ref.watch(accountMapProvider);
    final categoryType = _type == TransactionType.income ? CategoryType.income : CategoryType.expense;
    final categories = [...ref.watch(activeCategoriesProvider(categoryType))];
    final current = ref.watch(categoryMapProvider)[_categoryId];
    if (current != null && current.type == categoryType && !categories.any((c) => c.id == current.id)) {
      categories.add(current);
    }
    final accountChoices = [...accounts];
    final currentAccount = accountMap[_accountId];
    if (_editing && currentAccount != null && !currentAccount.isActive) accountChoices.add(currentAccount);
    if (_accountId == null && accounts.isNotEmpty) _accountId = accounts.first.id;

    final today = dateOnly(ref.watch(clockProvider)());
    final spec = _spec;
    final next = spec?.nextOnOrAfter(today);

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit transaksi berulang' : 'Transaksi berulang baru')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (!_editing && _name.text != 'Salary')
              Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  avatar: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Gunakan preset Salary'),
                  onPressed: () => setState(_applySalaryPreset),
                ),
              ),
            const SizedBox(height: 8),
            SegmentedButton<TransactionType>(
              segments: const [
                ButtonSegment(value: TransactionType.income, label: SegmentLabel('Income'), icon: Icon(Icons.arrow_upward)),
                ButtonSegment(value: TransactionType.expense, label: SegmentLabel('Expense'), icon: Icon(Icons.arrow_downward)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                final cat = ref.read(categoryMapProvider)[_categoryId];
                final wanted = _type == TransactionType.income ? CategoryType.income : CategoryType.expense;
                if (cat?.type != wanted) _categoryId = null;
              }),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nama', hintText: 'mis. Salary, Internet, Kos'),
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Nama wajib diisi' : null,
            ),
            const SizedBox(height: 8),
            MoneyField(
              controller: _amount,
              label: 'Nominal',
              large: true,
              currency: _currencyOf(accountMap, _accountId),
            ),
            const SizedBox(height: 16),
            if (accountChoices.isEmpty)
              FinCard(
                child: Row(
                  children: [
                    Expanded(child: Text('Belum ada account aktif.', style: context.text.bodyMedium)),
                    TextButton(onPressed: () => context.push(Routes.accounts), child: const Text('Tambah account')),
                  ],
                ),
              )
            else
              DropdownButtonFormField<String>(
                key: ValueKey('account-${accountChoices.length}'),
                initialValue: accountChoices.any((a) => a.id == _accountId) ? _accountId : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: _type == TransactionType.income ? 'Masuk ke account' : 'Dari account'),
                items: [
                  for (final a in accountChoices)
                    DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() {
                  MoneyField.switchCurrency(_amount, _currencyOf(accountMap, _accountId), _currencyOf(accountMap, v));
                  _accountId = v;
                }),
                validator: (v) => v == null ? 'Pilih account' : null,
              ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('category-${_type.db}-$_categoryId-${categories.length}'),
              initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Kategori'),
              items: [
                for (final c in categories)
                  DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _categoryId = v),
              validator: (v) => v == null ? 'Pilih kategori' : null,
            ),
            const SizedBox(height: 24),
            Text('Jadwal', style: context.text.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<RecurringFrequency>(
              key: ValueKey(_frequency),
              initialValue: _frequency,
              decoration: const InputDecoration(labelText: 'Frekuensi'),
              items: [
                for (final f in RecurringFrequency.values) DropdownMenuItem(value: f, child: Text(f.label)),
              ],
              onChanged: (v) => setState(() => _frequency = v ?? _frequency),
            ),
            const SizedBox(height: 12),
            ..._frequencyFields(context),
            const SizedBox(height: 12),
            _DateField(label: 'Tanggal mulai', date: _start, onTap: () => _pickDate(end: false)),
            const SizedBox(height: 12),
            _DateField(
              label: 'Tanggal selesai (opsional)',
              date: _end,
              onTap: () => _pickDate(end: true),
              onClear: _end == null ? null : () => setState(() => _end = null),
            ),
            const SizedBox(height: 8),
            Text(
              next == null ? 'Tidak ada jadwal berikutnya (jadwal sudah berakhir).' : 'Jadwal berikutnya: ${formatDay(next)}',
              style: context.text.bodySmall,
            ),
            const SizedBox(height: 24),
            Text('Pengingat', style: context.text.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kirim pengingat'),
              subtitle: const Text('Notifikasi lokal sebelum jatuh tempo'),
              value: _reminder,
              onChanged: (v) => setState(() => _reminder = v),
            ),
            if (_reminder) ...[
              SegmentedButton<int>(
                segments: [
                  for (final o in reminderOffsets) ButtonSegment(value: o, label: SegmentLabel(reminderOffsetLabel(o))),
                ],
                selected: {_offset},
                onSelectionChanged: (s) => setState(() => _offset = s.first),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickTime,
                borderRadius: BorderRadius.circular(AppRadius.input),
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Jam pengingat', suffixIcon: Icon(Icons.schedule)),
                  child: Text(formatTimeOfDay(_time)),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text('Konfirmasi', style: context.text.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-confirm'),
              subtitle: const Text(
                'Nonaktif (disarankan): jadwal menunggu konfirmasi Anda sebelum masuk ke saldo. '
                'Aktif: transaksi otomatis dicatat pada tanggal jatuh tempo saat aplikasi dibuka.',
              ),
              isThreeLine: true,
              value: _autoConfirm,
              onChanged: _toggleAutoConfirm,
            ),
            if (_autoConfirm)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: fin.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Auto-confirm aktif: saldo berubah otomatis tanpa konfirmasi.',
                        style: context.text.bodySmall?.copyWith(color: fin.warning),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy || accountChoices.isEmpty ? null : _save,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _frequencyFields(BuildContext context) => switch (_frequency) {
    RecurringFrequency.weekly => [
      Text('Hari', style: context.text.bodySmall),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var d = 1; d <= 7; d++)
            ChoiceChip(
              label: Text(weekdayShort[d - 1]),
              tooltip: weekdayNames[d - 1],
              selected: _dayOfWeek == d,
              onSelected: (_) => setState(() => _dayOfWeek = d),
            ),
        ],
      ),
    ],
    RecurringFrequency.monthly => [
      _dayOfMonthField(),
      if (_dayOfMonth >= 29)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Bulan yang lebih pendek memakai hari terakhirnya (mis. 31 → 30 Sep, 28/29 Feb).',
            style: context.text.bodySmall,
          ),
        ),
    ],
    RecurringFrequency.yearly => [
      Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<int>(
              initialValue: _monthOfYear,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Bulan'),
              items: [
                for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(monthNames[m - 1])),
              ],
              onChanged: (v) => setState(() => _monthOfYear = v ?? _monthOfYear),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: _dayOfMonthField()),
        ],
      ),
      if (_monthOfYear == 2 && _dayOfMonth == 29)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Tahun non-kabisat memakai 28 Feb.', style: context.text.bodySmall),
        ),
    ],
    RecurringFrequency.custom => [
      TextFormField(
        controller: _interval,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Setiap berapa hari', suffixText: 'hari'),
        validator: (v) {
          final n = int.tryParse(v ?? '');
          return (n == null || n < 1 || n > 3650) ? 'Isi 1–3650 hari' : null;
        },
      ),
      const SizedBox(height: 6),
      Text('Dihitung dari tanggal mulai.', style: context.text.bodySmall),
    ],
  };

  Widget _dayOfMonthField() => DropdownButtonFormField<int>(
    key: ValueKey('dom-$_dayOfMonth'),
    initialValue: _dayOfMonth,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Tanggal'),
    items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
    onChanged: (v) => setState(() => _dayOfMonth = v ?? _dayOfMonth),
  );
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.date, required this.onTap, this.onClear});
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(AppRadius.input),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: onClear == null
            ? const Icon(Icons.calendar_today_outlined)
            : IconButton(tooltip: 'Hapus tanggal', icon: const Icon(Icons.close), onPressed: onClear),
      ),
      child: Text(date == null ? 'Tidak ada' : formatDay(date!)),
    ),
  );
}
