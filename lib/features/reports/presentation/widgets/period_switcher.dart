import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';

/// `‹ September 2026 ›` switcher; [onNext] null disables moving forward
/// (no future periods with no data).
class PeriodSwitcher extends StatelessWidget {
  const PeriodSwitcher({super.key, required this.label, required this.onPrevious, required this.onNext});

  final String label;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(tooltip: 'Periode sebelumnya', icon: const Icon(Icons.chevron_left), onPressed: onPrevious),
      Flexible(
        child: Text(label, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      IconButton(tooltip: 'Periode berikutnya', icon: const Icon(Icons.chevron_right), onPressed: onNext),
    ],
  );
}
