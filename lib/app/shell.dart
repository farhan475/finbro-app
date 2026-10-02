import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme/app_theme.dart';

/// Bottom navigation: Home | Transaksi | Budget | Analitik | Lainnya (UI
/// reference). Goals live under Lainnya and the Home goals card.
///
/// The bar floats above the content as a frosted pill in the theme's own
/// surface tone (dark glass in dark mode, light glass in light mode). The
/// Scaffold extends the body behind it, so branch screens see the bar's
/// height in `MediaQuery.padding.bottom` and pad their lists with
/// [navBarClearance].
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: shell,
      bottomNavigationBar: _FloatingNavBar(
        selectedIndex: shell.currentIndex,
        onSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}

/// Bottom padding for a scrollable in a shell branch so its last item can
/// scroll clear of the floating bar (and the FAB above it when [fab]).
double navBarClearance(BuildContext context, {bool fab = false}) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  return bottom + (fab ? _navBarExtent + 96 : _navBarExtent + 16);
}

const double _navBarHeight = 68;
const double _navBarGap = 16;
const double _navBarSideInset = 18;

/// Visible height of the floating bar plus its gap to the system inset.
const double _navBarExtent = _navBarHeight + _navBarGap;

/// Lifts a branch screen's FAB above the floating bar. The inner Scaffold
/// positions its FAB from the system inset only, so it would otherwise sit
/// behind the bar.
class AboveNavBar extends StatelessWidget {
  const AboveNavBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: _navBarExtent), child: child);
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _radius = BorderRadius.all(Radius.circular(28));

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final systemBottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(_navBarSideInset, 0, _navBarSideInset, systemBottom + _navBarGap),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: _radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.45 : 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: _radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fin.surface.withValues(alpha: dark ? 0.56 : 0.64),
                borderRadius: _radius,
                border: Border.all(
                  color: dark ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.78),
                ),
              ),
              child: Row(
                children: [
                  _NavItem(index: 0, selected: selectedIndex == 0, icon: Icons.home_outlined, selectedIcon: Icons.home_rounded, label: 'Home', onTap: onSelected),
                  _NavItem(index: 1, selected: selectedIndex == 1, icon: Icons.receipt_long_outlined, selectedIcon: Icons.receipt_long, label: 'Transaksi', onTap: onSelected),
                  _NavItem(index: 2, selected: selectedIndex == 2, icon: Icons.account_balance_wallet_outlined, selectedIcon: Icons.account_balance_wallet, label: 'Budget', onTap: onSelected),
                  _NavItem(index: 3, selected: selectedIndex == 3, icon: Icons.bar_chart_outlined, selectedIcon: Icons.bar_chart_rounded, label: 'Analitik', onTap: onSelected),
                  _NavItem(index: 4, selected: selectedIndex == 4, icon: Icons.more_horiz, selectedIcon: Icons.more_horiz, label: 'Lainnya', onTap: onSelected),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.index, required this.selected, required this.icon, required this.selectedIcon, required this.label, required this.onTap});

  final int index;
  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    final color = selected ? fin.accentText : fin.muted;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onTap(index),
          child: SizedBox(
            height: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(selected ? selectedIcon : icon, color: color, size: 22),
                const SizedBox(height: 2),
                Text(label, style: context.text.labelSmall!.copyWith(color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
