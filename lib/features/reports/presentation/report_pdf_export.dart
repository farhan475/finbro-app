import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/providers/lookups.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../../backup/presentation/backup_screen.dart' show saveExternally;
import '../data/report_providers.dart';
import '../domain/health_metrics.dart';
import '../domain/report_pdf.dart';
import '../domain/report_shaping.dart';
import 'report_labels.dart';

/// Collects the report shown on screen for [query] into a PDF.
Future<ReportPdfData> loadReportPdfData(WidgetRef ref, ReportQuery query) async {
  final overview = await ref.read(reportOverviewProvider(query).future);
  final trend = await ref.read(reportTrendProvider(query).future);
  final monthly = query.scope == ReportScope.monthly;
  final budgets = monthly ? await ref.read(reportBudgetProvider(query.anchor).future) : null;
  final health = monthly ? await ref.read(healthDataProvider(query.anchor).future) : null;
  final categories = await ref.read(allCategoriesProvider.future);
  final names = {for (final c in categories) c.id: c.name};
  return ReportPdfData(
    title: periodTitle(query.scope, query.anchor),
    scope: query.scope,
    generatedAt: ref.read(clockProvider)(),
    comparisonLabel: comparisonCaption(overview.previousPeriod, query.scope, partial: overview.partial),
    current: overview.current,
    previous: overview.previous,
    savingsRate: overview.savingsRate,
    previousSavingsRate: overview.previousSavingsRate,
    trend: trend,
    categories: overview.categories,
    topTransactions: [
      for (final t in overview.topTransactions)
        PdfTransactionRow(at: t.transactionAt, category: names[t.categoryId] ?? '-', note: t.note, amount: t.amount),
    ],
    budgets: budgets ?? const [],
    health: health == null ? const [] : buildHealthMetrics(health.metrics, health.plan),
  );
}

Future<pw.Font> _font(String asset) async => pw.Font.ttf(await rootBundle.load(asset));

/// Builds the PDF for [query] and opens the system save dialog.
Future<void> exportReportPdf(BuildContext context, WidgetRef ref, ReportQuery query) async {
  try {
    final data = await loadReportPdfData(ref, query);
    final bytes = await buildReportPdf(
      data,
      regular: await _font('assets/fonts/Inter-Regular.ttf'),
      bold: await _font('assets/fonts/Inter-Bold.ttf'),
    );
    final name = reportPdfFileName(query.scope, query.anchor);
    final saved = await saveExternally(name, bytes, 'application/pdf');
    if (saved && context.mounted) showSnack(context, '$name disimpan.');
  } catch (e, s) {
    AppLogger.error('Export PDF gagal', e, s);
    if (context.mounted) showSnack(context, 'Export PDF gagal: $e');
  }
}
