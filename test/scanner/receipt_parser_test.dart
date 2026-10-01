import 'package:finbro_app/core/database/enums.dart';
import 'package:finbro_app/features/scanner/domain/receipt_parser.dart';
import 'package:finbro_app/features/scanner/domain/scan_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 30, 12);
  ScanParse parse(String text) => const ReceiptParser().parse(text, now: now);

  test('clear minimarket receipt with cash and change', () {
    final r = parse('''
INDOMARET
PT INDOMARCO PRIMA TBK
JL. TEBET RAYA NO. 12
NPWP 01.337.994.6-092.000
25.09.2026 14:32 2A07/KSR01/ANDI
AQUA 600ML        2   3.500    7.000
ROTI TAWAR SARI ROTI   1  16.500  16.500
INDOMIE GORENG    5   3.100   15.500
TOTAL ITEM 3
HARGA JUAL :          39.000
TOTAL :               39.000
TUNAI :               50.000
KEMBALI :             11.000
PPN : 3.865
TERIMA KASIH
''');
    expect(r.amount.value, 39000);
    expect(r.amount.confidence, FieldConfidence.high);
    expect(r.merchant.value, 'Indomaret');
    expect(r.date.value, DateTime(2026, 9, 25));
    expect(r.time.value, const ClockTime(14, 32));
    expect(r.direction.value, TransactionType.expense);
    expect(r.breakdown.cash, 50000);
    expect(r.breakdown.change, 11000);
    expect(r.paidInCash, isTrue);
    expect(r.items.map((i) => i.amount), [7000, 16500, 15500]);
  });

  test('restaurant with discount, tax (PB1) and service; grand total wins', () {
    final r = parse('''
*** WARUNG SOTO PAK DI ***
Jl. Kemang Raya 45, Jakarta Selatan
Telp 021-7190000
Meja 12      Pax 2
Kasir: Rina
Tgl: 24/09/2026  Jam 19:05
1 Soto Ayam            25.000
2 Nasi Putih           12.000
1 Es Teh Manis          6.000
1 Kerupuk               4.000
Subtotal               47.000
Diskon Member          -4.700
Service 5%              2.115
PB1 10%                 4.442
GRAND TOTAL            48.857
DEBIT BCA              48.857
''');
    expect(r.merchant.value, 'Warung Soto Pak Di');
    expect(r.amount.value, 48857);
    expect(r.amount.confidence, FieldConfidence.high);
    expect(r.breakdown.subtotal, 47000);
    expect(r.breakdown.discount, 4700);
    expect(r.breakdown.service, 2115);
    expect(r.breakdown.tax, 4442);
    expect(r.date.value, DateTime(2026, 9, 24));
    expect(r.time.value, const ClockTime(19, 5));
    expect(r.provider.value, WalletProvider.bca);
    expect(r.paidInCash, isFalse);
  });

  test('cafe with prices including tax and TOTAL BAYAR over TOTAL', () {
    final r = parse('''
Kopi Kenangan
Kota Kasablanka LG-12
2026-09-20 08:15
Kopi Kenangan Mantan  x2   Rp 38.000
Croissant               Rp 22.000
Total                   Rp 60.000
Voucher                -Rp 10.000
Total Bayar             Rp 50.000
Harga sudah termasuk PPN
QRIS GOPAY              Rp 50.000
''');
    expect(r.merchant.value, 'Kopi Kenangan');
    expect(r.amount.value, 50000);
    expect(r.date.value, DateTime(2026, 9, 20));
    expect(r.time.value, const ClockTime(8, 15));
    expect(r.provider.value, WalletProvider.gopay);
    expect(r.breakdown.tax, isNull, reason: 'tax already included');
  });

  test('long item list', () {
    final items = [for (var i = 1; i <= 25; i++) 'ITEM BARANG $i        ${_grouped(i * 1000)}'];
    final sum = [for (var i = 1; i <= 25; i++) i * 1000].reduce((a, b) => a + b);
    final r = parse([
      'SUPERINDO KALIBATA',
      '12 Sep 2026 17:40',
      ...items,
      'SUBTOTAL      ${_grouped(sum)}',
      'TOTAL         ${_grouped(sum)}',
      'CASH          ${_grouped(400000)}',
      'KEMBALIAN     ${_grouped(400000 - sum)}',
    ].join('\n'));
    expect(r.merchant.value, 'Superindo Kalibata');
    expect(r.amount.value, sum);
    expect(r.amount.confidence, FieldConfidence.high);
    expect(r.items, hasLength(25));
    expect(r.date.value, DateTime(2026, 9, 12));
  });

  test('label and value split across lines by OCR layout', () {
    final r = parse('''
ALFAMART
05-09-26 10:11
TEH BOTOL 2X       9.000
TOTAL BELANJA
Rp 9.000
TUNAI
Rp 10.000
KEMBALIAN
Rp 1.000
''');
    expect(r.amount.value, 9000);
    expect(r.date.value, DateTime(2026, 9, 5));
    expect(r.breakdown.change, 1000);
  });

  test('English receipt with month-first date', () {
    final r = parse('''
Starbucks Coffee
Grand Indonesia
Sep 21, 2026 3:45 PM
Caffe Latte Grande    58,000
Subtotal              58,000
Tax 10%                5,800
Total                 63,800
Visa ****1234         63,800
''');
    expect(r.merchant.value, 'Starbucks Coffee');
    expect(r.amount.value, 63800);
    expect(r.date.value, DateTime(2026, 9, 21));
  });

  test('legal entity header falls back to the brand line below', () {
    final r = parse('''
PT SUMBER ALFARIA TRIJAYA TBK
ALFAMIDI CIPETE
JL. CIPETE RAYA 8
Tanggal 3 Agustus 2026
SUSU UHT            18.900
JUMLAH              18.900
''');
    expect(r.merchant.value, 'Alfamidi Cipete');
    expect(r.amount.value, 18900);
    expect(r.date.value, DateTime(2026, 8, 3));
  });

  test('noisy low-light OCR: look-alike digits and misspelled labels', () {
    final r = parse('''
B4KSO BENGKEL
Jl. Mawar no 3
21/O9/2026 12:1O
Bakso urat       2B.OOO
Es jeruk          8.0O0
T0TAI            36.OOO
TUNAl            5O.OOO
KEMBAII          14.OOO
''');
    expect(r.amount.value, 36000);
    expect(r.amount.confidence, isNot(FieldConfidence.low));
    expect(r.date.value, DateTime(2026, 9, 21));
    expect(r.breakdown.change, 14000);
  });

  test('change and cash never win over the total', () {
    final r = parse('''
TOKO MAKMUR JAYA
KEMBALI     150.000
TUNAI       200.000
TOTAL        50.000
''');
    expect(r.amount.value, 50000);
  });

  test('no total label: derives from subtotal breakdown with medium confidence', () {
    final r = parse('''
RM PADANG SEDERHANA
Nasi Rendang      30.000
Teh Tawar          5.000
SUBTOTAL          35.000
PPN 11%            3.850
''');
    expect(r.amount.value, 38850);
    expect(r.amount.confidence, FieldConfidence.medium);
  });

  test('empty text yields empty parse', () {
    final r = parse('   \n  ');
    expect(r.isEmpty, isTrue);
    expect(r.amount.isPresent, isFalse);
  });
}

String _grouped(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}
