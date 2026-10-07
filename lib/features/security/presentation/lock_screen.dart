import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../domain/app_lock_service.dart';

/// Full-screen PIN pad shown by [AppLockGate]. It lives above the Navigator,
/// so it only uses plain widgets (no dialogs, no text fields).
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({
    super.key,
    required this.biometricEnabled,
    required this.onUnlocked,
    required this.authenticateBiometric,
  });

  final bool biometricEnabled;
  final VoidCallback onUnlocked;
  final Future<bool> Function() authenticateBiometric;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  static const _maxDigits = 6;
  final _limiter = PinAttemptLimiter.instance;
  String _pin = '';
  String? _error;
  bool _verifying = false;
  bool _biometricRunning = false;
  Timer? _ticker;
  // Last known cooldown (null: none); _submit re-checks before verifying.
  Duration? _cooldown;

  @override
  void initState() {
    super.initState();
    ref.read(appLockServiceProvider); // binds the persisted attempt limiter
    _refreshCooldown();
    if (widget.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Re-reads the cooldown; ticks every second while one is active so the
  /// countdown text stays fresh.
  Future<void> _refreshCooldown() async {
    final cooldown = await _limiter.remaining();
    if (!mounted) return;
    setState(() {
      if (cooldown == null && _cooldown != null) _error = null;
      _cooldown = cooldown;
    });
    if (cooldown == null) {
      _ticker?.cancel();
      _ticker = null;
    } else {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _refreshCooldown());
    }
  }

  Future<void> _biometric() async {
    if (_biometricRunning || !mounted) return;
    _biometricRunning = true;
    try {
      if (await widget.authenticateBiometric()) {
        unawaited(_limiter.reset());
        widget.onUnlocked();
      }
    } finally {
      _biometricRunning = false;
    }
  }

  void _digit(String d) {
    if (_verifying || _cooldown != null || _pin.length >= _maxDigits) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _backspace() {
    if (_verifying || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_verifying || _cooldown != null) return;
    if (_pin.length < 4) {
      setState(() => _error = 'PIN terdiri dari 4–6 digit.');
      return;
    }
    setState(() => _verifying = true);
    if (await _limiter.remaining() != null) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _pin = '';
      });
      await _refreshCooldown();
      return;
    }
    try {
      final ok = await ref.read(appLockServiceProvider).verifyPin(_pin);
      if (!mounted) return;
      if (ok) {
        unawaited(_limiter.reset());
        widget.onUnlocked();
        return;
      }
      await _limiter.recordFailure();
      final cooldown = await _limiter.remaining();
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _verifying = false;
        _pin = '';
        _error = cooldown != null ? null : 'PIN salah. Sisa ${_limiter.attemptsLeft} percobaan.';
      });
      await _refreshCooldown();
    } on PinIntegrityException catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _pin = '';
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final cooldown = _cooldown;
    final message = cooldown != null
        ? 'Terlalu banyak percobaan. Coba lagi dalam ${cooldown.inSeconds + 1} detik.'
        : _error;
    return Material(
      color: fin.background,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const FinBroMark(size: 48),
                    const SizedBox(height: 12),
                    Text('FinBro', style: context.text.titleLarge),
                    const SizedBox(height: 24),
                    Text('Masukkan PIN', style: context.text.titleMedium),
                    const SizedBox(height: 16),
                    Semantics(
                      label: '${_pin.length} digit dimasukkan',
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < _maxDigits; i++)
                            Container(
                              width: 14,
                              height: 14,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i < _pin.length ? fin.text : Colors.transparent,
                                border: Border.all(color: i < _pin.length ? fin.text : fin.border, width: 1.5),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: Center(
                        child: message == null
                            ? null
                            : Text(
                                message,
                                textAlign: TextAlign.center,
                                style: context.text.bodySmall!.copyWith(
                                  color: cooldown != null ? fin.warning : fin.negative,
                                ),
                              ),
                      ),
                    ),
                    _PinPad(
                      enabled: cooldown == null && !_verifying,
                      onDigit: _digit,
                      onBackspace: _backspace,
                      onSubmit: _submit,
                    ),
                    const SizedBox(height: 16),
                    if (widget.biometricEnabled)
                      TextButton.icon(
                        onPressed: _biometric,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Gunakan biometrik'),
                        style: TextButton.styleFrom(foregroundColor: fin.text),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      appLockDisclaimer,
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall!.copyWith(color: fin.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 3×4 numeric keypad: digits, backspace, confirm.
class _PinPad extends StatelessWidget {
  const _PinPad({required this.enabled, required this.onDigit, required this.onBackspace, required this.onSubmit});

  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    Widget key({required Widget child, required VoidCallback onTap, required String label}) => Padding(
      padding: const EdgeInsets.all(8),
      child: Semantics(
        button: true,
        label: label,
        child: InkResponse(
          onTap: enabled ? onTap : null,
          radius: 36,
          child: SizedBox(width: 64, height: 64, child: Center(child: child)),
        ),
      ),
    );
    Widget digit(String d) => key(
      label: d,
      onTap: () => onDigit(d),
      child: Text(d, style: context.text.headlineSmall),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) digit(d)]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            key(label: 'Hapus digit', onTap: onBackspace, child: const Icon(Icons.backspace_outlined)),
            digit('0'),
            key(label: 'Buka', onTap: onSubmit, child: const Icon(Icons.check_circle_outline, size: 30)),
          ],
        ),
      ],
    );
  }
}
