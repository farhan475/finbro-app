import 'package:finbro_app/app/router.dart';
import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/dashboard/presentation/home_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The floating navbar overlays the shell branches; every branch FAB must sit
/// fully above it (tappable, not hidden behind the glass), and the list must
/// scroll its last row clear of the FAB.
void main() {
  setUpAll(() => initializeDateFormatting('id_ID'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Rect navBarRect(WidgetTester tester) =>
      tester.getRect(find.ancestor(of: find.text('Lainnya'), matching: find.byType(BackdropFilter)).first);

  void expectFabAboveNavBar(WidgetTester tester, String tooltip) {
    final fab = tester.getRect(find.byTooltip(tooltip).first);
    final bar = navBarRect(tester);
    expect(fab.bottom, lessThanOrEqualTo(bar.top - 8), reason: '$tooltip FAB $fab overlaps navbar $bar');
    // A tap at the FAB's lower edge must reach the FAB, not the navbar.
    final hit = tester.hitTestOnBinding(Offset(fab.center.dx, fab.bottom - 2));
    final fabElement = tester.renderObject(find.byType(FloatingActionButton).first);
    expect(hit.path.any((e) => e.target == fabElement), isTrue);
  }

  for (final bottomInset in [0.0, 34.0]) {
    testWidgets('Home and Transaksi FABs sit above the floating navbar (system inset $bottomInset)', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      tester.view.padding = FakeViewPadding(bottom: bottomInset * 2.75, top: 24 * 2.75);
      tester.view.viewPadding = FakeViewPadding(bottom: bottomInset * 2.75, top: 24 * 2.75);
      addTearDown(tester.view.reset);

      final db = AppDatabase.memory();
      addTearDown(db.close);
      await tester.runAsync(() => AppSettingsRepository(db).setBool(SettingKeys.onboardingDone, true));

      final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: container.read(routerProvider)),
      ));
      await settle(tester);

      expectFabAboveNavBar(tester, 'Tambah transaksi');

      // Home list: scrolled to the end, its last row ends above the FAB.
      final homeList = find.byType(Scrollable).first;
      await tester.drag(homeList, const Offset(0, -20000));
      await settle(tester);
      final lastSection = tester.getRect(find.byType(RecentTransactionsCard));
      final fab = tester.getRect(find.byTooltip('Tambah transaksi').first);
      expect(lastSection.bottom, lessThan(fab.top));

      await tester.tap(find.text('Transaksi').last);
      await settle(tester);
      expectFabAboveNavBar(tester, 'Tambah transaksi');

      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
