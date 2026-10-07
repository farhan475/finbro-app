import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme/app_theme.dart';
import '../../core/database/enums.dart';
import '../../core/finance/finance_math.dart';
import '../../core/formatting/money.dart';

/// Bordered surface card (16–20 px radius, no floating shadow).
class FinCard extends StatelessWidget {
  const FinCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.color});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Single-line SegmentedButton label: shrinks at large font scales instead of
/// wrapping mid-word ("Expens/e") inside the fixed-width segment.
class SegmentLabel extends StatelessWidget {
  const SegmentLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
}

/// Money amount in minor units of [currency] (rupiah by default). [colorize]
/// tints positive/negative, always with a sign so state is not conveyed by
/// color alone. [alertNegative] tints only a negative value red (balances,
/// net cash flow); expense amounts stay neutral.
class AmountText extends StatelessWidget {
  const AmountText(
    this.amount, {
    super.key,
    this.style,
    this.colorize = false,
    this.signed = false,
    this.alertNegative = false,
    this.currency = Currency.idr,
  });

  final int amount;
  final TextStyle? style;
  final bool colorize;
  final bool signed;
  final bool alertNegative;
  final Currency currency;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final color = colorize && amount != 0
        ? (amount > 0 ? fin.positive : fin.negative)
        : (alertNegative && amount < 0 ? fin.negative : null);
    return Text(
      formatMoney(amount, currency, signed: signed || colorize),
      style: (style ?? context.text.bodyMedium)!.copyWith(
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: context.text.titleMedium)),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: context.fin.muted, visualDensity: VisualDensity.compact),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.actionLabel, this.onAction});

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: fin.surface2, shape: BoxShape.circle),
            child: Icon(icon, color: fin.muted),
          ),
          const SizedBox(height: 14),
          Text(title, style: context.text.titleSmall, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: context.text.bodySmall, textAlign: TextAlign.center),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

/// Color + text label for a budget status (accessibility: never color only).
extension BudgetStatusStyle on BudgetStatus {
  /// Bar/graphic color.
  Color color(FinColors fin) => switch (this) {
    BudgetStatus.normal => fin.accent,
    BudgetStatus.attention => fin.accent,
    BudgetStatus.warning => fin.warning,
    BudgetStatus.reached => fin.warning,
    BudgetStatus.over => fin.negative,
  };

  /// Label color: like [color], but the accent swaps to its legible text tone.
  Color textColor(FinColors fin) => switch (this) {
    BudgetStatus.normal || BudgetStatus.attention => fin.accentText,
    _ => color(fin),
  };
}

/// Animated progress bar; [percent] may exceed 100 (bar is clamped). Accent
/// on an accent-tinted track by default (reference UI).
class FinProgressBar extends StatelessWidget {
  const FinProgressBar({super.key, required this.percent, this.color, this.height = 6});

  final double percent;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final v = (percent / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: v),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => LinearProgressIndicator(
          value: value,
          minHeight: height,
          backgroundColor: fin.accentSoft,
          color: color ?? fin.accent,
        ),
      ),
    );
  }
}

/// Brand F mark tinted to the current text color.
class FinBroMark extends StatelessWidget {
  const FinBroMark({super.key, this.size = 32, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/f_mark.png',
    width: size,
    height: size,
    color: color ?? context.fin.text,
    colorBlendMode: BlendMode.srcIn,
    semanticLabel: 'FinBro',
  );
}

class FinBroWordmark extends StatelessWidget {
  const FinBroWordmark({super.key, this.showDescriptor = true, this.markSize = 56});
  final bool showDescriptor;
  final double markSize;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FinBroMark(size: markSize),
      const SizedBox(height: 16),
      Text('FinBro', style: context.text.displaySmall),
      if (showDescriptor)
        Text('Finance Brother App', style: context.text.bodyMedium!.copyWith(color: context.fin.muted)),
    ],
  );
}

final _thousands = NumberFormat.decimalPattern('id_ID');

/// Formats digits as `1.250.000` while typing.
class RupiahInputFormatter extends TextInputFormatter {
  const RupiahInputFormatter({this.currency = Currency.idr});

  /// Currencies with a minor unit keep the user's separators ('.'/'*', last
  /// one wins as decimal mark via [parseMoney]) instead of regrouping to
  /// thousands while typing; IDR regroups exactly as before.
  final Currency currency;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (currency.decimals > 0) {
      final t = newValue.text.replaceAll(RegExp(r'[^\d.,]'), '');
      return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    }
    final v = parseRupiah(newValue.text);
    if (v == null) return const TextEditingValue();
    final text = _thousands.format(v);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Amount input in minor units of [currency] (rupiah by default). Read the
/// value with `parseMoney(controller.text, currency)`; for IDR this equals
/// `parseRupiah`. Currencies with a minor unit accept decimals (last
/// separator = decimal mark).
class MoneyField extends StatelessWidget {
  const MoneyField({
    super.key,
    required this.controller,
    this.label = 'Nominal',
    this.autofocus = false,
    this.large = false,
    this.validator,
    this.allowZero = false,
    this.currency = Currency.idr,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final bool large;
  final bool allowZero;
  final String? Function(int? value)? validator;
  final Currency currency;

  /// Field text for [amount] minor units of [currency]: `1.250.000` for
  /// IDR, `12,50` for USD (round-trips through [parseMoney]).
  static String textFor(int amount, [Currency currency = Currency.idr]) {
    if (currency.decimals == 0) return _thousands.format(amount);
    var divisor = 1;
    for (var i = 0; i < currency.decimals; i++) {
      divisor *= 10;
    }
    return NumberFormat('#,##0.${'0' * currency.decimals}', 'id_ID').format(amount / divisor);
  }

  /// Re-renders [controller]'s amount when the bound account switches from
  /// [from] to [to]: the typed nominal is kept when exactly representable
  /// in [to] (`12` → `12,00`; `12,50` USD → `12,50` EUR) and cleared
  /// otherwise (`12,50` USD → IDR), never silently rounded.
  static void switchCurrency(TextEditingController controller, Currency from, Currency to) {
    if (from == to) return;
    final minor = parseMoney(controller.text, from);
    if (minor == null) return;
    final scaled = rescaleMinor(minor, from, to);
    if (scaled == null) {
      controller.clear();
    } else {
      controller.text = textFor(scaled, to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = large ? context.text.headlineSmall : context.text.bodyLarge;
    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: currency.decimals > 0
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.number,
      inputFormatters: [RupiahInputFormatter(currency: currency)],
      style: style!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      decoration: InputDecoration(labelText: label, prefixText: '${currency.symbol} '),
      validator: (text) {
        final v = parseMoney(text ?? '', currency);
        if (validator != null) return validator!(v);
        if (v == null || (!allowZero && v <= 0)) return 'Masukkan nominal';
        return null;
      },
    );
  }
}

/// Standard loading/error rendering for AsyncValue.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.builder});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
    data: builder,
    loading: () => const Padding(
      padding: EdgeInsets.all(32),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    ),
    error: (e, _) => Padding(
      padding: const EdgeInsets.all(24),
      child: Text('Terjadi kesalahan: $e', style: TextStyle(color: context.fin.negative)),
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Ya',
  bool destructive = false,
}) async {
  final fin = context.fin;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: destructive ? fin.negative : fin.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Month switcher `‹ September 2026 ›` used by Budget/Reports/Calendar.
class MonthSwitcher extends StatelessWidget {
  const MonthSwitcher({super.key, required this.month, required this.onChanged, required this.label});
  final DateTime month;
  final String label;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Bulan sebelumnya',
        icon: const Icon(Icons.chevron_left),
        onPressed: () => onChanged(DateTime(month.year, month.month - 1)),
      ),
      Text(label, style: context.text.titleSmall),
      IconButton(
        tooltip: 'Bulan berikutnya',
        icon: const Icon(Icons.chevron_right),
        onPressed: () => onChanged(DateTime(month.year, month.month + 1)),
      ),
    ],
  );
}
