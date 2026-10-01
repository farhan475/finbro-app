import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/seed.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/providers.dart';

final planningRepositoryProvider = Provider<PlanningRepository>(
  (ref) => PlanningRepository(ref.watch(databaseProvider)),
);

/// The single planning_settings row, recomputed after every commit.
final planningSettingsProvider = FutureProvider<PlanningSetting>((ref) {
  ref.watch(dbChangesProvider);
  return ref.watch(financeServiceProvider).planningSettings();
});

/// Confirmed income of the current month (allocation proposal source).
final currentMonthIncomeProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  return (await ref.watch(financeServiceProvider).summary(Period.month(now))).income;
});

/// §4 Available to Spend breakdown for today (uses saved settings).
final availableBreakdownProvider = FutureProvider.autoDispose<AvailableToSpend>((ref) {
  ref.watch(dbChangesProvider);
  final now = ref.watch(clockProvider)();
  return ref.watch(financeServiceProvider).availableToSpendBreakdown(now);
});

/// Allowed emergency lookback windows (03 §14).
const emergencyLookbackOptions = [3, 6, 12];

extension PlanningSettingPlan on PlanningSetting {
  AllocationPlan get plan => AllocationPlan(
    essential: essentialPercent,
    family: familyPercent,
    emergency: emergencyPercent,
    savings: savingsPercent,
    development: developmentPercent,
    personal: personalPercent,
    flexibleResidual: flexibleResidualMode,
  );
}

class PlanningRepository {
  PlanningRepository(this.db);
  final AppDatabase db;

  /// Validates and saves every editable planning field. Throws
  /// [LedgerValidationException] with a user-facing message when invalid.
  Future<void> save({
    required AllocationPlan plan,
    required int targetEmergencyMonths,
    required int emergencyLookbackMonths,
    required int minimumCashBuffer,
    required int userReserve,
  }) async {
    final planError = plan.validate();
    if (planError != null) throw LedgerValidationException(planError);
    if (targetEmergencyMonths < 1 || targetEmergencyMonths > 12) {
      throw const LedgerValidationException('Target Emergency Fund harus 1–12 bulan.');
    }
    if (!emergencyLookbackOptions.contains(emergencyLookbackMonths)) {
      throw const LedgerValidationException('Periode rata-rata harus 3, 6, atau 12 bulan.');
    }
    if (minimumCashBuffer < 0 || userReserve < 0) {
      throw const LedgerValidationException('Nominal tidak boleh negatif.');
    }
    await (db.update(db.planningSettings)..where((s) => s.id.equals(planningSettingsId))).write(
      PlanningSettingsCompanion(
        essentialPercent: Value(plan.essential),
        familyPercent: Value(plan.family),
        emergencyPercent: Value(plan.emergency),
        savingsPercent: Value(plan.savings),
        developmentPercent: Value(plan.development),
        personalPercent: Value(plan.personal),
        flexibleResidualMode: Value(plan.flexibleResidual),
        targetEmergencyMonths: Value(targetEmergencyMonths),
        emergencyLookbackMonths: Value(emergencyLookbackMonths),
        minimumCashBuffer: Value(minimumCashBuffer),
        userReserve: Value(userReserve),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
