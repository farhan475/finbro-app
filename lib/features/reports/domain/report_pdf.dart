// Monthly/yearly PDF report (09-security-backup §7). Pure rendering: the
// caller supplies data and fonts, so it runs offline and in tests.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/enums.dart';
import '../../../core/finance/finance_math.dart';
import '../../../core/finance/finance_service.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import 'health_metrics.dart';
import 'report_shaping.dart';

/// One row of the top-transactions table.
class PdfTransactionRow {
  const PdfTransactionRow({
    required this.at,
    required this.category,
    required this.note,
    required this.amount,
    this.currency = Currency.idr,
  });
  final DateTime at;
  final String category;
  final String? note;

  /// Minor units of [currency] (the transaction's account currency).
  final int amount;
  final Currency currency;
}

class ReportPdfData {
  const ReportPdfData({
    required this.title,
    required this.scope,
    required this.generatedAt,
    required this.comparisonLabel,
    required this.current,
    required this.previous,
    required this.savingsRate,
    required this.previousSavingsRate,
    required this.trend,
    required this.categories,
    required this.topTransactions,
    required this.budgets,
    required this.health,
  });

  /// `September 2026` or `2026`.
  final String title;
  final ReportScope scope;
  final DateTime generatedAt;

  /// e.g. `vs Agustus 2026`.
  final String comparisonLabel;
  final PeriodSummary current;
  final PeriodSummary previous;
  final double? savingsRate;
  final double? previousSavingsRate;
  final List<MonthPoint> trend;
  final List<CategoryAmount> categories;
  final List<PdfTransactionRow> topTransactions;

  /// Monthly scope only; empty for yearly.
  final List<BudgetUsageItem> budgets;

  /// Monthly scope only; empty for yearly.
  final List<HealthMetric> health;
}

const _ink = PdfColor.fromInt(0xFF111111);
const _muted = PdfColor.fromInt(0xFF667085);
const _border = PdfColor.fromInt(0xFFE5E7EB);
const _surface = PdfColor.fromInt(0xFFF7F8FA);

/// File name: `finbro-laporan-2026-09.pdf` / `finbro-laporan-2026.pdf`.
String reportPdfFileName(ReportScope scope, DateTime anchor) => scope == ReportScope.monthly
    ? 'finbro-laporan-${anchor.year}-${anchor.month.toString().padLeft(2, '0')}.pdf'
    : 'finbro-laporan-${anchor.year}.pdf';

Future<Uint8List> buildReportPdf(ReportPdfData d, {required pw.Font regular, required pw.Font bold}) {
  final doc = pw.Document(
    title: 'FinBro — Laporan ${d.title}',
    author: 'FinBro',
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
  final small = pw.TextStyle(fontSize: 8, color: _muted);
  final body = const pw.TextStyle(fontSize: 9.5, color: _ink);
  final heading = pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, color: _ink);

  // Each section is short enough for one page; keep its heading with its body.
  pw.Widget section(String title, List<pw.Widget> children) => pw.Inseparable(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 16),
        pw.Text(title, style: heading),
        pw.SizedBox(height: 6),
        ...children,
      ],
    ),
  );

  pw.Widget table(List<String> headers, List<List<String>> rows, {Set<int> right = const {}, Map<int, double>? flex}) =>
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        border: null,
        headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _ink),
        headerDecoration: const pw.BoxDecoration(color: _surface),
        cellStyle: body,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        rowDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _border, width: 0.5))),
        cellAlignments: {for (final i in right) i: pw.Alignment.centerRight},
        headerAlignments: {for (final i in right) i: pw.Alignment.centerRight},
        columnWidths: flex == null ? null : {for (final e in flex.entries) e.key: pw.FlexColumnWidth(e.value)},
      );

  pw.Widget empty(String text) => pw.Text(text, style: small);

  final summaryRows = [
    ['Total Income', formatRupiah(d.current.income), formatRupiah(d.previous.income),
      formatChange(percentChange(d.current.income, d.previous.income))],
    ['Total Expense', formatRupiah(d.current.expense), formatRupiah(d.previous.expense),
      formatChange(percentChange(d.current.expense, d.previous.expense))],
    ['Net Cash Flow', formatRupiah(d.current.netCashFlow), formatRupiah(d.previous.netCashFlow),
      formatRupiah(d.current.netCashFlow - d.previous.netCashFlow, signed: true)],
    ['Savings Rate', formatPercent(d.savingsRate, decimals: 1), formatPercent(d.previousSavingsRate, decimals: 1),
      formatPointChange(d.savingsRate, d.previousSavingsRate)],
  ];

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
      header: (ctx) => ctx.pageNumber == 1
          ? pw.SizedBox()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text('FinBro · Laporan ${d.title}', style: small),
            ),
      footer: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 8),
        decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _border, width: 0.5))),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Dibuat offline oleh FinBro · ${formatDay(d.generatedAt)} ${formatTime(d.generatedAt)}', style: small),
            pw.Text('Halaman ${ctx.pageNumber}/${ctx.pagesCount}', style: small),
          ],
        ),
      ),
      build: (ctx) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('FinBro', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _ink)),
                pw.Text('Finance Brother App', style: small),
              ],
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('Laporan ${d.scope == ReportScope.monthly ? 'Bulanan' : 'Tahunan'}', style: small),
                pw.Text(d.title, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _ink)),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Divider(color: _ink, thickness: 1),
        section('Ringkasan', [
          table(
            ['Metric', d.title, d.comparisonLabel.replaceFirst('vs ', ''), 'Perubahan'],
            summaryRows,
            right: {1, 2, 3},
            flex: {0: 1.4, 1: 1.2, 2: 1.2, 3: 1},
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Transfer antar account tidak dihitung sebagai income/expense. Persentase N/A bila periode pembanding bernilai 0.',
            style: small,
          ),
        ]),
        section(d.scope == ReportScope.monthly ? 'Tren 6 bulan' : 'Tren bulanan ${d.title}', [
          table(
            ['Bulan', 'Income', 'Expense', 'Net'],
            [
              for (final p in d.trend)
                [formatMonth(p.month), formatRupiah(p.income), formatRupiah(p.expense), formatRupiah(p.net, signed: true)],
            ],
            right: {1, 2, 3},
          ),
        ]),
        section('Spending per kategori', [
          if (d.categories.isEmpty)
            empty('Belum ada expense pada periode ini.')
          else
            table(
              ['#', 'Kategori', 'Jumlah', 'Porsi'],
              [
                for (final (i, c) in d.categories.indexed)
                  ['${i + 1}', c.name, formatRupiah(c.amount), formatPercent(c.share, decimals: 1)],
              ],
              right: {2, 3},
              flex: {0: 0.3, 1: 2, 2: 1.3, 3: 0.8},
            ),
        ]),
        section('Transaksi expense terbesar', [
          if (d.topTransactions.isEmpty)
            empty('Belum ada expense pada periode ini.')
          else
            table(
              ['Tanggal', 'Kategori', 'Catatan', 'Jumlah'],
              [
                for (final t in d.topTransactions)
                  [formatDay(t.at), t.category, t.note ?? '-', formatMoney(t.amount, t.currency)],
              ],
              right: {3},
              flex: {0: 1, 1: 1, 2: 1.8, 3: 1.1},
            ),
        ]),
        if (d.scope == ReportScope.monthly)
          section('Budget vs Actual', [
            if (d.budgets.isEmpty)
              empty('Belum ada budget aktif pada bulan ini.')
            else
              table(
                ['Kategori', 'Budget', 'Actual', 'Pemakaian', 'Sisa', 'Status'],
                [
                  for (final b in d.budgets)
                    [
                      b.category.name,
                      formatRupiah(b.budget.amount),
                      formatRupiah(b.actual),
                      formatPercent(b.usage),
                      formatRupiah(b.variance),
                      b.status.label,
                    ],
                ],
                right: {1, 2, 3, 4},
                flex: {0: 1.2, 1: 1.1, 2: 1.1, 3: 0.8, 4: 1.1, 5: 1},
              ),
          ]),
        if (d.health.isNotEmpty)
          section('Financial Health', [
            for (final m in d.health)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(vertical: 5),
                decoration: const pw.BoxDecoration(
                  border: pw.Border(bottom: pw.BorderSide(color: _border, width: 0.5)),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(m.title, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                        pw.Text(m.value, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                      ],
                    ),
                    pw.Text(
                      [m.benchmark, ?m.comparison, ?m.detail].join(' · '),
                      style: const pw.TextStyle(fontSize: 8.5, color: _ink),
                    ),
                    pw.Text(m.source, style: small),
                  ],
                ),
              ),
            pw.SizedBox(height: 4),
            pw.Text('Tanpa skor tunggal: setiap metric menampilkan nilai, acuan, dan sumber datanya.', style: small),
          ]),
      ],
    ),
  );
  return doc.save();
}
