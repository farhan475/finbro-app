import '../../../core/database/enums.dart';

/// What kind of document was scanned (07-ocr-screenshot §2).
enum ScanSource {
  receipt('Struk', AttachmentKind.receipt, SourceType.receiptOcr),
  screenshot('Screenshot', AttachmentKind.screenshot, SourceType.screenshot);

  const ScanSource(this.label, this.attachmentKind, this.sourceType);
  final String label;
  final AttachmentKind attachmentKind;
  final SourceType sourceType;
}

/// Field confidence (07-ocr-screenshot §4).
enum FieldConfidence {
  high('Terbaca jelas'),
  medium('Cek lagi'),
  low('Periksa');

  const FieldConfidence(this.label);
  final String label;

  FieldConfidence get lower => switch (this) {
    high => medium,
    _ => low,
  };
}

/// One extracted value plus how sure the parser is about it.
class Extracted<T> {
  const Extracted(this.value, this.confidence);
  const Extracted.none() : value = null, confidence = FieldConfidence.low;

  final T? value;
  final FieldConfidence confidence;

  bool get isPresent => value != null;

  @override
  String toString() => 'Extracted($value, ${confidence.name})';
}

/// Wall-clock time without a date.
class ClockTime {
  const ClockTime(this.hour, this.minute);
  final int hour;
  final int minute;

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Transaction status shown on a transfer/payment screenshot.
enum PaymentStatus {
  success('Berhasil'),
  pending('Diproses'),
  failed('Gagal');

  const PaymentStatus(this.label);
  final String label;
}

/// Bank / e-wallet providers recognised on screenshots and receipt payment
/// lines. [accountKeys] are matched against account names (word-wise).
enum WalletProvider {
  bca('BCA', ['bca'], AccountType.bank),
  gopay('GoPay', ['gopay', 'go pay'], AccountType.ewallet),
  ovo('OVO', ['ovo'], AccountType.ewallet),
  dana('DANA', ['dana'], AccountType.ewallet),
  shopeePay('ShopeePay', ['shopeepay', 'shopee pay', 'shopee'], AccountType.ewallet),
  seaBank('SeaBank', ['seabank', 'sea bank'], AccountType.bank),
  jago('Jago', ['jago'], AccountType.bank),
  bri('BRI', ['bri', 'brimo'], AccountType.bank),
  mandiri('Mandiri', ['mandiri', 'livin'], AccountType.bank),
  bni('BNI', ['bni'], AccountType.bank),
  linkAja('LinkAja', ['linkaja', 'link aja'], AccountType.ewallet);

  const WalletProvider(this.label, this.accountKeys, this.accountType);
  final String label;
  final List<String> accountKeys;
  final AccountType accountType;
}

class ReceiptItem {
  const ReceiptItem(this.name, this.amount, {this.quantity});
  final String name;
  final int amount;
  final int? quantity;

  @override
  String toString() => 'ReceiptItem($name, $amount, qty: $quantity)';
}

/// Summary lines read from a receipt (all optional).
class ReceiptBreakdown {
  const ReceiptBreakdown({
    this.subtotal,
    this.discount,
    this.tax,
    this.service,
    this.rounding,
    this.cash,
    this.change,
  });

  final int? subtotal;
  final int? discount;
  final int? tax;
  final int? service;
  final int? rounding;

  /// Amount tendered (TUNAI/CASH/DEBIT line).
  final int? cash;

  /// KEMBALI / KEMBALIAN / CHANGE.
  final int? change;

  bool get isEmpty =>
      subtotal == null &&
      discount == null &&
      tax == null &&
      service == null &&
      rounding == null &&
      cash == null &&
      change == null;
}

/// Draft extracted from OCR text. Never persisted; the review screen turns it
/// into a [TransactionDraft] only after the user confirms.
class ScanParse {
  const ScanParse({
    required this.source,
    required this.rawText,
    this.amount = const Extracted.none(),
    this.date = const Extracted.none(),
    this.time = const Extracted.none(),
    this.merchant = const Extracted.none(),
    this.direction = const Extracted(TransactionType.expense, FieldConfidence.low),
    this.status = const Extracted.none(),
    this.provider = const Extracted.none(),
    this.reference = const Extracted.none(),
    this.items = const [],
    this.breakdown = const ReceiptBreakdown(),
    this.paymentMethod,
    this.paidInCash = false,
  });

  final ScanSource source;
  final String rawText;
  final Extracted<int> amount;

  /// Local date at midnight.
  final Extracted<DateTime> date;
  final Extracted<ClockTime> time;

  /// Merchant (receipt) or counterparty (screenshot), as printed.
  final Extracted<String> merchant;

  /// Expense or income.
  final Extracted<TransactionType> direction;
  final Extracted<PaymentStatus> status;
  final Extracted<WalletProvider> provider;
  final Extracted<String> reference;
  final List<ReceiptItem> items;
  final ReceiptBreakdown breakdown;
  final String? paymentMethod;

  /// Receipt paid with TUNAI/CASH (suggests a cash account).
  final bool paidInCash;

  bool get isEmpty => rawText.trim().isEmpty;

  /// Combined date + time, or null when no date was read.
  DateTime? get dateTime {
    final d = date.value;
    if (d == null) return null;
    final t = time.value;
    return DateTime(d.year, d.month, d.day, t?.hour ?? 0, t?.minute ?? 0);
  }
}
