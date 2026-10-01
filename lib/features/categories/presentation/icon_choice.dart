import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// Selectable icon square for icon pickers (categories, accounts).
/// Selection is shown by fill *and* a check mark, not color alone.
class IconChoice extends StatelessWidget {
  const IconChoice({super.key, required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: selected ? fin.primary : fin.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? fin.primary : fin.border),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: selected ? fin.onPrimary : fin.text),
                if (selected) Positioned(right: 4, top: 4, child: Icon(Icons.check, size: 12, color: fin.onPrimary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
