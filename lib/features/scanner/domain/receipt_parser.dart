/// Receipt (struk) OCR text → [ScanParse].
///
/// Pipeline: normalize lines → classify each line by keyword (fuzzy, so
/// `T0TAL`/`TOTAI` still match) → pick the total, preferring candidates that
/// agree with subtotal/discount/tax/service or cash − change → merchant from
/// the header → date/time → items.
library;

import '../../../core/database/enums.dart';
import 'date_time_parser.dart';
import 'merchant_text.dart';
import 'provider_detector.dart';
import 'scan_models.dart';
import 'text_normalizer.dart';

enum _Kind {
  other,
  meta,
  change,
  itemCount,
  discount,
  tax,
  service,
  rounding,
  subtotal,
  totalStrong,
  totalWeak,
  payment,
}

/// Ordered by preference: earlier phrases are the more final "amount paid".
const _totalStrong = [
  'GRAND TOTAL',
  'TOTAL BAYAR',
  'TOTAL PEMBAYARAN',
  'HARUS DIBAYAR',
  'TOTAL TAGIHAN',
  'JUMLAH BAYAR',
  'JUMLAH TAGIHAN',
  'AMOUNT DUE',
  'TOTAL DUE',
  'BALANCE DUE',
  'NET TOTAL',
  'TOTAL AKHIR',
  'TOTAL AMOUNT',
  'TOTAL BELANJA',
  'TOTAL HARGA',
];
const _totalWeak = ['TOTAL', 'JUMLAH', 'AMOUNT'];
const _itemCount = [
  'TOTAL ITEM',
  'TOTAL ITEMS',
  'TOTAL QTY',
  'TOTAL BARANG',
  'JUMLAH ITEM',
  'JUMLAH BARANG',
  'JUMLAH QTY',
];

/// Bare count labels ("ITEM 3", "QTY: 5"); only on short lines so product
/// names such as "ITEM BARANG 1   1.000" stay items.
const _itemCountBare = ['QTY', 'ITEM', 'ITEMS'];

/// Address/contact line starters, checked before payment words so fuzzy
/// matching cannot read "JL. TEBET RAYA" as a DEBET payment.
const _addressStart = ['JL', 'JLN', 'JALAN', 'TELP', 'TEL', 'TLP', 'NPWP', 'HP', 'WA', 'FAX'];
const _discount = ['DISKON', 'DISC', 'DISCOUNT', 'POTONGAN', 'HEMAT', 'VOUCHER'];
const _tax = ['PPN', 'PAJAK', 'TAX', 'PB 1', 'PBI', 'PBJT', 'VAT', 'PPN DPP'];
const _service = ['SERVICE', 'SERVIS', 'SERVICE CHARGE', 'SVC', 'BIAYA LAYANAN', 'SERVICE CHG'];
const _rounding = ['PEMBULATAN', 'ROUNDING'];
const _subtotal = ['SUBTOTAL', 'SUB TOTAL', 'HARGA JUAL', 'TOTAL SEBELUM'];
const _change = ['KEMBALI', 'KEMBALIAN', 'CHANGE', 'SUSUK'];
const _payment = [
  'TUNAI', 'CASH', 'BAYAR', 'DIBAYAR', 'UANG', 'PAYMENT', 'PEMBAYARAN', 'DEBIT', 'DEBET', 'KARTU',
  'CARD', 'KREDIT', 'CREDIT', 'QRIS', 'EDC', 'GOPAY', 'OVO', 'DANA', 'SHOPEEPAY', 'LINKAJA', 'FLAZZ',
  'EMONEY', 'E MONEY', 'BRIZZI', 'TAPCASH', 'VISA', 'MASTERCARD', 'TRANSFER',
];
const _cashWords = ['TUNAI', 'CASH', 'UANG'];
const _inclusive = ['INCL', 'INCLUDING', 'INCLUDE', 'INCLUDED', 'TERMASUK', 'SUDAH'];
const _metaAccounts = ['MEMBER', 'POIN', 'POINT', 'POINTS', 'SALDO', 'SISA SALDO'];
const _meta = [
  'TELP', 'TEL', 'TLP', 'PHONE', 'HP', 'WA', 'FAX', 'NPWP', 'JL', 'JLN', 'JALAN', 'KASIR', 'CASHIER',
  'KSR', 'STRUK', 'NOTA', 'RECEIPT', 'INVOICE', 'BILL', 'ORDER', 'MEJA', 'TABLE', 'TGL', 'TANGGAL',
  'DATE', 'JAM', 'WAKTU', 'TIME', 'TERMINAL', 'TRX', 'REF', 'PELANGGAN', 'CUSTOMER', 'GUEST', 'PAX',
  'WAITER', 'SERVER', 'SHIFT', 'NO', 'NOMOR', 'KODE', 'RT', 'RW', 'KEL', 'KEC', 'KAB', 'BLOK', 'RUKO',
  'LT', 'LANTAI', 'KOMP', 'PERUM', 'GEDUNG', 'GD', 'EMAIL', 'WWW', 'COM', 'TERIMA KASIH',
  'THANK YOU', 'SELAMAT DATANG', 'WELCOME', 'LAYANAN KONSUMEN', 'KRITIK', 'SARAN', 'BARANG YANG',
  'SMS', 'CALL', 'CS', 'COPY', 'REPRINT', 'SALINAN', 'DINE IN', 'TAKE AWAY', 'TAKEAWAY',
];

/// Header lines that are never the merchant name.
const _merchantSkip = [
  'TELP', 'TEL', 'TLP', 'PHONE', 'HP', 'WA', 'FAX', 'NPWP', 'JL', 'JLN', 'JALAN', 'KEL', 'KEC', 'KAB',
  'RT', 'RW', 'BLOK', 'RUKO', 'LT', 'LANTAI', 'KOMP', 'PERUM', 'GEDUNG', 'GD', 'NO', 'KASIR',
  'CASHIER', 'STRUK', 'NOTA', 'RECEIPT', 'INVOICE', 'FAKTUR', 'TANGGAL', 'TGL', 'DATE', 'MEJA', 'TABLE',
  'BILL', 'ORDER', 'SELAMAT DATANG', 'WELCOME', 'TERIMA KASIH', 'THANK YOU', 'COPY', 'REPRINT',
  'SALINAN', 'CHECK', 'PELANGGAN', 'CUSTOMER', 'MEMBER', 'PAX', 'GUEST', 'SHIFT', 'TRX', 'EMAIL',
  'WWW', 'COM', 'CABANG', 'OUTLET', 'BUKTI', 'PEMBELIAN', 'PENJUALAN', 'TRANSAKSI', 'POS', 'DINE IN',
  'TAKE AWAY',
];
const _legalEntity = ['PT', 'CV', 'UD', 'TBK', 'KOPERASI'];

class _Line {
  _Line(this.index, NormalizedLine n)
    : text = n.text,
      corrected = n.corrected,
      words = keywordWords(n.text),
      amounts = findAmounts(n.text);

  final int index;
  final String text;
  final bool corrected;
  final List<String> words;
  final List<AmountMatch> amounts;
  _Kind kind = _Kind.other;
  int rank = 0;

  AmountMatch? get lastPositive {
    for (final a in amounts.reversed) {
      if (a.value > 0) return a;
    }
    return null;
  }
}

class _Value {
  const _Value(this.amount, this.line);
  final AmountMatch amount;
  final _Line line;
  int get value => amount.value;
  int get signed => amount.negative ? -amount.value : amount.value;
}

class ReceiptParser {
  const ReceiptParser();

  ScanParse parse(String rawText, {required DateTime now}) {
    final lines = [
      for (final (i, n) in normalizeOcrLines(rawText).indexed) _Line(i, n),
    ];
    if (lines.isEmpty) {
      return ScanParse(
        source: ScanSource.receipt,
        rawText: rawText,
        direction: const Extracted(TransactionType.expense, FieldConfidence.high),
      );
    }
    for (final l in lines) {
      l.kind = _classify(l, now);
      if (l.kind == _Kind.totalStrong) {
        l.rank = _totalStrong.indexWhere((p) => hasPhrase(l.words, p));
      }
    }

    // Value of a summary line: its own last amount, or an amount-only next
    // line (label and value split by the OCR layout).
    final consumed = <int>{};
    _Value? valueOf(_Line l) {
      final own = l.lastPositive;
      if (own != null) return _Value(own, l);
      final i = l.index + 1;
      if (i < lines.length) {
        final next = lines[i];
        final nextPositive = next.lastPositive;
        final rest = next.text.replaceAll(RegExp(r'\b(Rp|IDR)\b'), '');
        if (nextPositive != null && letterCount(rest) < 2) {
          consumed.add(i);
          return _Value(nextPositive, next);
        }
      }
      return null;
    }

    final values = <int, _Value>{};
    for (final l in lines) {
      if (l.kind == _Kind.other || l.kind == _Kind.meta) continue;
      final v = valueOf(l);
      if (v != null) values[l.index] = v;
    }
    Iterable<_Value> valuesOf(_Kind k) => [
      for (final l in lines)
        if (l.kind == k && values[l.index] != null) values[l.index]!,
    ];

    // Breakdown.
    final subtotal = valuesOf(_Kind.subtotal).lastOrNull?.value;
    final discountLines = valuesOf(_Kind.discount).toList();
    final discountTotal = discountLines.where((v) => hasPhrase(v.line.words, 'TOTAL')).lastOrNull;
    var discount = discountTotal?.value ??
        (discountLines.isEmpty ? null : discountLines.fold<int>(0, (s, v) => s + v.value));
    final taxes = valuesOf(_Kind.tax).toList();
    final tax = taxes.isEmpty ? null : taxes.fold<int>(0, (s, v) => s + v.value);
    final services = valuesOf(_Kind.service).toList();
    final service = services.isEmpty ? null : services.fold<int>(0, (s, v) => s + v.value);
    final rounding = valuesOf(_Kind.rounding).lastOrNull?.signed;
    final payments = valuesOf(_Kind.payment).toList();
    final cash = payments.firstOrNull?.value;
    final change = valuesOf(_Kind.change).firstOrNull?.value;

    // Region boundaries.
    final summaryStart = lines
            .where(
              (l) =>
                  values.containsKey(l.index) &&
                  const {
                    _Kind.subtotal,
                    _Kind.totalStrong,
                    _Kind.totalWeak,
                    _Kind.itemCount,
                    _Kind.payment,
                    _Kind.change,
                  }.contains(l.kind),
            )
            .firstOrNull
            ?.index ??
        lines.length;
    final firstPricedLine = lines
            .where(
              (l) =>
                  l.index < summaryStart &&
                  l.kind == _Kind.other &&
                  l.amounts.any((a) => a.value > 0 && (a.grouped || a.hasCurrency || a.value >= 100)),
            )
            .firstOrNull
            ?.index ??
        summaryStart;

    final merchant = _merchant(lines, firstPricedLine);
    final merchantIndex = merchant.$2;

    // Items + in-list discounts.
    final items = <ReceiptItem>[];
    var inlineDiscount = 0;
    String? pendingName;
    for (final l in lines) {
      if (l.index <= (merchantIndex ?? -1) || l.index >= summaryStart || consumed.contains(l.index)) {
        continue;
      }
      if (l.kind == _Kind.meta) {
        pendingName = null;
        continue;
      }
      if (l.kind != _Kind.other) continue;
      final amts = [for (final a in l.amounts) if (a.value > 0) a];
      if (amts.isEmpty) {
        pendingName = letterCount(l.text) >= 2 ? l.text : null;
        continue;
      }
      final last = amts.last;
      var name = l.text.substring(0, amts.first.start);
      name = name
          .replaceFirst(RegExp(r'^\s*\d{1,3}\s*[xX@]?\s+'), '')
          .replaceFirst(RegExp(r'\s*\d{1,3}\s*[xX@]\s*$'), '')
          .replaceFirst(RegExp(r'[\s:@xX]+$'), '')
          .trim();
      if (last.negative) {
        inlineDiscount += last.value;
        pendingName = null;
        continue;
      }
      final qty = _quantity(l.text, amts);
      if (letterCount(name) >= 2) {
        items.add(ReceiptItem(prettifyMerchant(name), last.value, quantity: qty));
      } else if (pendingName != null) {
        items.add(ReceiptItem(prettifyMerchant(pendingName), last.value, quantity: qty));
      }
      pendingName = null;
    }
    if (inlineDiscount > 0 && discountTotal == null) discount = (discount ?? 0) + inlineDiscount;
    final itemsSum = items.fold<int>(0, (s, i) => s + i.amount);

    // Expected totals implied by the breakdown.
    final expected = <int>{};
    void expectFrom(int base) {
      final d = discount ?? 0;
      final t = tax ?? 0;
      final s = service ?? 0;
      final r = rounding ?? 0;
      expected.addAll([base - d + t + s + r, base - d + r, base - d + s + r, base + t + s + r, base + r]);
    }

    if (subtotal != null) expectFrom(subtotal);
    if (itemsSum > 0) expectFrom(itemsSum);
    if (cash != null && change != null) expected.add(cash - change);
    final strongCheck = subtotal != null || (cash != null && change != null);

    final amount = _total(
      lines: lines,
      values: values,
      expected: expected,
      strongCheck: strongCheck,
      subtotal: subtotal,
      discount: discount,
      tax: tax,
      service: service,
      rounding: rounding,
      cash: cash,
      change: change,
      itemsSum: itemsSum,
    );

    final dt = pickDateTime([for (final l in lines) l.text], now: now);

    final paymentLine = payments.firstOrNull?.line ??
        lines.where((l) => l.kind == _Kind.payment).firstOrNull;
    final paymentText = paymentLine == null ? null : _paymentLabel(paymentLine);
    final paidInCash = paymentLine != null && hasAnyPhrase(paymentLine.words, _cashWords);
    final provider = paymentLine == null
        ? const Extracted<WalletProvider>.none()
        : detectProvider([paymentLine.text]);

    return ScanParse(
      source: ScanSource.receipt,
      rawText: rawText,
      amount: amount,
      date: dt.date,
      time: dt.time,
      merchant: merchant.$1,
      direction: const Extracted(TransactionType.expense, FieldConfidence.high),
      provider: provider,
      items: items,
      breakdown: ReceiptBreakdown(
        subtotal: subtotal,
        discount: discount,
        tax: tax,
        service: service,
        rounding: rounding,
        cash: cash,
        change: change,
      ),
      paymentMethod: paymentText,
      paidInCash: paidInCash,
    );
  }

  _Kind _classify(_Line l, DateTime now) {
    final w = l.words;
    if (w.isEmpty) return _Kind.other;
    final inclusive = hasAnyPhrase(w, _inclusive);
    if (hasAnyPhrase(w, _change)) return _Kind.change;
    if ((hasAnyPhrase(w, _itemCount) || (w.length <= 3 && hasAnyPhrase(w, _itemCountBare))) &&
        !hasAnyPhrase(w, _totalStrong)) {
      return _Kind.itemCount;
    }
    if (hasAnyPhrase(w, _discount)) return _Kind.discount;
    if (!inclusive && hasAnyPhrase(w, _tax)) return _Kind.tax;
    if (!inclusive && hasAnyPhrase(w, _service)) return _Kind.service;
    if (hasAnyPhrase(w, _rounding)) return _Kind.rounding;
    if (hasAnyPhrase(w, _subtotal)) return _Kind.subtotal;
    if (hasAnyPhrase(w, _totalStrong)) return _Kind.totalStrong;
    if (hasAnyPhrase(w, _totalWeak)) return _Kind.totalWeak;
    if (hasAnyPhrase(w, _metaAccounts) || _addressStart.contains(w.first)) return _Kind.meta;
    // Only cash words tolerate OCR typos (TUNAl); fuzzy "DEBET" would match
    // street names like TEBET.
    if (hasAnyPhrase(w, _payment, fuzzy: false) || hasAnyPhrase(w, _cashWords)) return _Kind.payment;
    if (hasAnyPhrase(w, _meta) || findDates(l.text, now: now).isNotEmpty) return _Kind.meta;
    return _Kind.other;
  }

  /// Merchant = first meaningful header line; legal-entity lines ("PT …")
  /// are only a fallback. Returns the value and its line index.
  (Extracted<String>, int?) _merchant(List<_Line> lines, int headerEnd) {
    _Line? fallback;
    final limit = headerEnd.clamp(0, 8);
    for (final l in lines.take(limit == 0 ? 1 : limit)) {
      final clean = prettifyMerchant(l.text.replaceAll(RegExp(r'[*=#~_]+'), ' '));
      if (letterCount(clean) < 3 || letterRatio(clean) < 0.5) continue;
      if (hasAnyPhrase(l.words, _merchantSkip)) continue;
      if (findDates(l.text, now: DateTime(2000)).isNotEmpty) continue;
      if (l.amounts.any((a) => a.grouped || a.hasCurrency)) continue;
      if (l.words.isNotEmpty && _legalEntity.contains(l.words.first)) {
        fallback ??= l;
        continue;
      }
      final clear = l.index <= 2 && !l.corrected && clean.length <= 40 && letterRatio(clean) >= 0.6;
      return (Extracted(clean, clear ? FieldConfidence.high : FieldConfidence.medium), l.index);
    }
    if (fallback != null) {
      return (Extracted(prettifyMerchant(fallback.text), FieldConfidence.medium), fallback.index);
    }
    return (const Extracted.none(), null);
  }

  Extracted<int> _total({
    required List<_Line> lines,
    required Map<int, _Value> values,
    required Set<int> expected,
    required bool strongCheck,
    required int? subtotal,
    required int? discount,
    required int? tax,
    required int? service,
    required int? rounding,
    required int? cash,
    required int? change,
    required int itemsSum,
  }) {
    final candidates = [
      for (final l in lines)
        if ((l.kind == _Kind.totalStrong || l.kind == _Kind.totalWeak) &&
            values[l.index] != null &&
            _looksLikeMoney(values[l.index]!.amount))
          values[l.index]!,
    ];
    if (candidates.isEmpty) {
      // Alfamart-style "Total Item 3   45.500".
      for (final l in lines) {
        final v = values[l.index];
        if (l.kind == _Kind.itemCount && v != null && (v.amount.grouped || v.amount.hasCurrency)) {
          candidates.add(v);
        }
      }
    }
    candidates.sort((a, b) {
      int tier(_Value v) => switch (v.line.kind) {
        _Kind.totalStrong => 0,
        _Kind.totalWeak => 1,
        _ => 2,
      };
      final byTier = tier(a).compareTo(tier(b));
      if (byTier != 0) return byTier;
      final byRank = a.line.rank.compareTo(b.line.rank);
      if (byRank != 0) return byRank;
      return b.line.index.compareTo(a.line.index);
    });

    if (candidates.isNotEmpty) {
      final consistent = candidates.where((c) => expected.contains(c.value)).firstOrNull;
      final pick = consistent ?? candidates.first;
      FieldConfidence confidence;
      if (consistent != null) {
        confidence = FieldConfidence.high;
      } else {
        confidence = pick.line.kind == _Kind.itemCount ? FieldConfidence.medium : FieldConfidence.high;
        final disagreeing = candidates.any((c) => c.value != pick.value && c.line.kind == pick.line.kind);
        if (pick.line.corrected || (strongCheck && expected.isNotEmpty) || disagreeing) {
          confidence = confidence.lower;
        }
      }
      return Extracted(pick.value, confidence);
    }

    if (subtotal != null) {
      return Extracted(
        subtotal - (discount ?? 0) + (tax ?? 0) + (service ?? 0) + (rounding ?? 0),
        FieldConfidence.medium,
      );
    }
    if (cash != null && change != null && cash > change) {
      return Extracted(cash - change, FieldConfidence.medium);
    }
    if (itemsSum > 0) {
      return Extracted(itemsSum - (discount ?? 0) + (tax ?? 0) + (service ?? 0), FieldConfidence.low);
    }
    AmountMatch? largest;
    for (final l in lines) {
      if (l.kind != _Kind.other) continue;
      for (final a in l.amounts) {
        if ((a.grouped || a.hasCurrency) && a.value > 0 && (largest == null || a.value > largest.value)) {
          largest = a;
        }
      }
    }
    return largest == null ? const Extracted.none() : Extracted(largest.value, FieldConfidence.low);
  }

  bool _looksLikeMoney(AmountMatch a) => a.grouped || a.hasCurrency || a.value >= 100;

  int? _quantity(String text, List<AmountMatch> amts) {
    final m = RegExp(r'(?<![\d.,])(\d{1,3})\s*[xX@]').firstMatch(text);
    if (m != null) return int.parse(m[1]!);
    if (amts.length >= 3 && !amts.first.grouped && !amts.first.hasCurrency && amts.first.value < 1000) {
      return amts.first.value;
    }
    return null;
  }

  String? _paymentLabel(_Line l) {
    final cut = l.amounts.isEmpty ? l.text.length : l.amounts.first.start;
    final label = prettifyMerchant(l.text.substring(0, cut).replaceAll(RegExp(r'[:=]'), ' '));
    return label.isEmpty ? null : label;
  }
}
