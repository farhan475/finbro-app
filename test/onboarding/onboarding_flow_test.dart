import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/core/settings/app_settings_repository.dart';
import 'package:finbro_app/features/onboarding/presentation/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  late AppDatabase db;

  setUpAll(() => initializeDateFormatting('id_ID'));
  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> tapNext(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(FilledButton, label));
    await settle(tester);
  }

  testWidgets('name and at least one account are required; finishing marks onboarding done', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light),
          routerConfig: GoRouter(
            initialLocation: '/onboarding',
            routes: [
              GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
              GoRoute(path: '/', builder: (_, _) => const Text('HOME')),
            ],
          ),
        ),
      ),
    );
    await settle(tester);

    await tapNext(tester, 'Mulai');

    // Name page: blocked until a name is typed.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Lanjut')).onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, 'Farhan');
    await tester.pump();
    await tapNext(tester, 'Lanjut');

    // Accounts page: blocked until one account exists.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Lanjut')).onPressed, isNull);
    await tester.tap(find.widgetWithText(ActionChip, 'BCA'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, 'Saldo awal'), '500000');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Tambah akun'));
    await settle(tester);
    await tapNext(tester, 'Lanjut');

    // Planning page: default allocation is valid (100%), continue to reminder, finish.
    await tapNext(tester, 'Lanjut');
    await tapNext(tester, 'Selesai');

    expect(find.text('HOME'), findsOneWidget);
    final accounts = await tester.runAsync(() => db.select(db.accounts).get());
    expect(accounts!.map((a) => a.name), ['BCA']);
    expect(accounts.single.openingBalance, 500000);
    final settings = await tester.runAsync(() => AppSettingsRepository(db).watchAll().first);
    expect(settings![SettingKeys.userName], 'Farhan');
    expect(settings[SettingKeys.onboardingDone], 'true');
    await unmount(tester);
  });
}
