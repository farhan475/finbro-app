import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/features/accounts/data/account_repository.dart';
import 'package:finbro_app/features/transactions/presentation/transaction_form_screen.dart';
import 'package:finbro_app/shared/widgets/transaction_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late String accountId;

  setUpAll(() => initializeDateFormatting('id_ID'));

  Future<void> pumpForm(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light),
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const TransactionFormScreen()),
              GoRoute(path: '/:any', builder: (_, _) => const SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
    // Drift streams resolve on real async, not on the fake clock.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  /// Disposes the tree and lets Drift's stream cleanup timers fire.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 1));
  }

  setUp(() async {
    db = AppDatabase.memory();
    accountId = await AccountRepository(db).create(
      name: 'BCA',
      type: AccountType.bank,
      openingBalance: 1000000,
    );
  });
  tearDown(() => db.close());

  testWidgets('saving without an amount is rejected and writes nothing', (tester) async {
    await pumpForm(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Simpan'));
    await tester.pump();

    expect(find.text('Masukkan nominal lebih dari 0'), findsOneWidget);
    final rows = await tester.runAsync(() => db.select(db.transactions).get());
    expect(rows, isEmpty);
    await unmount(tester);
  });

  testWidgets('amount + category saves one confirmed expense on the account', (tester) async {
    await pumpForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '25000');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Food'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Simpan'));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    final rows = await tester.runAsync(() => db.select(db.transactions).get());
    expect(rows, hasLength(1));
    expect(rows!.single.amount, 25000);
    expect(rows.single.type, TransactionType.expense);
    expect(rows.single.accountId, accountId);
    expect(rows.single.categoryId, SystemCategories.food);
    await unmount(tester);
  });

  group('non-IDR account', () {
    late String usdId;

    setUp(() async {
      usdId = await AccountRepository(db).create(
        name: 'Dollar',
        type: AccountType.bank,
        openingBalance: 0,
        currency: Currency.usd,
      );
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    testWidgets('"12,50" on a USD account is stored as 1250 cents and shown as \$12,50', (tester) async {
      await pumpForm(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Dollar'));
      await tester.pump();
      expect(find.text('\$ '), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '12,50');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Food'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Simpan'));
      await settle(tester);

      final rows = await tester.runAsync(() => db.select(db.transactions).get());
      expect(rows, hasLength(1));
      expect(rows!.single.amount, 1250);
      expect(rows.single.accountId, usdId);
      await unmount(tester);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(body: TransactionTile(rows.single)),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('-\$12,50'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('switching account keeps an exact amount and clears one that would round', (tester) async {
      await pumpForm(tester);
      final amountField = find.byType(TextFormField).first;
      String amountText() => tester.widget<TextFormField>(amountField).controller!.text;

      await tester.tap(find.widgetWithText(ChoiceChip, 'Dollar'));
      await tester.pump();
      await tester.enterText(amountField, '12');
      await tester.tap(find.widgetWithText(ChoiceChip, 'BCA'));
      await tester.pump();
      expect(amountText(), '12');

      await tester.tap(find.widgetWithText(ChoiceChip, 'Dollar'));
      await tester.pump();
      expect(amountText(), '12,00');
      await tester.enterText(amountField, '12,50');
      await tester.tap(find.widgetWithText(ChoiceChip, 'BCA'));
      await tester.pump();
      expect(amountText(), isEmpty);
      await unmount(tester);
    });
  });
}
