import 'dart:typed_data';

import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/features/statement_import/presentation/statement_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Uint8List csv(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  late AppDatabase db;
  late Account account;

  setUpAll(() => initializeDateFormatting('id_ID'));

  setUp(() async {
    db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime(2026, 10, 2, 10);
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: 'acc-bank', name: 'BCA', type: AccountType.bank, createdAt: now, updatedAt: now,
    ));
    account = (await (db.select(db.accounts)..limit(1)).get()).single;
  });

  Future<void> pumpReview(WidgetTester tester, Uint8List bytes) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: StatementImportReviewScreen(account: account, bytes: bytes),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
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

  testWidgets('review screen shows parsed rows, summary and commit button', (tester) async {
    await pumpReview(tester, csv('''
"02/09","TRANSFER KE KOPI KENANGAN","KCU JAKARTA","50,000.00 DB","1,950,000.00"
"03/09","TRANSFER DARI PT MAJU","KCU JAKARTA","2,000,000.00 CR","3,950,000.00"
'''));

    expect(find.textContaining('TRANSFER KE KOPI KENANGAN'), findsOneWidget);
    expect(find.textContaining('TRANSFER DARI PT MAJU'), findsOneWidget);
    expect(find.textContaining('2 baris terbaca'), findsOneWidget);
    expect(find.textContaining('Impor 2 transaksi'), findsOneWidget);
    expect(find.textContaining('Kemungkinan duplikat'), findsNothing);
    expect(find.text('-Rp 50.000'), findsOneWidget);
    expect(find.text('+Rp 2.000.000'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('tapping a row excludes it and the button count follows', (tester) async {
    await pumpReview(tester, csv('''
"02/09","TRANSFER KE KOPI KENANGAN","KCU JAKARTA","50,000.00 DB","1,950,000.00"
"03/09","TRANSFER DARI PT MAJU","KCU JAKARTA","2,000,000.00 CR","3,950,000.00"
'''));

    await tester.tap(find.textContaining('TRANSFER KE KOPI KENANGAN').first);
    await tester.pump();
    expect(find.textContaining('Impor 1 transaksi'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('with several accounts the file buttons wait for the chosen target account', (tester) async {
    final now = DateTime(2026, 10, 2, 10);
    await db.into(db.accounts).insert(AccountsCompanion.insert(
      id: 'acc-mandiri', name: 'Mandiri', type: AccountType.bank, createdAt: now, updatedAt: now,
    ));
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const StatementImportEntryScreen()),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    bool enabled(String label) =>
        tester.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>())).enabled;

    // Before: both buttons were live and called accounts.single → StateError.
    expect(enabled('Pilih file CSV'), isFalse);
    expect(enabled('Pilih file PDF mutasi'), isFalse);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mandiri').last);
    await tester.pumpAndSettle();

    expect(enabled('Pilih file CSV'), isTrue);
    expect(enabled('Pilih file PDF mutasi'), isTrue);
    await unmount(tester);
  });
}
