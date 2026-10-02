import 'package:finbro_app/features/scanner/domain/date_time_parser.dart';
import 'package:finbro_app/features/scanner/domain/scan_models.dart';
import 'package:finbro_app/features/scanner/domain/text_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 30, 12);

  group('parseIdrAmount', () {
    const cases = {
      'Rp 35.000': 35000,
      'Rp35.000': 35000,
      '35,000': 35000,
      '35.000,00': 35000,
      '1,250,000.00': 1250000,
      'IDR 1.250.000': 1250000,
      'Rp 35.000,-': 35000,
      '35000': 35000,
      '12.500,50': 12501,
      '12.500,49': 12500,
      'Rp. 7.500': 7500,
    };
    cases.forEach((input, expected) {
      test(input, () => expect(parseIdrAmount(input), expected));
    });

    test('rejects non-amounts', () {
      expect(parseIdrAmount('abc'), isNull);
      expect(parseIdrAmount(''), isNull);
      expect(parseIdrAmount('Rp'), isNull);
    });
  });

  group('normalizeOcrLine', () {
    test('repairs look-alike characters inside numbers', () {
      final n = normalizeOcrLine('TOTAL Rp 35.O00');
      expect(n.text, 'TOTAL Rp 35.000');
      expect(n.corrected, isTrue);
    });

    test('leaves words alone', () {
      final n = normalizeOcrLine('SOTO AYAM BOS');
      expect(n.text, 'SOTO AYAM BOS');
      expect(n.corrected, isFalse);
    });

    test('joins split thousands and separates the Rp prefix', () {
      expect(normalizeOcrLine('TOTAL Rp35. 000').text, 'TOTAL Rp 35.000');
    });
  });

  group('findAmounts', () {
    test('ignores dates, times, percentages and long ids', () {
      expect(findAmounts('25/09/2026 14:32').map((a) => a.value), isEmpty);
      expect(findAmounts('PPN 11%').map((a) => a.value), isEmpty);
      expect(findAmounts('No. Ref 1234567890123').map((a) => a.value), isEmpty);
    });

    test('reads currency and grouped amounts', () {
      final a = findAmounts('2 x 15.000   Rp 30.000');
      expect(a.map((e) => e.value), [2, 15000, 30000]);
      expect(a.last.hasCurrency, isTrue);
    });

    test('negative discount', () {
      final a = findAmounts('DISKON  -5.000').single;
      expect(a.value, 5000);
      expect(a.negative, isTrue);
    });
  });

  group('keyword matching', () {
    test('OCR digit look-alikes map back to letters', () {
      expect(keywordWords('T0TAL BAYAR'), ['TOTAL', 'BAYAR']);
    });

    test('fuzzy tolerates one edit on long words only', () {
      expect(hasPhrase(keywordWords('TOTAI'), 'TOTAL'), isTrue);
      expect(hasPhrase(keywordWords('JUMLAN'), 'JUMLAH'), isTrue);
      expect(hasPhrase(keywordWords('TAX'), 'TAG'), isFalse);
      expect(hasPhrase(keywordWords('PENERIMA'), 'MENERIMA', fuzzy: false), isFalse);
    });
  });

  group('dates', () {
    DateTime? first(String s) => findDates(s, now: now).firstOrNull?.date;

    test('numeric formats (Indonesian day-first)', () {
      expect(first('25/09/2026'), DateTime(2026, 9, 25));
      expect(first('25-09-26'), DateTime(2026, 9, 25));
      expect(first('2026-09-25'), DateTime(2026, 9, 25));
      expect(first('05.09.2026'), DateTime(2026, 9, 5));
    });

    test('month names in Indonesian and English', () {
      expect(first('25 Sep 2026'), DateTime(2026, 9, 25));
      expect(first('25 September 2026'), DateTime(2026, 9, 25));
      expect(first('3 Agustus 2026'), DateTime(2026, 8, 3));
      expect(first('12 Mei 2026'), DateTime(2026, 5, 12));
      expect(first('1 Okt 2025'), DateTime(2025, 10, 1));
      expect(first('7 Des 2025'), DateTime(2025, 12, 7));
      expect(first('Sep 25, 2026'), DateTime(2026, 9, 25));
    });

    test('day/month without year before a time takes the latest past year', () {
      expect(first('25/09 14:32'), DateTime(2026, 9, 25));
      expect(first('28/12 09:00'), DateTime(2025, 12, 28));
    });

    test('future dates are low confidence', () {
      expect(findDates('25/12/2026', now: now).single.confidence, FieldConfidence.low);
    });

    test('invalid calendar dates are rejected', () {
      expect(first('31/02/2026'), isNull);
    });

    test('time HH:mm and HH.mm next to a date', () {
      expect(findTime('14:32')!.time, const ClockTime(14, 32));
      expect(findTime('25.09.2026 14.32')!.time, const ClockTime(14, 32));
      expect(findTime('TOTAL 14.500'), isNull);
    });

    test('pickDateTime prefers labelled date and ignores expiry', () {
      final r = pickDateTime([
        'Berlaku s/d 31/12/2026',
        'Tanggal: 24/09/2026',
        'Jam: 19:05',
      ], now: now);
      expect(r.date.value, DateTime(2026, 9, 24));
      expect(r.time.value, const ClockTime(19, 5));
    });

    test('pickDateTime drops dates outside the review picker range', () {
      DateTime? picked(List<String> lines) => pickDateTime(lines, now: now).date.value;
      // OCR "98" read as 2098, and pre-2000 dates, are not proposed.
      expect(picked(['Tanggal: 12/05/98']), isNull);
      expect(picked(['Tanggal: 31/12/1999']), isNull);
      expect(picked(['Tanggal: 01/10/2027']), isNull);
      // Boundaries [2000-01-01, now + 365 days] are kept.
      expect(picked(['Tanggal: 01/01/2000']), DateTime(2000, 1, 1));
      expect(picked(['Tanggal: 30/09/2027']), DateTime(2027, 9, 30));
      // An out-of-range date does not shadow a valid one further down.
      expect(picked(['Tanggal: 12/05/98', '24/09/2026 19:05']), DateTime(2026, 9, 24));
    });
  });
}
