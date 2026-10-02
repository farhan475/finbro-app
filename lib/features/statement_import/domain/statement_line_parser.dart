/// Line parser for statement text (PDF text layer or OCR of scanned pages).
///
/// A transaction starts with a date (`01/09`, `01/09/2026`, `01 Sep 2026`,
/// `PEND`), followed by the description and, at the end of the line, the
/// amount(s): mutation [CR/DB] [balance]. Lines without a date continue the
/// previous description (wrapped text, reference numbers). Opening/closing
/// balances are recorded; headers, totals and page footers are skipped.
library;

import 'bank_presets.dart';
import 'statement_models.dart';
import 'statement_text.dart';

/// Wrapped description lines kept per transaction; more than this is page
/// boilerplate after the last row.
const _maxContinuationLines = 4;

StatementParse parseStatementLines(List<String> rawLines, {required DateTime now, String? formatLabel}) {
  final lines = [for (final l in rawLines) l.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim()];
  final yearFor = inferYear(periodEnd: findPeriodEnd(lines), now: now);
  final drafts = <_LineDraft>[];
  _LineDraft? open;
  int? opening;
  int? closing;
  var skipped = 0;

  void close() {
    final d = open;
    open = null;
    if (d == null) return;
    if (d.amounts.isEmpty) {
      skipped++;
    } else {
      drafts.add(d);
    }
  }

  for (final line in lines) {
    if (line.isEmpty) continue;
    if (_isNoise(line)) {
      close();
      continue;
    }
    final pending = RegExp(r'^PEND(ING)?\b', caseSensitive: false).firstMatch(line);
    final date = pending == null ? parseLeadingDate(line, yearFor: yearFor) : null;
    if (date != null || pending != null) {
      var rest = line.substring(date?.length ?? pending!.end).trim();
      if (RegExp(r'^(-|–|s\.?\s?d\.?|sampai|hingga|to)\s*\d', caseSensitive: false).hasMatch(rest)) {
        close(); // Period line "01/09/2026 - 30/09/2026".
        continue;
      }
      // Value date column right after the posting date.
      final second = parseLeadingDate(rest, yearFor: yearFor);
      if (second != null) rest = rest.substring(second.length).trim();
      final tail = _splitTrailingAmounts(rest);
      final summary = summaryKind(tail.text);
      if (summary != null) {
        close();
        final v = tail.amounts.isEmpty ? null : tail.amounts.last.signedValue;
        if (summary == SummaryKind.opening) opening ??= v;
        if (summary == SummaryKind.closing) closing = v ?? closing;
        continue;
      }
      close();
      open = _LineDraft(
        date: date?.date,
        hasTime: date?.hasTime ?? false,
        pending: pending != null,
        description: [if (tail.text.isNotEmpty) tail.text],
        amounts: tail.amounts,
      );
      continue;
    }
    final tail = _splitTrailingAmounts(line);
    final summary = summaryKind(tail.text);
    if (summary != null) {
      close();
      final v = tail.amounts.isEmpty ? null : tail.amounts.last.signedValue;
      if (summary == SummaryKind.opening) opening ??= v;
      if (summary == SummaryKind.closing) closing = v ?? closing;
      continue;
    }
    final d = open;
    if (d == null) continue; // Preamble (account holder, address, period).
    if (d.continuations >= _maxContinuationLines) {
      close();
      continue;
    }
    d.continuations++;
    if (d.amounts.isEmpty && tail.amounts.isNotEmpty) d.amounts = tail.amounts;
    if (tail.text.isNotEmpty) d.description.add(tail.text);
  }
  close();

  final rows = _resolve(drafts, opening, now);
  if (rows.isEmpty) throw const StatementImportException(StatementErrors.noRows);
  final last = _lastBalance(rows);
  return StatementParse(
    rows: rows,
    formatLabel: formatLabel ?? detectPreset(const [], lines.take(40))?.name,
    openingBalance: opening,
    closingBalance: closing ?? last,
    skippedLines: skipped,
  );
}

class _LineDraft {
  _LineDraft({
    required this.date,
    required this.hasTime,
    required this.pending,
    required this.description,
    required this.amounts,
  });
  final DateTime? date;
  final bool hasTime;
  final bool pending;
  final List<String> description;
  List<_Money> amounts;
  int continuations = 0;
}

class _Money {
  const _Money(this.value, this.direction, {this.negative = false});
  final int value;
  final StatementDirection? direction;
  final bool negative;
  int get signedValue => negative ? -value : value;
}

const _headerWords = {
  'tanggal', 'tgl', 'date', 'keterangan', 'uraian', 'description', 'deskripsi', 'saldo', 'balance', 'debet',
  'debit', 'kredit', 'credit', 'mutasi', 'jumlah', 'amount', 'nominal', 'cabang', 'branch', 'transaksi',
  'transaction', 'remark', 'remarks', 'valuta', 'value', 'referensi', 'reference', 'teller', 'db/cr', 'cr/db',
};

final _footer = RegExp(
  r'^(halaman|hal|page)\s*:?\s*\d+(\s*(dari|of|/)\s*\d+)?$|^\d+\s*(dari|of|/)\s*\d+$|bersambung|continued|'
  r'^(dicetak|printed|tanggal cetak|print date)\b',
  caseSensitive: false,
);

/// Column headers, page numbers, "bersambung" markers.
bool _isNoise(String line) {
  if (_footer.hasMatch(line.trim())) return true;
  final words = foldText(line).split(' ');
  final hits = words.where(_headerWords.contains).length;
  return hits >= 3 && hits * 2 >= words.length && _splitTrailingAmounts(line).amounts.isEmpty;
}

/// Money tokens as printed on statements: grouped thousands and/or two
/// decimals, optional sign, parentheses and an attached CR/DB marker.
/// Plain digit runs (reference numbers) are not amounts here.
final _moneyToken = RegExp(
  r'^[-+(]?(?:Rp\.?)?(?:\d{1,3}(?:[.,]\d{3})+(?:[.,]\d{1,2})?|\d+[.,]\d{2})\)?-?(?:CR|DB|DR|D|K|C)?\.?$',
  caseSensitive: false,
);

({String text, List<_Money> amounts}) _splitTrailingAmounts(String s) {
  final tokens = s.split(' ').where((t) => t.isNotEmpty).toList();
  final amounts = <_Money>[];
  StatementDirection? pendingMarker;
  var cut = tokens.length;
  for (var i = tokens.length - 1; i >= 0; i--) {
    final t = tokens[i];
    if (t.toUpperCase() == 'RP' || t.toUpperCase() == 'IDR') {
      cut = i;
      continue;
    }
    final marker = parseDirectionMarker(t);
    if (marker != null && t != '-' && t != '+' && pendingMarker == null && i > 0 && _moneyToken.hasMatch(tokens[i - 1])) {
      pendingMarker = marker;
      continue;
    }
    if (!_moneyToken.hasMatch(t)) break;
    final a = parseStatementAmount(t);
    if (a == null) break;
    amounts.insert(0, _Money(a.value, a.marker ?? pendingMarker ?? (a.negative ? StatementDirection.debit : null), negative: a.negative));
    pendingMarker = null;
    cut = i;
  }
  return (text: tokens.take(cut).join(' '), amounts: amounts);
}

/// Turns amount columns into rows: one amount = mutation; two = mutation +
/// balance; three or more = debit, credit (one of them zero), balance.
List<StatementRow> _resolve(List<_LineDraft> drafts, int? opening, DateTime now) {
  final booked = [for (final d in drafts) ?d.date];
  final latest = booked.isEmpty ? DateTime(now.year, now.month, now.day) : booked.reduce((a, b) => a.isAfter(b) ? a : b);
  final rows = <StatementRow>[];
  int? prevBalance = opening;
  final parsed = <({_LineDraft d, int amount, StatementDirection? dir, int? balance})>[];
  for (final d in drafts) {
    final a = d.amounts;
    int amount;
    StatementDirection? dir;
    int? balance;
    if (a.length == 1) {
      amount = a[0].value;
      dir = a[0].direction;
    } else if (a.length == 2) {
      amount = a[0].value;
      dir = a[0].direction;
      balance = a[1].signedValue;
    } else {
      final debit = a[a.length - 3];
      final credit = a[a.length - 2];
      balance = a.last.signedValue;
      if (debit.value == 0 && credit.value != 0) {
        amount = credit.value;
        dir = StatementDirection.credit;
      } else if (credit.value == 0 && debit.value != 0) {
        amount = debit.value;
        dir = StatementDirection.debit;
      } else {
        amount = debit.value;
        dir = debit.direction;
      }
    }
    if (amount == 0) continue;
    parsed.add((d: d, amount: amount, dir: dir, balance: balance));
  }
  for (var i = 0; i < parsed.length; i++) {
    final p = parsed[i];
    var dir = p.dir;
    if (dir == null && p.balance != null) {
      dir = directionFromBalances(
        amount: p.amount,
        balance: p.balance!,
        before: prevBalance,
        after: i + 1 < parsed.length ? parsed[i + 1].balance : null,
      );
    }
    if (p.balance != null) prevBalance = p.balance;
    final date = p.d.date ?? latest;
    rows.add(
      StatementRow(
        date: p.d.hasTime ? date : DateTime(date.year, date.month, date.day),
        description: p.d.description.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
        amount: p.amount,
        direction: dir ?? StatementDirection.debit,
        balance: p.balance,
        hasTime: p.d.hasTime,
        pending: p.d.pending,
        directionGuessed: dir == null,
      ),
    );
  }
  return rows;
}


int? _lastBalance(List<StatementRow> rows) {
  final withBalance = rows.where((r) => r.balance != null).toList();
  if (withBalance.isEmpty) return null;
  final descending = rows.first.date.isAfter(rows.last.date);
  return descending ? withBalance.first.balance : withBalance.last.balance;
}
