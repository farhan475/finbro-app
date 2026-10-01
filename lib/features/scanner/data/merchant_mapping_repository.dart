import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/ids.dart';
import '../domain/merchant_text.dart';

enum SuggestionSource {
  /// Learned from an earlier confirmed scan (`merchant_mappings`).
  mapping('dari riwayat'),

  /// Offline keyword guess (e.g. "kopi" → Food).
  keyword('tebakan otomatis');

  const SuggestionSource(this.label);
  final String label;
}

class MerchantSuggestion {
  const MerchantSuggestion({this.normalizedMerchant, this.categoryId, required this.source});

  /// Clean merchant name learned earlier (mapping only).
  final String? normalizedMerchant;
  final String? categoryId;
  final SuggestionSource source;
}

/// `raw_merchant → normalized merchant → suggested category`
/// (07-ocr-screenshot §5). Raw keys are [merchantKey] (lower-case,
/// whitespace-collapsed).
class MerchantMappingRepository {
  const MerchantMappingRepository(this.db);
  final AppDatabase db;

  Future<MerchantMapping?> lookup(String rawMerchant) {
    final key = merchantKey(rawMerchant);
    if (key.isEmpty) return Future.value();
    return (db.select(db.merchantMappings)..where((m) => m.rawMerchant.equals(key))).getSingleOrNull();
  }

  /// Mapping first (its category only if still active and of [type]); else
  /// a keyword guess among active categories of [type]. Null when nothing
  /// is known.
  Future<MerchantSuggestion?> suggest(String rawMerchant, {required CategoryType type}) async {
    if (merchantKey(rawMerchant).isEmpty) return null;
    Future<bool> usable(String? id) async {
      if (id == null) return false;
      final c = await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingleOrNull();
      return c != null && c.isActive && c.type == type;
    }

    final mapping = await lookup(rawMerchant);
    if (mapping != null) {
      final ok = await usable(mapping.categoryId);
      return MerchantSuggestion(
        normalizedMerchant: mapping.normalizedMerchant,
        categoryId: ok ? mapping.categoryId : null,
        source: SuggestionSource.mapping,
      );
    }
    if (type != CategoryType.expense) return null;
    final guess = keywordCategoryFor(rawMerchant);
    if (!await usable(guess)) return null;
    return MerchantSuggestion(categoryId: guess, source: SuggestionSource.keyword);
  }

  /// Upserts the mapping for [rawMerchant] after the user confirmed a scan.
  Future<void> remember({
    required String rawMerchant,
    required String normalizedMerchant,
    String? categoryId,
  }) async {
    final key = merchantKey(rawMerchant);
    final normalized = normalizedMerchant.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (key.isEmpty || normalized.isEmpty) return;
    final now = DateTime.now();
    await db.transaction(() async {
      final existing = await lookup(key);
      if (existing == null) {
        await db.into(db.merchantMappings).insert(
          MerchantMappingsCompanion.insert(
            id: newId(),
            rawMerchant: key,
            normalizedMerchant: normalized,
            categoryId: Value(categoryId),
            createdAt: now,
            updatedAt: now,
          ),
        );
      } else {
        await (db.update(db.merchantMappings)..where((m) => m.id.equals(existing.id))).write(
          MerchantMappingsCompanion(
            normalizedMerchant: Value(normalized),
            categoryId: Value(categoryId),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }
}

final merchantMappingRepositoryProvider = Provider<MerchantMappingRepository>(
  (ref) => MerchantMappingRepository(ref.watch(databaseProvider)),
);
