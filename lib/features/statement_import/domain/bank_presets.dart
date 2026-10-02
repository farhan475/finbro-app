/// Known CSV layouts of Indonesian banks, written from public descriptions
/// of their internet/mobile banking exports. They name the detected bank and
/// confirm the column guess; the column roles themselves come from the
/// shared header aliases in `csv_statement_parser.dart`, so a bank that
/// renames a column still parses through the generic path.
///
/// Not validated against real files yet: every preset needs a sample
/// statement from the owner before it can be called reliable.
library;

import 'statement_text.dart';

class BankPreset {
  const BankPreset(this.name, {required this.keywords, required this.signatures});

  final String name;

  /// Whole words in the text above the header (account info, title).
  final List<String> keywords;

  /// Folded header names; a header row containing every name of one
  /// signature is this bank's layout.
  final List<List<String>> signatures;

  bool matchesHeader(Set<String> header) => signatures.any((s) => s.every(header.contains));

  /// Length of the longest keyword found in [folded], 0 when none.
  int textMatch(String folded) {
    var best = 0;
    for (final k in keywords) {
      if (k.length > best && ' $folded '.contains(' $k ')) best = k.length;
    }
    return best;
  }
}

const bankPresets = <BankPreset>[
  // KlikBCA "Mutasi Rekening" CSV: account info lines, then
  // `Tanggal Transaksi,Keterangan,Cabang,Jumlah,,Saldo`; dates `'01/09`
  // without year or `PEND`; Jumlah `50,000.00 DB`; footer Saldo Awal /
  // Mutasi Kredit / Mutasi Debet / Saldo Akhir.
  BankPreset(
    'BCA',
    keywords: ['bca', 'klikbca', 'bank central asia', 'mybca'],
    signatures: [
      ['tanggal transaksi', 'keterangan', 'cabang', 'jumlah', 'saldo'],
    ],
  ),
  // Mandiri internet banking / Livin': `Account No,Date,Val. Date,
  // Transaction Code,Description,Description,Reference No.,Debit,Credit`.
  BankPreset(
    'Mandiri',
    keywords: ['mandiri', 'livin', 'bank mandiri'],
    signatures: [
      ['account no', 'date', 'val date', 'description', 'debit', 'credit'],
      ['date', 'description', 'reference no', 'debit', 'credit'],
    ],
  ),
  // BNI: `Post Date,Value Date,Branch,Journal No.,Description,Debit,Credit,
  // Balance` or `Tanggal Transaksi,Uraian Transaksi,Tipe,Nominal,Saldo`.
  BankPreset(
    'BNI',
    keywords: ['bni', 'bank negara indonesia', 'wondr'],
    signatures: [
      ['post date', 'journal no', 'description', 'debit', 'credit'],
      ['tanggal transaksi', 'uraian transaksi', 'tipe', 'nominal', 'saldo'],
    ],
  ),
  // BRI internet banking: `Tanggal Transaksi,Uraian Transaksi,Teller,Debet,
  // Kredit,Saldo`.
  BankPreset(
    'BRI',
    keywords: ['bri', 'brimo', 'bank rakyat indonesia'],
    signatures: [
      ['tanggal transaksi', 'uraian transaksi', 'teller', 'debet', 'kredit'],
    ],
  ),
  // Bank Jago history export: `Tanggal & Waktu,Sumber/Tujuan,Rincian
  // Transaksi,Catatan,Jumlah,Saldo` (signed amounts) or the English labels.
  BankPreset(
    'Jago',
    keywords: ['jago', 'bank jago'],
    signatures: [
      ['tanggal & waktu', 'sumber/tujuan', 'rincian transaksi', 'jumlah'],
      ['date & time', 'source/destination', 'transaction details', 'amount'],
    ],
  ),
  // SeaBank: `Waktu Transaksi,Jenis Transaksi,Keterangan,Nominal,Saldo`
  // with signed amounts.
  BankPreset(
    'SeaBank',
    keywords: ['seabank', 'sea bank'],
    signatures: [
      ['waktu transaksi', 'jenis transaksi', 'keterangan', 'nominal'],
    ],
  ),
  // blu by BCA Digital: `Tanggal,Deskripsi,Debit/Kredit,Nominal,Saldo`.
  BankPreset(
    'blu (BCA Digital)',
    keywords: ['blu', 'bca digital', 'blu by bca digital'],
    signatures: [
      ['tanggal', 'deskripsi', 'debit/kredit', 'nominal'],
    ],
  ),
];

/// Preset for a header row (exact layout first) or, failing that, the bank
/// named in the text above it.
BankPreset? detectPreset(List<String> headerCells, Iterable<String> preamble) {
  final header = {for (final c in headerCells) foldText(c)};
  for (final p in bankPresets) {
    if (p.matchesHeader(header)) return p;
  }
  final text = foldText(preamble.join(' '));
  BankPreset? best;
  var bestLen = 0;
  for (final p in bankPresets) {
    final len = p.textMatch(text);
    if (len > bestLen) {
      best = p;
      bestLen = len;
    }
  }
  return best;
}
