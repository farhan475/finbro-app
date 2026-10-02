/// CSV mutation files: header/column detection, presets and row parsing.
library;

import 'dart:typed_data';

import 'bank_presets.dart';
import 'csv_table.dart';
import 'statement_models.dart';
import 'statement_text.dart';

enum ColumnRole {
  date('Tanggal'),
  description('Keterangan'),
  amount('Nominal (bertanda / CR-DB)'),
  debit('Debet (uang keluar)'),
  credit('Kredit (uang masuk)'),
  marker('Penanda CR/DB'),
  balance('Saldo');

  const ColumnRole(this.label);
  final String label;
}

/// Which column holds what. Description may span several columns (joined).
class ColumnMapping {
  const ColumnMapping({
    this.date,
    this.descriptions = const [],
    this.amount,
    this.debit,
    this.credit,
    this.marker,
    this.balance,
    this.dataStart = 0,
    this.dateOrder = DateOrder.dayFirst,
  });

  final int? date;
  final List<int> descriptions;
  final int? amount;
  final int? debit;
  final int? credit;
  final int? marker;
  final int? balance;

  /// Index of the first data row in [CsvAnalysis.table].
  final int dataStart;
  final DateOrder dateOrder;

  bool get isComplete =>
      date != null && descriptions.isNotEmpty && (amount != null || debit != null || credit != null);

  /// Role of column [i] (first match; description included).
  ColumnRole? roleOf(int i) {
    if (date == i) return ColumnRole.date;
    if (amount == i) return ColumnRole.amount;
    if (debit == i) return ColumnRole.debit;
    if (credit == i) return ColumnRole.credit;
    if (marker == i) return ColumnRole.marker;
    if (balance == i) return ColumnRole.balance;
    if (descriptions.contains(i)) return ColumnRole.description;
    return null;
  }

  /// Assigns [role] to column [i] (null clears it). A single-column role
  /// moves from the column that held it; description adds/removes [i].
  ColumnMapping withRole(int i, ColumnRole? role) {
    int? clear(int? c) => c == i ? null : c;
    var m = ColumnMapping(
      date: clear(date),
      descriptions: [for (final d in descriptions) if (d != i) d],
      amount: clear(amount),
      debit: clear(debit),
      credit: clear(credit),
      marker: clear(marker),
      balance: clear(balance),
      dataStart: dataStart,
      dateOrder: dateOrder,
    );
    return switch (role) {
      null => m,
      ColumnRole.date => m._copy(date: i),
      ColumnRole.description => m._copy(descriptions: [...m.descriptions, i]..sort()),
      ColumnRole.amount => m._copy(amount: i),
      ColumnRole.debit => m._copy(debit: i),
      ColumnRole.credit => m._copy(credit: i),
      ColumnRole.marker => m._copy(marker: i),
      ColumnRole.balance => m._copy(balance: i),
    };
  }

  ColumnMapping withDataStart(int row) => _copy(dataStart: row);
  ColumnMapping withDateOrder(DateOrder order) => _copy(dateOrder: order);

  ColumnMapping _copy({
    int? date,
    List<int>? descriptions,
    int? amount,
    int? debit,
    int? credit,
    int? marker,
    int? balance,
    int? dataStart,
    DateOrder? dateOrder,
  }) => ColumnMapping(
    date: date ?? this.date,
    descriptions: descriptions ?? this.descriptions,
    amount: amount ?? this.amount,
    debit: debit ?? this.debit,
    credit: credit ?? this.credit,
    marker: marker ?? this.marker,
    balance: balance ?? this.balance,
    dataStart: dataStart ?? this.dataStart,
    dateOrder: dateOrder ?? this.dateOrder,
  );
}

/// Detection result of a CSV file, before rows are parsed.
class CsvAnalysis {
  const CsvAnalysis({
    required this.table,
    required this.mapping,
    required this.confident,
    this.headerRow,
    this.preset,
  });

  final List<List<String>> table;

  /// Best guess; the user may adjust it when [confident] is false.
  final ColumnMapping mapping;

  /// Header found, every required column identified and most data rows
  /// read. When false the UI asks the user to confirm the columns.
  final bool confident;
  final int? headerRow;
  final BankPreset? preset;

  int get columnCount => table.fold(0, (m, r) => r.length > m ? r.length : m);

  String columnName(int i) {
    final h = headerRow;
    final name = h == null || i >= table[h].length ? '' : table[h][i];
    return name.isEmpty ? 'Kolom ${i + 1}' : name;
  }

  String? get formatLabel => preset?.name ?? 'CSV';
}

/// Decodes and analyses CSV bytes. Throws [StatementImportException] when
/// the file is not tabular text.
CsvAnalysis analyzeCsv(Uint8List bytes, {required DateTime now}) {
  final text = decodeStatementText(bytes);
  if (text.contains('\u0000')) throw const StatementImportException(StatementErrors.unsupported);
  return analyzeCsvText(text, now: now);
}

CsvAnalysis analyzeCsvText(String text, {required DateTime now}) {
  final table = parseCsv(text, detectDelimiter(text));
  if (table.isEmpty) throw const StatementImportException(StatementErrors.noRows);

  final header = _findHeader(table);
  if (header != null) {
    final preamble = [for (final r in table.take(header.row)) r.join(' ')];
    final preset = detectPreset(table[header.row], preamble);
    var mapping = _withMarkerColumn(table, header.mapping.withDataStart(header.row + 1));
    mapping = mapping.withDateOrder(_dateOrder(table, mapping));
    final analysis = CsvAnalysis(table: table, mapping: mapping, confident: false, headerRow: header.row, preset: preset);
    final ok = mapping.isComplete && _readRatio(analysis, mapping, now) >= 0.6;
    return CsvAnalysis(table: table, mapping: mapping, confident: ok, headerRow: header.row, preset: preset);
  }
  final guess = _inferMapping(table, now);
  return CsvAnalysis(
    table: table,
    mapping: guess,
    confident: false,
    preset: detectPreset(const [], table.take(10).map((r) => r.join(' '))),
  );
}

/// Parses rows with [mapping]. Throws when nothing could be read.
StatementParse parseCsvStatement(CsvAnalysis a, ColumnMapping mapping, {required DateTime now}) {
  if (!mapping.isComplete) throw const StatementImportException(StatementErrors.unsupportedLayout);
  final table = a.table;
  final yearFor = inferYear(periodEnd: findPeriodEnd(table.map((r) => r.join(' '))), now: now);
  final drafts = <_Draft>[];
  int? opening;
  int? closing;
  var skipped = 0;

  String cell(List<String> r, int? i) => i == null || i >= r.length ? '' : r[i];

  // Opening/closing balances may sit above the header or in the footer.
  for (var ri = 0; ri < table.length; ri++) {
    final r = table[ri];
    final dateCell = cell(r, mapping.date);
    if (ri >= mapping.dataStart && (isPendingDate(dateCell) || _cellDate(dateCell, mapping, yearFor) != null)) {
      continue;
    }
    final kind = summaryKind(r.join(' '));
    if (kind == SummaryKind.opening) opening ??= _amountInRow(r);
    if (kind == SummaryKind.closing) closing ??= _amountInRow(r);
  }

  for (var ri = mapping.dataStart; ri < table.length; ri++) {
    final r = table[ri];
    final dateCell = cell(r, mapping.date);
    final description = _joinDescription([for (final i in mapping.descriptions) cell(r, i)]);
    final pending = isPendingDate(dateCell);
    final parsedDate = pending ? null : _cellDate(dateCell, mapping, yearFor);
    if (!pending && parsedDate == null) {
      if (summaryKind(r.join(' ')) != null) continue;
      // Wrapped description (no date, no amount) continues the row above.
      final hasAmount = _rowAmount(r, mapping) != null;
      if (!hasAmount && description.isNotEmpty && drafts.isNotEmpty && r.where((c) => c.isNotEmpty).length <= 2) {
        drafts.last.description = _joinDescription([drafts.last.description, description]);
      } else if (hasAmount) {
        skipped++;
      }
      continue;
    }
    final summary = summaryKind(description);
    if (summary == SummaryKind.opening || summary == SummaryKind.closing) {
      final v = _rowAmount(r, mapping)?.$1 ?? parseStatementAmount(cell(r, mapping.balance))?.value;
      if (summary == SummaryKind.opening) opening ??= v;
      if (summary == SummaryKind.closing) closing ??= v;
      continue;
    }
    final money = _rowAmount(r, mapping);
    if (money == null || money.$1 == 0) {
      skipped++;
      continue;
    }
    final markerCell = cell(r, mapping.marker);
    final balance = parseStatementAmount(cell(r, mapping.balance));
    drafts.add(
      _Draft(
        date: parsedDate?.date,
        hasTime: parsedDate?.hasTime ?? false,
        description: description,
        amount: money.$1,
        direction: money.$2 ?? parseDirectionMarker(markerCell),
        balance: balance == null ? null : (balance.negative ? -balance.value : balance.value),
        pending: pending,
      ),
    );
  }

  final rows = _finish(drafts, now: now);
  if (rows.isEmpty) throw const StatementImportException(StatementErrors.noRows);
  return StatementParse(
    rows: rows,
    formatLabel: a.formatLabel,
    openingBalance: opening,
    closingBalance: closing ?? _lastBalance(rows),
    skippedLines: skipped,
  );
}

class _Draft {
  _Draft({
    required this.date,
    required this.hasTime,
    required this.description,
    required this.amount,
    required this.direction,
    required this.balance,
    required this.pending,
  });
  DateTime? date;
  final bool hasTime;
  String description;
  final int amount;
  StatementDirection? direction;
  final int? balance;
  final bool pending;
}

/// Fills missing directions from balance changes and PEND dates from the
/// latest booked date, then builds rows.
List<StatementRow> _finish(List<_Draft> drafts, {required DateTime now}) {
  for (var i = 0; i < drafts.length; i++) {
    final d = drafts[i];
    if (d.direction != null || d.balance == null) continue;
    d.direction = _directionFromBalance(d, i > 0 ? drafts[i - 1].balance : null, i + 1 < drafts.length ? drafts[i + 1] : null);
  }
  final booked = [for (final d in drafts) ?d.date];
  final latest = booked.isEmpty ? DateTime(now.year, now.month, now.day) : booked.reduce((a, b) => a.isAfter(b) ? a : b);
  return [
    for (final d in drafts)
      StatementRow(
        date: d.date ?? DateTime(latest.year, latest.month, latest.day),
        description: d.description,
        amount: d.amount,
        direction: d.direction ?? StatementDirection.debit,
        balance: d.balance,
        hasTime: d.hasTime,
        pending: d.pending,
        directionGuessed: d.direction == null,
      ),
  ];
}


StatementDirection? _directionFromBalance(_Draft d, int? prevBalance, _Draft? next) =>
    directionFromBalances(amount: d.amount, balance: d.balance!, before: prevBalance, after: next?.balance);

int? _lastBalance(List<StatementRow> rows) {
  if (rows.isEmpty || rows.any((r) => r.balance == null)) return null;
  // Oldest-first files end with the newest balance; newest-first start with it.
  final descending = rows.first.date.isAfter(rows.last.date);
  return descending ? rows.first.balance : rows.last.balance;
}

String _joinDescription(List<String> parts) =>
    parts.map((p) => p.trim()).where((p) => p.isNotEmpty).join(' ').replaceAll(RegExp(r'\s+'), ' ');

ParsedDate? _cellDate(String cell, ColumnMapping m, int Function(int, int) yearFor) {
  if (cell.trim().isEmpty) return null;
  final d = parseLeadingDate(cell, order: m.dateOrder, yearFor: yearFor);
  if (d == null) return null;
  // The whole cell must be a date (optionally with time), not a description.
  final rest = cell.substring(d.length).trim();
  if (rest.isNotEmpty && !RegExp(r'^(WIB|WITA|WIT|[AP]M)?$', caseSensitive: false).hasMatch(rest)) return null;
  return d;
}

/// (absolute amount, direction from the amount cells or null).
(int, StatementDirection?)? _rowAmount(List<String> r, ColumnMapping m) {
  String cell(int? i) => i == null || i >= r.length ? '' : r[i];
  if (m.debit != null || m.credit != null) {
    final debit = parseStatementAmount(cell(m.debit))?.value ?? 0;
    final credit = parseStatementAmount(cell(m.credit))?.value ?? 0;
    if (debit == 0 && credit == 0) {
      // Some layouts also carry a signed amount column.
      if (m.amount == null) return cell(m.debit).isEmpty && cell(m.credit).isEmpty ? null : (0, null);
    } else {
      final net = credit - debit;
      return (net.abs(), net >= 0 ? StatementDirection.credit : StatementDirection.debit);
    }
  }
  final a = parseStatementAmount(cell(m.amount));
  if (a == null) return null;
  return (a.value, a.direction);
}

/// Last money value in a summary row such as `Saldo Awal : 1,000,000.00`,
/// also when an unquoted `1,000,000.00` was split into several cells.
int? _amountInRow(List<String> r) {
  final text = r.join(',');
  for (final t in RegExp(r'(?<![\d/\-])-?\d[\d.,]*\d(?![\d/\-])').allMatches(text).toList().reversed) {
    final a = parseStatementAmount(t.group(0)!);
    if (a != null) return a.negative ? -a.value : a.value;
  }
  return null;
}

double _readRatio(CsvAnalysis a, ColumnMapping m, DateTime now) {
  final dataRows = a.table.skip(m.dataStart).where((r) => r.where((c) => c.isNotEmpty).length >= 2).length;
  if (dataRows == 0) return 0;
  try {
    final p = parseCsvStatement(a, m, now: now);
    return p.rows.length / dataRows;
  } on StatementImportException {
    return 0;
  }
}

// ---- Header detection -------------------------------------------------------

const _ignoredHeaders = {
  'cabang', 'branch', 'teller', 'no', 'no rekening', 'account no', 'account number', 'reference no', 'no referensi',
  'referensi', 'reference', 'ref', 'journal no', 'kode transaksi', 'transaction code', 'val date', 'value date',
  'tanggal valuta', 'tanggal efektif', 'effective date', 'kode', 'mata uang', 'currency', 'status',
};

ColumnRole? headerRole(String raw) {
  final f = foldText(raw);
  if (f.isEmpty || _ignoredHeaders.contains(f)) return null;
  bool any(List<String> words) => words.any((w) => f == w || f.startsWith('$w ') || f.endsWith(' $w'));
  if (any(['saldo', 'balance', 'running balance', 'ending balance', 'saldo akhir'])) return ColumnRole.balance;
  if (const {
    'tipe', 'type', 'jenis', 'db/cr', 'cr/db', 'd/k', 'k/d', 'dk', 'debit/kredit', 'debit/credit', 'kredit/debit',
    'debet/kredit', 'arah', 'tipe transaksi', 'dc', 'd/c', 'mutasi db/cr',
  }.contains(f)) {
    return ColumnRole.marker;
  }
  if (any(['debit', 'debet', 'db', 'dr', 'pengeluaran', 'uang keluar', 'keluar', 'withdrawal', 'withdrawals', 'mutasi debet', 'mutasi debit'])) {
    return ColumnRole.debit;
  }
  if (any(['kredit', 'credit', 'cr', 'pemasukan', 'uang masuk', 'masuk', 'deposit', 'deposits', 'mutasi kredit'])) {
    return ColumnRole.credit;
  }
  if (f.contains('tanggal') || f.contains('tgl') || f.contains('date') || f == 'waktu' || f.startsWith('waktu ')) {
    return ColumnRole.date;
  }
  if (any([
    'keterangan', 'uraian', 'description', 'deskripsi', 'remark', 'remarks', 'rincian', 'detail', 'details',
    'transaction details', 'catatan', 'notes', 'note', 'narasi', 'narrative', 'sumber/tujuan', 'source/destination',
    'transaksi', 'transaction', 'nama transaksi', 'berita', 'jenis transaksi', 'merchant', 'penerima', 'info',
  ])) {
    return ColumnRole.description;
  }
  if (any(['jumlah', 'nominal', 'amount', 'mutasi', 'nilai', 'jumlah transaksi', 'transaction amount', 'idr', 'rp'])) {
    return ColumnRole.amount;
  }
  return null;
}

class _Header {
  const _Header(this.row, this.mapping);
  final int row;
  final ColumnMapping mapping;
}

_Header? _findHeader(List<List<String>> table) {
  _Header? best;
  var bestScore = 0;
  for (var ri = 0; ri < table.length && ri < 40; ri++) {
    var m = const ColumnMapping();
    final r = table[ri];
    for (var i = 0; i < r.length; i++) {
      final role = headerRole(r[i]);
      if (role == null || (role != ColumnRole.description && m.roleOf(i) != null)) continue;
      // First date column wins (transaction date before value date); one
      // column per single role.
      final taken = switch (role) {
        ColumnRole.date => m.date != null,
        ColumnRole.amount => m.amount != null,
        ColumnRole.debit => m.debit != null,
        ColumnRole.credit => m.credit != null,
        ColumnRole.marker => m.marker != null,
        ColumnRole.balance => m.balance != null,
        ColumnRole.description => false,
      };
      if (!taken) m = m.withRole(i, role);
    }
    if (!m.isComplete) continue;
    final score = [m.date, m.amount, m.debit, m.credit, m.marker, m.balance].whereType<int>().length + 1;
    if (score > bestScore) {
      best = _Header(ri, m);
      bestScore = score;
    }
  }
  return best;
}

/// A column without a role whose values are CR/DB markers (BCA puts them in
/// an unnamed column next to Jumlah).
ColumnMapping _withMarkerColumn(List<List<String>> table, ColumnMapping m) {
  if (m.marker != null || m.amount == null) return m;
  final width = table.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  for (var i = 0; i < width; i++) {
    if (m.roleOf(i) != null) continue;
    final values = [
      for (final r in table.skip(m.dataStart).take(60))
        if (i < r.length && r[i].isNotEmpty) r[i],
    ];
    if (values.isNotEmpty && values.where((v) => parseDirectionMarker(v) != null).length >= values.length * 0.8) {
      return m.withRole(i, ColumnRole.marker);
    }
  }
  return m;
}

/// Month-first only when some value cannot be day-first (day > 12 in the
/// second position) and none contradicts it.
DateOrder _dateOrder(List<List<String>> table, ColumnMapping m) {
  final col = m.date;
  if (col == null) return DateOrder.dayFirst;
  var dayFirstOnly = false;
  var monthFirstOnly = false;
  final re = RegExp(r"^\s*'?(\d{1,2})[/\-.](\d{1,2})[/\-.]\d{2,4}");
  for (final r in table.skip(m.dataStart).take(200)) {
    if (col >= r.length) continue;
    final match = re.firstMatch(r[col]);
    if (match == null) continue;
    final a = int.parse(match.group(1)!);
    final b = int.parse(match.group(2)!);
    if (a > 12) dayFirstOnly = true;
    if (b > 12) monthFirstOnly = true;
  }
  return monthFirstOnly && !dayFirstOnly ? DateOrder.monthFirst : DateOrder.dayFirst;
}

/// Guess from values when there is no recognisable header row.
ColumnMapping _inferMapping(List<List<String>> table, DateTime now) {
  final width = table.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  final yearFor = inferYear(now: now);
  bool isDate(String c) {
    final d = parseLeadingDate(c, yearFor: yearFor);
    return d != null && c.substring(d.length).trim().isEmpty || isPendingDate(c);
  }

  // First row whose some cell is a date starts the data.
  var start = table.indexWhere((r) => r.any(isDate));
  if (start < 0) return const ColumnMapping();
  final sample = table.skip(start).take(80).toList();
  double ratio(int i, bool Function(String) test) {
    final values = [for (final r in sample) if (i < r.length && r[i].isNotEmpty) r[i]];
    if (values.isEmpty) return 0;
    return values.where(test).length / sample.length;
  }

  var m = ColumnMapping(dataStart: start);
  final numeric = <int>[];
  var bestText = -1;
  var bestLen = 0.0;
  for (var i = 0; i < width; i++) {
    if (m.date == null && ratio(i, isDate) >= 0.6) {
      m = m.withRole(i, ColumnRole.date);
      continue;
    }
    if (ratio(i, (c) => parseDirectionMarker(c) != null) >= 0.6) {
      m = m.withRole(i, ColumnRole.marker);
      continue;
    }
    if (ratio(i, (c) => parseStatementAmount(c) != null) >= 0.3 &&
        ratio(i, (c) => parseStatementAmount(c) == null && RegExp('[A-Za-z]{3}').hasMatch(c)) < 0.2) {
      numeric.add(i);
      continue;
    }
    final lens = [for (final r in sample) if (i < r.length) r[i].length];
    final avg = lens.isEmpty ? 0.0 : lens.reduce((a, b) => a + b) / sample.length;
    if (avg > bestLen) {
      bestLen = avg;
      bestText = i;
    }
  }
  if (bestText >= 0) m = m.withRole(bestText, ColumnRole.description);
  if (numeric.length == 1) {
    m = m.withRole(numeric[0], ColumnRole.amount);
  } else if (numeric.length == 2) {
    // Two half-empty columns are debit/credit; otherwise amount + balance.
    final filled = [for (final i in numeric) ratio(i, (c) => (parseStatementAmount(c)?.value ?? 0) != 0)];
    if (filled[0] < 0.9 && filled[1] < 0.9) {
      m = m.withRole(numeric[0], ColumnRole.debit).withRole(numeric[1], ColumnRole.credit);
    } else {
      m = m.withRole(numeric[0], ColumnRole.amount).withRole(numeric[1], ColumnRole.balance);
    }
  } else if (numeric.length >= 3) {
    final n = numeric.length;
    m = m
        .withRole(numeric[n - 3], ColumnRole.debit)
        .withRole(numeric[n - 2], ColumnRole.credit)
        .withRole(numeric[n - 1], ColumnRole.balance);
  }
  return m.withDateOrder(_dateOrder(table, m));
}
