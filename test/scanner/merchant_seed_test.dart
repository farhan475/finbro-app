import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/features/scanner/data/merchant_mapping_repository.dart';
import 'package:finbro_app/features/scanner/domain/merchant_seed.dart';
import 'package:flutter_test/flutter_test.dart';

const _food = 'sys-expense-food';
const _transport = 'sys-expense-transport';
const _bills = 'sys-expense-bills';
const _shopping = 'sys-expense-shopping';
const _health = 'sys-expense-health';
const _subscription = 'sys-expense-subscription';
const _entertainment = 'sys-expense-entertainment';

void main() {
  group('seedMerchantFor', () {
    test('noisy OCR and bank text maps to the right merchant and category', () {
      const cases = {
        'INDOMARET JL SUDIRMAN 12': ('Indomaret', _shopping),
        'PT INDOMARCO PRIMA': ('Indomaret', _shopping),
        'INDOMARETJL.SUDIRMAN': ('Indomaret', _shopping),
        'IND0MARET': ('Indomaret', _shopping),
        'INDOMARFT CABANG 3': ('Indomaret', _shopping),
        'ALFAMART-ALFA': ('Alfamart', _shopping),
        'PT SUMBER ALFARIA TRIJAYA TBK': ('Alfamart', _shopping),
        'ALFA MIDI KEMANG': ('Alfamidi', _shopping),
        '** SUPER INDO **': ('Superindo', _shopping),
        'Circle K Kuningan': ('Circle K', _shopping),
        'KOPIKENANGAN - TEBET': ('Kopi Kenangan', _food),
        'TRSF E-BANKING DB 0210/FTSCY/WS95051 KOPI KENANGAN': ('Kopi Kenangan', _food),
        "McDonald's Kemang": ("McDonald's", _food),
        'J.CO DONUTS & COFFEE': ('J.CO', _food),
        'A&W RESTORAN': ('A&W', _food),
        'QRIS STARBUCKS GRAND INDONESIA': ('Starbucks', _food),
        'SPBU 34.123.45 PERTAMINA': ('Pertamina', _transport),
        '5HELL KUNINGAN': ('Shell', _transport),
        'BP AKR': ('BP', _transport),
        'PLN PASCABAYAR': ('PLN', _bills),
        'APOTEK K-24 CIPETE': ('K24', _health),
        'GOOGLE *YOUTUBEPREMIUM': ('YouTube Premium', _subscription),
        'APPLE.COM/BILL': ('iCloud', _subscription),
        'tiket.com': ('tiket.com', _transport),
        'CINEMA 21 PLAZA SENAYAN': ('Cinema XXI', _entertainment),
        'H&M PIM': ('H&M', _shopping),
      };
      for (final MapEntry(key: text, value: (name, category)) in cases.entries) {
        final m = seedMerchantFor(text);
        expect(m?.name, name, reason: text);
        expect(m?.categoryId, category, reason: text);
      }
    });

    test('short aliases match only as whole words', () {
      for (final text in [
        'XLARGE FASHION',
        'TRI JAYA MOTOR',
        'TRIBUN NEWS',
        'KAIZEN',
        'SHELLY BOUTIQUE',
        'MAXIMUS GYM',
        'CV AXISTA',
        'TOKO KENANGA',
        'CIRCLES',
        'INFORMATIKA',
        'MCDX',
      ]) {
        expect(seedMerchantFor(text), isNull, reason: text);
      }
      expect(seedMerchantFor('BPJS KESEHATAN')!.name, 'BPJS Kesehatan');
      expect(seedMerchantFor('PULSA XL 50RB')!.name, 'XL');
      expect(seedMerchantFor('PEMBELIAN PULSA TRI')!.name, 'Tri');
    });

    test('the longest, most specific alias wins', () {
      expect(seedMerchantFor('GRAB FOOD')!.name, 'GrabFood');
      expect(seedMerchantFor('GRAB')!.name, 'Grab');
      expect(seedMerchantFor('GOJEK GOFOOD')!.categoryId, _food);
      expect(seedMerchantFor('SHOPEE FOOD')!.name, 'ShopeeFood');
      expect(seedMerchantFor('BPJS TK')!.categoryId, _bills);
      expect(seedMerchantFor('KAI COMMUTER')!.name, 'KRL Commuter Line');
    });

    test('unknown or empty text has no seed merchant', () {
      expect(seedMerchantFor('Warung Bu Siti'), isNull);
      expect(seedMerchantFor('Zzyzx Corp'), isNull);
      expect(seedMerchantFor('  --  '), isNull);
      expect(seedMerchantFor(''), isNull);
    });
  });

  group('seed table', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    test('every category id is a seeded active expense category', () async {
      final expense = {
        for (final c in await db.select(db.categories).get())
          if (c.type == CategoryType.expense && c.isActive) c.id,
      };
      for (final m in seedMerchants) {
        expect(expense, contains(m.categoryId), reason: m.name);
      }
    });

    test('every alias resolves to its own merchant', () {
      for (final m in seedMerchants) {
        for (final a in m.aliases) {
          expect(seedMerchantFor(a)?.categoryId, m.categoryId, reason: '${m.name}: $a');
        }
      }
    });
  });

  group('MerchantMappingRepository.suggest with seed', () {
    late AppDatabase db;
    late MerchantMappingRepository mappings;
    setUp(() {
      db = AppDatabase.memory();
      mappings = MerchantMappingRepository(db);
    });
    tearDown(() => db.close());

    test('seed suggests when the user has no mapping', () async {
      final s = await mappings.suggest('INDOMARET JL SUDIRMAN 12', type: CategoryType.expense);
      expect(s!.source, SuggestionSource.seed);
      expect(s.categoryId, _shopping);
      expect(s.seedMerchant, 'Indomaret');
      expect(s.normalizedMerchant, isNull);
    });

    test('user mapping overrides the seed and is kept on later saves', () async {
      await mappings.remember(rawMerchant: 'INDOMARET', normalizedMerchant: 'Indomaret', categoryId: _food);
      final s = await mappings.suggest('indomaret', type: CategoryType.expense);
      expect(s!.source, SuggestionSource.mapping);
      expect(s.categoryId, _food);

      final other = await mappings.suggest('INDOMARET JL SUDIRMAN', type: CategoryType.expense);
      expect(other!.source, SuggestionSource.seed);
      expect(other.categoryId, _shopping);
    });

    test('seed fills in when the mapped category is archived, keeping the learned name', () async {
      await mappings.remember(rawMerchant: 'ALFAMART 123', normalizedMerchant: 'Alfamart Rumah', categoryId: _food);
      await (db.update(db.categories)..where((c) => c.id.equals(_food)))
          .write(const CategoriesCompanion(isActive: Value(false)));
      final s = await mappings.suggest('ALFAMART 123', type: CategoryType.expense);
      expect(s!.source, SuggestionSource.seed);
      expect(s.categoryId, _shopping);
      expect(s.normalizedMerchant, 'Alfamart Rumah');
    });

    test('archived seed category falls back to the keyword guess; income gets no seed', () async {
      await (db.update(db.categories)..where((c) => c.id.equals(_transport)))
          .write(const CategoriesCompanion(isActive: Value(false)));
      final s = await mappings.suggest('SHELL CAFE', type: CategoryType.expense);
      expect(s!.source, SuggestionSource.keyword);
      expect(s.categoryId, _food);
      expect(await mappings.suggest('PERTAMINA', type: CategoryType.expense), isNull);
      expect(await mappings.suggest('KFC', type: CategoryType.income), isNull);
    });
  });
}
