import 'package:finbro_app/core/database/enums.dart';
import 'package:finbro_app/core/formatting/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatMoney', () {
    test('IDR delegates to the existing whole-rupiah format', () {
      expect(formatMoney(1234567, Currency.idr), 'Rp 1.234.567');
      expect(formatMoney(1234, Currency.idr), 'Rp 1.234');
      expect(formatMoney(-35000, Currency.idr), '-Rp 35.000');
      expect(formatMoney(35000, Currency.idr, signed: true), '+Rp 35.000');
      expect(formatMoney(0, Currency.idr), 'Rp 0');
    });

    test('two-decimal currencies use id_ID grouping and 2 decimals', () {
      expect(formatMoney(123456, Currency.usd), '\$1.234,56');
      expect(formatMoney(123456, Currency.eur), '€1.234,56');
      expect(formatMoney(123456, Currency.sgd), 'S\$1.234,56');
      expect(formatMoney(5, Currency.usd), '\$0,05');
    });

    test('negative and signed variants', () {
      expect(formatMoney(-123456, Currency.usd), '-\$1.234,56');
      expect(formatMoney(123456, Currency.usd, signed: true), '+\$1.234,56');
      expect(formatMoney(-123456, Currency.usd, signed: true), '-\$1.234,56');
      expect(formatMoney(-1234, Currency.eur), '-€12,34');
    });

    test('zero-decimal currencies (JPY) render whole numbers', () {
      expect(formatMoney(1234567, Currency.jpy), '¥1.234.567');
      expect(formatMoney(-500000, Currency.jpy), '-¥500.000');
      expect(formatMoney(500000, Currency.jpy, signed: true), '+¥500.000');
    });
  });

  group('formatMoneyCompact', () {
    test('symbol-prefixed compact labels', () {
      expect(formatMoneyCompact(4800000, Currency.usd), '\$4,8 jt');
      expect(formatMoneyCompact(750000, Currency.sgd), 'S\$750 rb');
      expect(formatMoneyCompact(1200000000, Currency.eur), '€1,2 M');
      expect(formatMoneyCompact(-12500000, Currency.usd), '-\$13 jt');
      expect(formatMoneyCompact(900, Currency.usd), '\$900');
    });

    test('IDR keeps the existing compact style', () {
      expect(formatMoneyCompact(4800000, Currency.idr), '4,8 jt');
      expect(formatMoneyCompact(750000, Currency.idr), '750 rb');
    });
  });

  group('formatRate', () {
    test('renders rupiah per 1 unit of the currency', () {
      expect(formatRate(16250, Currency.usd), '1 USD = Rp 16.250');
      expect(formatRate(18500.4, Currency.eur), '1 EUR = Rp 18.500');
      expect(formatRate(12250, Currency.sgd), '1 SGD = Rp 12.250');
    });
  });

  group('parseRate', () {
    test("Indonesian grouping: '.' is thousands, ',' is decimal", () {
      expect(parseRate('16.250'), 16250, reason: 'was read as 16,25 before');
      expect(parseRate('Rp 1.234.567'), 1234567);
      expect(parseRate('16.250,5'), 16250.5);
      expect(parseRate('105,25'), 105.25);
      expect(parseRate('16250'), 16250);
    });

    test('a lone dot that is not a thousands group is a decimal mark', () {
      expect(parseRate('16250.5'), 16250.5);
      expect(parseRate('0.5'), 0.5);
    });

    test('malformed or empty input is rejected', () {
      expect(parseRate(''), isNull);
      expect(parseRate('Rp'), isNull);
      expect(parseRate('1,2,3'), isNull);
      expect(parseRate('1.2.3'), isNull);
      expect(parseRate('1,5.000'), isNull);
    });

    test('round-trips formatRateInput', () {
      for (final r in [16250.0, 105.25, 0.5, 1234567.89]) {
        expect(parseRate(formatRateInput(r)), r);
      }
    });
  });

  group('currencyFromCode', () {
    test('case-insensitive lookup', () {
      expect(currencyFromCode('usd'), Currency.usd);
      expect(currencyFromCode('USD'), Currency.usd);
      expect(currencyFromCode('Idr'), Currency.idr);
    });

    test('null for null and unknown codes', () {
      expect(currencyFromCode(null), isNull);
      expect(currencyFromCode('xyz'), isNull);
      expect(currencyFromCode(''), isNull);
    });
  });

  group('parseRupiah (unchanged contract)', () {
    test('strips non-digits', () {
      expect(parseRupiah('1.250.000'), 1250000);
      expect(parseRupiah('Rp 35.000'), 35000);
      expect(parseRupiah('35000'), 35000);
    });

    test('null without digits', () {
      expect(parseRupiah('abc'), isNull);
      expect(parseRupiah(''), isNull);
      expect(parseRupiah('-'), isNull);
    });
  });

  group('parseMoney', () {
    test('IDR behaves like parseRupiah', () {
      expect(parseMoney('1.250.000', Currency.idr), 1250000);
      expect(parseMoney('35000', Currency.idr), 35000);
      expect(parseMoney('abc', Currency.idr), isNull);
    });
    test('JPY is whole units', () {
      expect(parseMoney('1.234', Currency.jpy), 1234);
    });
    test('decimal separators: last one wins', () {
      expect(parseMoney('10.24', Currency.usd), 1024);
      expect(parseMoney('10,24', Currency.usd), 1024);
      expect(parseMoney('1.234,56', Currency.usd), 123456);
      expect(parseMoney('1,234.56', Currency.usd), 123456);
    });
    test('no separator means whole units', () {
      expect(parseMoney('10', Currency.usd), 1000);
      expect(parseMoney('1250', Currency.usd), 125000);
    });
    test('rejects too many fractions / separators', () {
      expect(parseMoney('10.245', Currency.usd), isNull);
      expect(parseMoney('1.2.3,4', Currency.usd), isNull);
    });
    test('round-trips with formatMoney', () {
      const amount = 123456;
      final text = formatMoney(amount, Currency.usd).replaceAll(RegExp(r'[^\d.,]'), '');
      expect(parseMoney(text, Currency.usd), amount);
    });
  });
}
