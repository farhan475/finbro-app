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
double navBarClearance(BuildContext context, {bool fab = false}) =>
    MediaQuery.paddingOf(context).bottom + (fab ? 80 : 16);

const double _navBarHeight = 64;
const double _navBarGap = 12;

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
      padding: EdgeInsets.fromLTRB(16, 0, 16, systemBottom + _navBarGap),
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
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fin.surface.withValues(alpha: dark ? 0.72 : 0.78),
                borderRadius: _radius,
                border: Border.all(
                  color: dark ? Colors.white.withValues(alpha: 0.08) : fin.border.withValues(alpha: 0.9),
                ),
              ),
              // NavigationBar adds its own SafeArea; the outer Padding
              // already handles the system inset.
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: NavigationBar(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onSelected,
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
                    NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Transaksi'),
                    NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Budget'),
                    NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart_rounded), label: 'Analitik'),
                    NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Lainnya'),
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
