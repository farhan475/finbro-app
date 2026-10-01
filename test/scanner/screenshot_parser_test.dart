import 'package:finbro_app/core/database/enums.dart';
import 'package:finbro_app/features/scanner/domain/scan_models.dart';
import 'package:finbro_app/features/scanner/domain/screenshot_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 30, 12);
  ScanParse parse(String text) => const ScreenshotParser().parse(text, now: now);

  test('BCA mobile m-Transfer', () {
    final r = parse('''
m-Transfer
BERHASIL
25/09 14:32:10
Ke BCA - 1234567890
BUDI SANTOSO
Rp 1.250.000,00
Berita: bayar kos
No. Ref 2509ABC123456
''');
    expect(r.amount.value, 1250000);
    expect(r.amount.confidence, FieldConfidence.high);
    expect(r.status.value, PaymentStatus.success);
    expect(r.direction.value, TransactionType.expense);
    expect(r.merchant.value, 'Budi Santoso');
    expect(r.provider.value, WalletProvider.bca);
    expect(r.date.value, DateTime(2026, 9, 25));
    expect(r.time.value, const ClockTime(14, 32));
    expect(r.reference.value, '2509ABC123456');
  });

  test('GoPay payment to merchant', () {
    final r = parse('''
Pembayaran berhasil
Rp35.000
Kopi Kenangan - Tebet
25 Sep 2026, 08:15
Metode pembayaran
Saldo GoPay
Rp35.000
ID Transaksi
A120926XYZ889
''');
    expect(r.amount.value, 35000);
    expect(r.status.value, PaymentStatus.success);
    expect(r.direction.value, TransactionType.expense);
    expect(r.merchant.value, 'Kopi Kenangan');
    expect(r.provider.value, WalletProvider.gopay);
    expect(r.date.value, DateTime(2026, 9, 25));
    expect(r.time.value, const ClockTime(8, 15));
    expect(r.reference.value, 'A120926XYZ889');
  });

  test('OVO transfer with admin fee: amount excludes fee lines', () {
    final r = parse('''
Transfer Berhasil
Penerima
SITI AMINAH
OVO 0812****7788
Nominal Transfer   Rp 200.000
Sumber Dana       OVO Cash
Biaya Admin        Rp 2.500
Total              Rp 202.500
20 September 2026 19:44
No. Referensi 9981234567
''');
    expect(r.amount.value, 202500);
    expect(r.merchant.value, 'Siti Aminah');
    expect(r.direction.value, TransactionType.expense);
    expect(r.provider.value, WalletProvider.ovo);
    expect(r.reference.value, '9981234567');
  });

  test('DANA incoming money is income', () {
    final r = parse('''
DANA
Dana Masuk
+Rp 150.000
Dari
ANDI WIJAYA
Sukses
18 Sep 2026 • 10:02
ID Transaksi 20260918101234
''');
    expect(r.amount.value, 150000);
    expect(r.direction.value, TransactionType.income);
    expect(r.merchant.value, 'Andi Wijaya');
    expect(r.provider.value, WalletProvider.dana);
    expect(r.status.value, PaymentStatus.success);
    expect(r.time.value, const ClockTime(10, 2));
  });

  test('ShopeePay payment', () {
    final r = parse('''
Pembayaran Sukses
ShopeePay
Total Pembayaran
Rp 89.900
Merchant
Toko Sepatu Keren
Waktu Pembayaran 22-09-2026 21:10
No. Pesanan 220926AB12CD
''');
    expect(r.amount.value, 89900);
    expect(r.merchant.value, 'Toko Sepatu Keren');
    expect(r.provider.value, WalletProvider.shopeePay);
    expect(r.date.value, DateTime(2026, 9, 22));
    expect(r.time.value, const ClockTime(21, 10));
  });

  test('SeaBank transfer; recipient label is not read as income', () {
    final r = parse('''
SeaBank
Transfer Berhasil
Rp 500.000
Nama Penerima
RINA KARTIKA
Bank Tujuan BRI
Tanggal Transaksi 15 Sep 2026 09:30
''');
    expect(r.amount.value, 500000);
    expect(r.direction.value, TransactionType.expense);
    expect(r.merchant.value, 'Rina Kartika');
    expect(r.provider.value, WalletProvider.seaBank);
  });

  test('Jago incoming transfer', () {
    final r = parse('''
Bank Jago
Uang Masuk
Rp 3.000.000
Diterima dari
PT MAJU MUNDUR
Kantong Utama
01 Sep 2026 08:00
''');
    expect(r.amount.value, 3000000);
    expect(r.direction.value, TransactionType.income);
    expect(r.merchant.value, 'PT Maju Mundur');
    expect(r.provider.value, WalletProvider.jago);
  });

  test('failed status is reported', () {
    final r = parse('''
Transaksi Gagal
Rp 75.000
Ke GoPay 0812345678
10 Sep 2026 12:00
''');
    expect(r.status.value, PaymentStatus.failed);
    expect(r.amount.value, 75000);
  });

  test('generic noisy screenshot: amount repaired, lower confidence', () {
    final r = parse('''
Transaksi Berhasil
Rp 12O.OOO
Kepada: WARUNG MAKAN BU SRI
Tanggal 12/09/2026
''');
    expect(r.amount.value, 120000);
    expect(r.amount.confidence, isNot(FieldConfidence.high));
    expect(r.merchant.value, 'Warung Makan Bu Sri');
    expect(r.direction.value, TransactionType.expense);
    expect(r.date.value, DateTime(2026, 9, 12));
  });
}
