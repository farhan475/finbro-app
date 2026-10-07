import 'dart:async';
import 'dart:io';

import 'package:finbro_app/core/background/external_writes.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late AppDatabase app;
  late AppDatabase background;
  final now = DateTime(2026, 9, 30, 10);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('finbro-external-writes-test-');
    final file = File(p.join(tmp.path, 'finbro.sqlite'));
    app = AppDatabase.open(file);
    await app.select(app.accounts).get(); // creates the file
    background = AppDatabase.open(file);
  });

  tearDown(() async {
    await app.close();
    await background.close();
    await tmp.delete(recursive: true);
  });

  test('stream queries pick up commits of another connection on check', () async {
    final writes = ExternalWrites(app);
    final accounts = StreamIterator(app.select(app.accounts).watch());
    expect(await accounts.moveNext(), isTrue);
    expect(accounts.current, isEmpty);
    await writes.check(now);

    final t = DateTime(2026, 9, 30);
    await background.into(background.accounts).insert(
      AccountsCompanion.insert(id: 'acc-bca', name: 'BCA', type: AccountType.bank, createdAt: t, updatedAt: t),
    );
    await writes.check(now);

    expect(await accounts.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(accounts.current.map((a) => a.name), ['BCA']);
    await accounts.cancel();
  });
}
