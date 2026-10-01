/// Transfer / payment screenshot OCR text (BCA mobile, GoPay, OVO, DANA,
/// ShopeePay, SeaBank, Jago, generic) → [ScanParse].
library;

import '../../../core/database/enums.dart';
import 'date_time_parser.dart';
import 'merchant_text.dart';
import 'provider_detector.dart';
import 'scan_models.dart';
import 'text_normalizer.dart';

const _success = [
  'BERHASIL', 'SUKSES', 'SUCCESS', 'SUCCESSFUL', 'SUCCESSFULLY', 'COMPLETED', 'SELESAI', 'LUNAS',
];
const _pending = ['PENDING', 'DIPROSES', 'MENUNGGU', 'PROCESSING', 'TERTUNDA', 'IN PROGRESS'];
const _failed = [
  'GAGAL', 'FAILED', 'DIBATALKAN', 'CANCELLED', 'CANCELED', 'DITOLAK', 'REJECTED', 'KEDALUWARSA',
];

const _incomeStrong = [
  'UANG MASUK', 'DANA MASUK', 'TRANSFER MASUK', 'TERIMA UANG', 'MENERIMA', 'DITERIMA DARI',
  'TERIMA DARI', 'RECEIVED', 'INCOMING', 'REFUND', 'PENGEMBALIAN DANA', 'KAMU TERIMA',
  'ANDA MENERIMA', 'UANG DITERIMA', 'DANA DITERIMA',
];
const _incomeWeak = ['PENGIRIM', 'DARI', 'FROM', 'SENDER'];
const _expenseStrong = [
  'UANG KELUAR', 'TRANSFER KELUAR', 'PEMBAYARAN', 'BAYAR', 'KIRIM UANG', 'TRANSFER KE', 'KIRIM KE',
  'PEMBELIAN', 'PAYMENT', 'PAID', 'SENT', 'KAMU BAYAR', 'KAMU KIRIM', 'TARIK TUNAI', 'M TRANSFER',
];
const _expenseWeak = ['PENERIMA', 'TUJUAN', 'KE', 'KEPADA', 'MERCHANT', 'TO', 'RECIPIENT'];

const _totalLabels = [
  'TOTAL', 'TOTAL BAYAR', 'TOTAL PEMBAYARAN', 'TOTAL TRANSAKSI', 'TOTAL TRANSFER', 'GRAND TOTAL',
];
const _amountLabels = [
  'JUMLAH', 'JUMLAH TRANSFER', 'NOMINAL', 'NOMINAL TRANSFER', 'AMOUNT', 'KAMU BAYAR', 'KAMU KIRIM',
  'ANDA BAYAR', 'DIBAYAR', 'BESAR TRANSFER', 'JUMLAH DANA', 'TAGIHAN', 'HARGA',
];
const _nonAmountLines = [
  'BIAYA', 'ADMIN', 'FEE', 'SALDO', 'BALANCE', 'SISA', 'CASHBACK', 'KOIN', 'COINS', 'POIN', 'POINTS',
  'DISKON', 'DISCOUNT', 'POTONGAN', 'VOUCHER', 'LIMIT', 'PROMO', 'HEMAT', 'BONUS', 'REF', 'REFERENSI',
  'ID TRANSAKSI', 'NO TRANSAKSI', 'ORDER ID',
];

/// Counterparty labels, most specific first (regex source, case-insensitive).
const _payeeLabels = [
  r'nama\s+penerima', r'rekening\s+tujuan', r'nama\s+tujuan', r'nama\s+merchant', r'nama\s+toko',
  r'transfer\s+ke', r'kirim\s+(?:uang\s+)?ke', r'dibayar\s+ke', r'bayar\s+ke', r'pembayaran\s+ke',
  r'paid\s+to', r'sent\s+to', r'penerima', r'tujuan', r'kepada', r'merchant', r'toko', r'recipient',
  r'payee', r'ke', r'to',
];
const _payerLabels = [
  r'nama\s+pengirim', r'diterima\s+dari', r'terima\s+dari', r'received\s+from', r'pengirim', r'dari',
  r'from', r'sender',
];

final _referenceLabel = RegExp(
  r'(?<![A-Za-z])(no\.?\s*ref(?:erensi)?|nomor\s+referensi|kode\s+referensi|ref(?:erence)?(?:\s*(?:no|number|id))?\.?|id\s+transaksi|transaction\s+id|no\.?\s*transaksi|nomor\s+transaksi|kode\s+transaksi|order\s+id|no\.?\s*pesanan|trx\s*id|id\s+pembayaran)(?![A-Za-z])\s*[:#.\-]?\s*(.*)$',
  caseSensitive: false,
);
final _referenceToken = RegExp(r'[A-Za-z0-9][A-Za-z0-9\-/]{3,}');

/// Generic screen text that is never the counterparty.
const _genericLines = [
  'DETAIL TRANSAKSI', 'RINCIAN TRANSAKSI', 'BUKTI TRANSFER', 'BUKTI PEMBAYARAN', 'DETAIL',
  'RINCIAN', 'TRANSAKSI', 'RECEIPT', 'RESI', 'BAGIKAN', 'SHARE', 'SELESAI', 'KEMBALI', 'METODE',
  'SUMBER DANA', 'KATEGORI', 'CATATAN', 'BERITA', 'KETERANGAN', 'BERANDA', 'HOME', 'GALERI',
];

class _SLine {
  _SLine(this.index, NormalizedLine n)
    : text = n.text,
      corrected = n.corrected,
      words = keywordWords(n.text),
      amounts = findAmounts(n.text);

  final int index;
  final String text;
  final bool corrected;
  final List<String> words;
  final List<AmountMatch> amounts;

  AmountMatch? get firstMoney {
    for (final a in amounts) {
      if (a.value > 0 && (a.hasCurrency || a.grouped)) return a;
    }
    return null;
  }
}

class ScreenshotParser {
  const ScreenshotParser();

  ScanParse parse(String rawText, {required DateTime now}) {
    final lines = [for (final (i, n) in normalizeOcrLines(rawText).indexed) _SLine(i, n)];
    if (lines.isEmpty) return ScanParse(source: ScanSource.screenshot, rawText: rawText);

    final status = _status(lines);
    final amount = _amount(lines);
    final direction = _direction(lines, amount.$2);
    final party = _counterparty(lines, direction, amount.$2?.index);
    final dt = pickDateTime([for (final l in lines) l.text], now: now);
    final provider = detectProvider([for (final l in lines) l.text], excluded: party.$2);

    return ScanParse(
      source: ScanSource.screenshot,
      rawText: rawText,
      amount: amount.$1,
      date: dt.date,
      time: dt.time,
      merchant: party.$1,
      direction: direction,
      status: status,
      provider: provider,
      reference: _reference(lines),
    );
  }

  Extracted<PaymentStatus> _status(List<_SLine> lines) {
    for (final l in lines) {
      final PaymentStatus? s;
      if (hasAnyPhrase(l.words, _failed)) {
        s = PaymentStatus.failed;
      } else if (hasAnyPhrase(l.words, _pending)) {
        s = PaymentStatus.pending;
      } else if (hasAnyPhrase(l.words, _success)) {
        s = PaymentStatus.success;
      } else {
        s = null;
      }
      if (s == null) continue;
      final prominent = l.index < 6 || l.words.length <= 4;
      return Extracted(s, prominent ? FieldConfidence.high : FieldConfidence.medium);
    }
    return const Extracted.none();
  }

  Extracted<TransactionType> _direction(List<_SLine> lines, _SLine? amountLine) {
    var income = 0;
    var expense = 0;
    for (final l in lines) {
      // Exact: fuzzy matching would read "PENERIMA" as "MENERIMA".
      if (hasAnyPhrase(l.words, _incomeStrong, fuzzy: false)) income += 2;
      if (hasAnyPhrase(l.words, _expenseStrong, fuzzy: false)) expense += 2;
      if (l.words.isNotEmpty && _incomeWeak.contains(l.words.first)) income += 1;
      if (l.words.isNotEmpty && _expenseWeak.contains(l.words.first)) expense += 1;
    }
    final money = amountLine?.firstMoney;
    if (amountLine != null && money != null) {
      final before = amountLine.text.substring(0, money.start).trimRight();
      if (money.negative || before.endsWith('-')) expense += 2;
      if (before.endsWith('+')) income += 2;
    }
    if (income == expense) {
      return const Extracted(TransactionType.expense, FieldConfidence.low);
    }
    final winner = income > expense ? TransactionType.income : TransactionType.expense;
    final hi = income > expense ? income : expense;
    final lo = income > expense ? expense : income;
    return Extracted(winner, hi >= 2 && lo == 0 ? FieldConfidence.high : FieldConfidence.medium);
  }

  /// Returns the amount and the line it came from.
  (Extracted<int>, _SLine?) _amount(List<_SLine> lines) {
    bool excluded(_SLine l) => hasAnyPhrase(l.words, _nonAmountLines);

    ({AmountMatch amount, _SLine line})? labelled(List<String> labels) {
      for (final l in lines) {
        if (excluded(l) || !hasAnyPhrase(l.words, labels)) continue;
        final own = l.firstMoney ?? l.amounts.where((a) => a.value >= 100).firstOrNull;
        if (own != null) return (amount: own, line: l);
        if (l.index + 1 < lines.length) {
          final next = lines[l.index + 1];
          final m = next.firstMoney;
          if (m != null && !excluded(next)) return (amount: m, line: next);
        }
      }
      return null;
    }

    final total = labelled(_totalLabels);
    final named = labelled(_amountLabels);
    ({AmountMatch amount, _SLine line})? headline;
    final distinct = <int>{};
    for (final l in lines) {
      if (excluded(l)) continue;
      for (final a in l.amounts) {
        if (a.hasCurrency && a.value > 0) {
          distinct.add(a.value);
          headline ??= (amount: a, line: l);
        }
      }
    }

    final pick = total ?? named ?? headline;
    if (pick != null) {
      var confidence = distinct.length <= 1 || (headline != null && headline.amount.value == pick.amount.value)
          ? FieldConfidence.high
          : FieldConfidence.medium;
      if (pick == headline && distinct.length > 1) confidence = FieldConfidence.medium;
      if (pick.line.corrected) confidence = confidence.lower;
      return (Extracted(pick.amount.value, confidence), pick.line);
    }

    ({AmountMatch amount, _SLine line})? largest;
    for (final l in lines) {
      if (excluded(l)) continue;
      for (final a in l.amounts) {
        if (a.grouped && (largest == null || a.value > largest.amount.value)) {
          largest = (amount: a, line: l);
        }
      }
    }
    if (largest == null) return (const Extracted.none(), null);
    return (Extracted(largest.amount.value, FieldConfidence.low), largest.line);
  }

  /// Counterparty/merchant and the line indexes it was read from (excluded
  /// from provider detection, e.g. destination bank "BCA - 123…").
  (Extracted<String>, Set<int>) _counterparty(
    List<_SLine> lines,
    Extracted<TransactionType> direction,
    int? amountLine,
  ) {
    final isIncome = direction.value == TransactionType.income;
    final primary = isIncome ? _payerLabels : _payeeLabels;
    final secondary = isIncome ? _payeeLabels : _payerLabels;

    final found = _labelled(lines, primary) ??
        (direction.confidence == FieldConfidence.low ? _labelled(lines, secondary) : null);
    if (found != null) {
      return (Extracted(found.$1, FieldConfidence.high), found.$2);
    }

    // No label: the first name-like line right below the amount.
    if (amountLine != null) {
      for (var i = amountLine + 1; i < lines.length && i <= amountLine + 3; i++) {
        final l = lines[i];
        if (!_nameLike(l)) continue;
        final name = _cleanName(l.text);
        if (name != null) return (Extracted(name, FieldConfidence.medium), {i});
      }
    }
    return (const Extracted.none(), const {});
  }

  (String, Set<int>)? _labelled(List<_SLine> lines, List<String> labels) {
    for (final label in labels) {
      final re = RegExp(
        r'^(?:.{0,24}?\s)?' + label + r'(?![A-Za-z])\s*[:\-]?\s*(.*)$',
        caseSensitive: false,
      );
      for (final l in lines) {
        final m = re.firstMatch(l.text);
        if (m == null) continue;
        final rest = m[1]!.trim();
        if (rest.split(' ').length > 7) continue;
        final same = rest.isEmpty ? null : _cleanName(rest);
        if (same != null && !_isGeneric(same) && !_isBankOnly(same)) return (same, {l.index});
        for (var i = l.index + 1; i < lines.length && i <= l.index + 2; i++) {
          final next = lines[i];
          if (next.firstMoney != null || findDates(next.text, now: DateTime(2000)).isNotEmpty) break;
          final name = _cleanName(next.text);
          if (name != null && !_isGeneric(name) && !_isBankOnly(name)) {
            return (name, {for (var j = l.index; j <= i + 1 && j < lines.length; j++) j});
          }
        }
      }
    }
    return null;
  }

  bool _nameLike(_SLine l) {
    if (l.firstMoney != null) return false;
    if (letterCount(l.text) < 3 || letterRatio(l.text) < 0.6) return false;
    if (findDates(l.text, now: DateTime(2000)).isNotEmpty) return false;
    if (hasAnyPhrase(l.words, [..._success, ..._pending, ..._failed, ..._incomeStrong, ..._expenseStrong])) {
      return false;
    }
    return !_isGeneric(l.text);
  }

  static const _bankWords = {
    'BANK', 'BCA', 'BRI', 'BNI', 'MANDIRI', 'BSI', 'BTN', 'CIMB', 'NIAGA', 'PERMATA', 'DANAMON',
    'JAGO', 'SEABANK', 'SEA', 'JENIUS', 'BTPN', 'MEGA', 'PANIN', 'OCBC', 'MAYBANK', 'BJB', 'DKI',
    'SYARIAH', 'DIGITAL', 'OVO', 'GOPAY', 'DANA', 'SHOPEEPAY', 'LINKAJA', 'NEO', 'COMMERCE', 'BLU',
  };

  /// "BCA", "Bank Mandiri", "OVO": destination bank/wallet, not a person or
  /// merchant (m-BCA prints "Ke BCA - 123…" above the recipient name).
  bool _isBankOnly(String s) {
    final w = keywordWords(s);
    return w.isNotEmpty && w.every(_bankWords.contains);
  }

  bool _isGeneric(String s) {
    final w = keywordWords(s);
    if (w.isEmpty) return true;
    return hasAnyPhrase(w, _genericLines) ||
        hasAnyPhrase(w, [..._success, ..._pending, ..._failed]);
  }

  /// Strips account numbers, masks and bank suffixes: `BUDI - BCA 1234` →
  /// `BUDI`; `a.n. SITI` → `SITI`.
  String? _cleanName(String raw) {
    var s = raw.replaceAll(RegExp(r'^(a\.?\s?n\.?|an\.)\s+', caseSensitive: false), '');
    final parts = s.split(RegExp(r'\s+[-|•/]\s+|\(|\)'));
    s = parts.firstWhere((p) => letterCount(p.replaceAll(RegExp(r'[\d*•xX]{3,}'), '')) >= 2, orElse: () => '');
    s = s
        .replaceAll(RegExp(r'[\d*•]{3,}[\d*•\s-]*'), ' ')
        .replaceAll(RegExp(r'[:]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (letterCount(s) < 2) return null;
    return prettifyMerchant(s);
  }

  Extracted<String> _reference(List<_SLine> lines) {
    for (final l in lines) {
      final m = _referenceLabel.firstMatch(l.text);
      if (m == null) continue;
      final same = _referenceValue(m[2]!);
      if (same != null) {
        return Extracted(same, same.length >= 6 ? FieldConfidence.high : FieldConfidence.medium);
      }
      if (l.index + 1 < lines.length) {
        final next = _referenceValue(lines[l.index + 1].text);
        if (next != null) return Extracted(next, FieldConfidence.medium);
      }
    }
    return const Extracted.none();
  }

  String? _referenceValue(String rest) {
    final t = rest.trim();
    if (t.isEmpty) return null;
    // "1234 5678 9012" → one number.
    if (RegExp(r'^\d[\d ]{5,}\d$').hasMatch(t)) return t.replaceAll(' ', '');
    for (final m in _referenceToken.allMatches(t)) {
      final token = m[0]!;
      if (RegExp(r'\d').hasMatch(token)) return token;
    }
    return null;
  }
}
