import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/category_icon.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../domain/app_lock_service.dart';
import '../domain/pin_hasher.dart';

class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  Future<void> _enable(BuildContext context, WidgetRef ref) async {
    final values = await _PinDialog.show(
      context,
      title: 'Aktifkan PIN',
      fields: const ['PIN baru (4–6 digit)', 'Ulangi PIN'],
      mustMatchLastTwo: true,
    );
    if (values == null || !context.mounted) return;
    try {
      await ref.read(appLockServiceProvider).setPin(values[0]);
      if (context.mounted) showSnack(context, 'App lock aktif.');
    } on PinException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  Future<void> _change(BuildContext context, WidgetRef ref) async {
    final values = await _PinDialog.show(
      context,
      title: 'Ubah PIN',
      fields: const ['PIN saat ini', 'PIN baru (4–6 digit)', 'Ulangi PIN baru'],
      mustMatchLastTwo: true,
    );
    if (values == null || !context.mounted) return;
    try {
      await ref.read(appLockServiceProvider).changePin(current: values[0], next: values[1]);
      if (context.mounted) showSnack(context, 'PIN diperbarui.');
    } on PinException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  Future<void> _disable(BuildContext context, WidgetRef ref) async {
    final values = await _PinDialog.show(
      context,
      title: 'Nonaktifkan PIN',
      fields: const ['PIN saat ini'],
      confirmLabel: 'Nonaktifkan',
    );
    if (values == null || !context.mounted) return;
    try {
      await ref.read(appLockServiceProvider).disable(current: values[0]);
      if (context.mounted) showSnack(context, 'App lock dinonaktifkan.');
    } on PinException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fin = context.fin;
    final config = ref.watch(appLockConfigProvider);
    final biometricAvailable = ref.watch(biometricAvailableProvider).value ?? false;
    final service = ref.read(appLockServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Keamanan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FinCard(
            child: Row(
              children: [
                IconAvatar(config.pinEnabled ? Icons.lock_outline : Icons.lock_open_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('App lock', style: context.text.titleMedium),
                      Text(
                        config.pinEnabled
                            ? 'Aktif — PIN${config.biometricEnabled ? ' + biometrik' : ''}'
                            : 'Nonaktif',
                        style: context.text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (!config.pinEnabled)
            FilledButton.icon(
              onPressed: () => _enable(context, ref),
              icon: const Icon(Icons.pin_outlined),
              label: const Text('Aktifkan PIN'),
            )
          else
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.password),
                    title: const Text('Ubah PIN'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _change(context, ref),
                  ),
                  ListTile(
                    leading: Icon(Icons.no_encryption_outlined, color: fin.negative),
                    title: Text('Nonaktifkan PIN', style: TextStyle(color: fin.negative)),
                    onTap: () => _disable(context, ref),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Buka dengan biometrik'),
              subtitle: Text(
                !biometricAvailable
                    ? 'Tidak tersedia di perangkat ini'
                    : config.pinEnabled
                        ? 'Sidik jari / wajah, PIN tetap bisa dipakai'
                        : 'Aktifkan PIN terlebih dahulu',
              ),
              value: config.biometricEnabled,
              onChanged: biometricAvailable && config.pinEnabled
                  ? (v) => service.setBiometricEnabled(v)
                  : null,
            ),
          ),
          const SectionHeader('Kunci otomatis'),
          Text(
            'Kunci lagi setelah aplikasi berada di latar belakang selama:',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (final e in lockTimeoutOptions.entries) ButtonSegment(value: e.key, label: SegmentLabel(e.value)),
            ],
            selected: {
              lockTimeoutOptions.containsKey(config.timeoutSeconds) ? config.timeoutSeconds : defaultLockTimeoutSeconds,
            },
            onSelectionChanged: config.pinEnabled ? (s) => service.setLockTimeout(s.first) : null,
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: fin.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$appLockDisclaimer Lupa PIN tidak dapat dipulihkan; simpan backup secara rutin.',
                  style: context.text.bodySmall!.copyWith(color: fin.muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Obscured numeric PIN fields in a dialog. Returns the entered values.
class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.title, required this.fields, required this.mustMatchLastTwo, required this.confirmLabel});

  final String title;
  final List<String> fields;
  final bool mustMatchLastTwo;
  final String confirmLabel;

  static Future<List<String>?> show(
    BuildContext context, {
    required String title,
    required List<String> fields,
    bool mustMatchLastTwo = false,
    String confirmLabel = 'Simpan',
  }) => showDialog<List<String>>(
    context: context,
    builder: (_) => _PinDialog(
      title: title,
      fields: fields,
      mustMatchLastTwo: mustMatchLastTwo,
      confirmLabel: confirmLabel,
    ),
  );

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _form = GlobalKey<FormState>();
  late final _controllers = [for (final _ in widget.fields) TextEditingController()];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, [for (final c in _controllers) c.text]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.fields.length;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < n; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextFormField(
                  controller: _controllers[i],
                  autofocus: i == 0,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textInputAction: i == n - 1 ? TextInputAction.done : TextInputAction.next,
                  onFieldSubmitted: i == n - 1 ? (_) => _submit() : null,
                  decoration: InputDecoration(labelText: widget.fields[i], counterText: ''),
                  validator: (v) {
                    if (!PinHasher.isValidPin(v ?? '')) return 'PIN harus 4–6 digit angka';
                    if (widget.mustMatchLastTwo && i == n - 1 && n >= 2 && v != _controllers[n - 2].text) {
                      return 'PIN tidak sama';
                    }
                    return null;
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        TextButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
