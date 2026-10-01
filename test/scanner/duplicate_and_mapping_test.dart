import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/database/seed.dart';
import 'package:finbro_app/core/ledger/ledger_service.dart';
import 'package:finbro_app/features/scanner/data/merchant_mapping_repository.dart';
import 'package:finbro_app/features/scanner/domain/duplicate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late DuplicateDetector detector;
  late MerchantMappingRepository mappings;
  final now = DateTime(2026, 9, 15, 12);
  const acc = 'acc-main';

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerService(db);
    detector = DuplicateDetector(db);
    mappings = MerchantMappingRepository(db);
    await db.into(db.accounts).insert(
      AccountsCompanion.insert(
        id: acc,
        name: 'BCA',
        type: AccountType.bank,
        openingBalance: const Value(5000000),
        createdAt: now,
        updatedAt: now,
      ),
    );
  });
  tearDown(() => db.close());

  Future<String> expense(
    int amount,
    DateTime at, {
    String category = SystemCategories.food,
    String? note,
    String? hash,
    TransactionStatus status = TransactionStatus.confirmed,
  }) => ledger.create(
    TransactionDraft(
      type: TransactionType.expense,
      amount: amount,
      accountId: acc,
      categoryId: category,
      transactionAt: at,
      note: note,
      attachments: [
        if (hash != null)
          AttachmentDraft(localPath: '/tmp/x.jpg', mimeType: 'image/jpeg', kind: AttachmentKind.receipt, imageHash: hash),
      ],
    ),
    status: status,
  );

  group('DuplicateDetector', () {
    test('same amount + similar merchant within ±2 days', () async {
      final id = await expense(35000, DateTime(2026, 9, 13, 20), note: 'Kopi Kenangan Tebet',
          category: SystemCategories.otherExpense);
      final found = await detector.find(
        amount: 35000,
        transactionAt: DateTime(2026, 9, 15, 8),
        merchant: 'KOPI KENANGAN',
        categoryId: SystemCategories.food,
      );
      expect(found.map((c) => c.transaction.id), [id]);
      expect(found.single.reasons, {DuplicateReason.sameMerchant});
    });

    test('same amount + same category within window', () async {
      final id = await expense(50000, DateTime(2026, 9, 17, 9));
      final found = await detector.find(
        amount: 50000,
        transactionAt: DateTime(2026, 9, 15),
        merchant: 'Warung Baru',
        categoryId: SystemCategories.food,
      );
      expect(found.single.transaction.id, id);
      expect(found.single.reasons, {DuplicateReason.sameCategory});
    });

    test('outside the window, different amount, or unrelated merchant/category is not a duplicate',
        () async {
      await expense(50000, DateTime(2026, 9, 12, 23, 59)); // 3 days before
      await expense(50000, DateTime(2026, 9, 18)); // 3 days after
      await expense(51000, DateTime(2026, 9, 15)); // other amount
      await expense(50000, DateTime(2026, 9, 15), category: 'sys-expense-transport', note: 'Parkir');
      final found = await detector.find(
        amount: 50000,
        transactionAt: DateTime(2026, 9, 15, 10),
        merchant: 'Soto Pak Di',
        categoryId: SystemCategories.food,
      );
      expect(found, isEmpty);
    });

    test('same image hash is a duplicate regardless of amount/date', () async {
      final id = await expense(10000, DateTime(2026, 1, 1), hash: 'abc123', category: 'sys-expense-bills');
      final found = await detector.find(
        amount: 99000,
        transactionAt: now,
        imageHash: 'abc123',
      );
      expect(found.single.transaction.id, id);
      expect(found.single.reasons, {DuplicateReason.sameImage});
    });

    test('voided rows are ignored', () async {
      final id = await expense(35000, now, hash: 'h1');
      await (db.update(db.transactions)..where((t) => t.id.equals(id)))
          .write(const TransactionsCompanion(status: Value(TransactionStatus.voided)));
      final found = await detector.find(
        amount: 35000,
        transactionAt: now,
        categoryId: SystemCategories.food,
        imageHash: 'h1',
      );
      expect(found, isEmpty);
    });

    test('several reasons on one row are merged', () async {
      await expense(35000, now, note: 'Indomaret', hash: 'h2');
      final found = await detector.find(
        amount: 35000,
        transactionAt: now,
        merchant: 'INDOMARET',
        categoryId: SystemCategories.food,
        imageHash: 'h2',
      );
      expect(found.single.reasons, DuplicateReason.values.toSet());
    });
  });

  group('MerchantMappingRepository', () {
    test('remember upserts by normalized raw key and suggest returns it', () async {
      await mappings.remember(
        rawMerchant: '  KOPI   KENANGAN  ',
        normalizedMerchant: 'Kopi Kenangan',
        categoryId: SystemCategories.food,
      );
      await mappings.remember(
        rawMerchant: 'kopi kenangan',
        normalizedMerchant: 'Kopi  Kenangan ',
        categoryId: 'sys-expense-shopping',
      );
      final rows = await db.select(db.merchantMappings).get();
      expect(rows, hasLength(1));
      expect(rows.single.rawMerchant, 'kopi kenangan');
      expect(rows.single.normalizedMerchant, 'Kopi Kenangan');

      final s = await mappings.suggest('Kopi Kenangan', type: CategoryType.expense);
      expect(s!.source, SuggestionSource.mapping);
      expect(s.categoryId, 'sys-expense-shopping');
      expect(s.normalizedMerchant, 'Kopi Kenangan');
    });

    test('mapping category of the wrong type or archived is not suggested', () async {
      await mappings.remember(rawMerchant: 'Kantor', normalizedMerchant: 'Kantor', categoryId: SystemCategories.food);
      final s = await mappings.suggest('KANTOR', type: CategoryType.income);
      expect(s!.categoryId, isNull);

      await (db.update(db.categories)..where((c) => c.id.equals(SystemCategories.food)))
          .write(const CategoriesCompanion(isActive: Value(false)));
      expect((await mappings.suggest('kantor', type: CategoryType.expense))!.categoryId, isNull);
    });

    test('keyword fallback without mapping', () async {
      final s = await mappings.suggest('APOTEK K24 CIPETE', type: CategoryType.expense);
      expect(s!.source, SuggestionSource.keyword);
      expect(s.categoryId, 'sys-expense-health');
      expect(await mappings.suggest('Zzyzx Corp', type: CategoryType.expense), isNull);
    });
  });
}
