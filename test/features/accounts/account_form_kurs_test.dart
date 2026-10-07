import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/features/accounts/presentation/account_form_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The kurs field doubles as the rate editor and is saved for the selected
/// currency, so it must always show that currency's stored rate.
void main() {
  setUpAll(() => initializeDateFormatting('id_ID'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  String kurs(WidgetTester tester) =>
      tester.widget<TextField>(find.widgetWithText(TextField, 'Kurs (1 ${_code(tester)} = ... Rp)')).controller!.text;

  testWidgets('switching currency shows the stored kurs of the new currency', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase.memory(); // seeded: USD 16250, EUR 17250
    addTearDown(db.close);

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const AccountFormScreen()),
    ));
    await settle(tester);

    await tester.tap(find.text(r'$ USD'));
    await settle(tester);
    expect(kurs(tester), '16250');

    await tester.tap(find.text('€ EUR'));
    await settle(tester);
    expect(kurs(tester), '17250', reason: 'never carries the USD rate over to EUR');

    await tester.tap(find.text('Rp IDR'));
    await settle(tester);
    expect(find.textContaining('Kurs (1'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 1));
  });
}

String _code(WidgetTester tester) {
  final label = tester.widget<Text>(find.textContaining('Kurs (1 ')).data!;
  return RegExp(r'Kurs \(1 (\w+)').firstMatch(label)!.group(1)!;
}
