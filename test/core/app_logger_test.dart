import 'package:drift/drift.dart' show InvalidDataException, VerificationMeta, VerificationResult;
import 'package:flutter_test/flutter_test.dart';

import 'package:finbro_app/core/utilities/app_logger.dart';

void main() {
  test('InvalidDataException is logged without the rejected row contents', () {
    // Drift embeds the failing row's toString() in the message; the log must
    // not contain column values (amounts, notes, merchant names).
    final error = InvalidDataException(
      'Sorry, TransactionCompanion(amount: Value(1234567), note: '
      'Value(kopi sultan 500rb)) cannot be used for that because: \n'
      '• amount: must not be negative\n',
      {
        const VerificationMeta('amount'):
            const VerificationResult.failure('must not be negative'),
      },
    );

    final line = AppLogger.describeError(error);

    expect(line, isNot(contains('1234567')));
    expect(line, isNot(contains('kopi')));
    expect(line, contains('InvalidDataException'));
    expect(line, contains('1'));
  });

  test('InvalidDataException without details is still described', () {
    final line = AppLogger.describeError(InvalidDataException('row is bad'));
    expect(line, contains('InvalidDataException'));
    expect(line, isNot(contains('row is bad')));
  });

  test('other exceptions keep their message', () {
    expect(AppLogger.describeError(StateError('cek saldo gagal')), contains('cek saldo gagal'));
  });
}
