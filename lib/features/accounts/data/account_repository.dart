import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/ids.dart';

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(ref.watch(databaseProvider)),
);

/// Calculated balance per account (03 §2), recomputed after every commit.
/// The argument is `includeArchived`.
final accountBalancesProvider = FutureProvider.family<List<AccountBalance>, bool>((ref, includeArchived) {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).accountBalances(includeArchived: includeArchived);
});

/// Single account row (active or archived); null once deleted.
final accountByIdProvider = StreamProvider.autoDispose.family<Account?, String>((ref, id) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.accounts)..where((a) => a.id.equals(id))).watchSingleOrNull();
});

/// How often an account is referenced; decides archive vs delete (FR-ACC-003).
final accountUsageProvider = FutureProvider.autoDispose.family<AccountUsage, String>((ref, id) {
  ref.watch(dbChangesProvider);
  return ref.watch(accountRepositoryProvider).usage(id);
});

/// Rule violation the user can fix; show [message] as-is.
class AccountException implements Exception {
  const AccountException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AccountUsage {
  const AccountUsage({required this.transactions, required this.recurringRules});

  /// Transactions of any status where the account is source or destination.
  final int transactions;
  final int recurringRules;

  bool get canDelete => transactions == 0 && recurringRules == 0;
}

/// Account CRUD. Balances are never stored here: they are replayed from
/// transactions by FinanceService.
class AccountRepository {
  AccountRepository(this.db);

  final AppDatabase db;

  static const maxNameLength = 60;

  Future<String> create({
    required String name,
    required AccountType type,
    required int openingBalance,
    String? icon,
    Currency currency = Currency.idr,
  }) async {
    final id = newId();
    await db.transaction(() async {
      final clean = await _validName(name);
      final now = DateTime.now();
      await db.into(db.accounts).insert(
        AccountsCompanion.insert(
          id: id,
          name: clean,
          type: type,
          icon: Value(_cleanIcon(icon)),
          openingBalance: Value(openingBalance),
          currency: Value(currency.code),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
    return id;
  }

  Future<void> update(
    String id, {
    required String name,
    required AccountType type,
    required int openingBalance,
    String? icon,
    Currency currency = Currency.idr,
  }) async {
    await db.transaction(() async {
      await _get(id);
      final clean = await _validName(name, exceptId: id);
      await (db.update(db.accounts)..where((a) => a.id.equals(id))).write(
        AccountsCompanion(
          name: Value(clean),
          type: Value(type),
          icon: Value(_cleanIcon(icon)),
          openingBalance: Value(openingBalance),
          currency: Value(currency.code),
          updatedAt: Value(DateTime.now()),
        ),
      );
    });
  }

  /// Archived accounts keep their history but accept no new postings.
  Future<void> archive(String id) => _setActive(id, false);

  Future<void> unarchive(String id) => _setActive(id, true);

  Future<AccountUsage> usage(String id) async {
    final txCount = db.transactions.id.count();
    final transactions = await (db.selectOnly(db.transactions)
          ..addColumns([txCount])
          ..where(db.transactions.accountId.equals(id) | db.transactions.transferToAccountId.equals(id)))
        .map((r) => r.read(txCount) ?? 0)
        .getSingle();
    final ruleCount = db.recurringRules.id.count();
    final rules = await (db.selectOnly(db.recurringRules)
          ..addColumns([ruleCount])
          ..where(db.recurringRules.accountId.equals(id)))
        .map((r) => r.read(ruleCount) ?? 0)
        .getSingle();
    return AccountUsage(transactions: transactions, recurringRules: rules);
  }

  /// Hard delete, allowed only for accounts without any history
  /// (FR-ACC-003); otherwise the account must be archived.
  Future<void> delete(String id) async {
    await db.transaction(() async {
      await _get(id);
      final u = await usage(id);
      if (u.transactions > 0) {
        throw const AccountException(
          'Account ini punya riwayat transaksi dan tidak bisa dihapus. Arsipkan saja.',
        );
      }
      if (u.recurringRules > 0) {
        throw const AccountException(
          'Account ini dipakai oleh transaksi berulang. Hapus atau ubah aturan tersebut dulu.',
        );
      }
      await (db.delete(db.accounts)..where((a) => a.id.equals(id))).go();
    });
  }

  Future<Account> _get(String id) async {
    final a = await (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingleOrNull();
    if (a == null) throw const AccountException('Account tidak ditemukan.');
    return a;
  }

  Future<void> _setActive(String id, bool active) async {
    await _get(id);
    await (db.update(db.accounts)..where((a) => a.id.equals(id))).write(
      AccountsCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())),
    );
  }

  Future<String> _validName(String name, {String? exceptId}) async {
    final clean = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) throw const AccountException('Nama account wajib diisi.');
    if (clean.length > maxNameLength) {
      throw const AccountException('Nama account maksimal $maxNameLength karakter.');
    }
    final q = db.select(db.accounts)..where((a) => a.name.lower().equals(clean.toLowerCase()));
    if (exceptId != null) q.where((a) => a.id.equals(exceptId).not());
    if ((await q.get()).isNotEmpty) {
      throw AccountException('Account "$clean" sudah ada.');
    }
    return clean;
  }

  static String? _cleanIcon(String? icon) {
    final t = icon?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
