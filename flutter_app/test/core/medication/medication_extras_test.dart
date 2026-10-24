import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_extras.dart';

void main() {
  test('the payload carries every key so a null clears', () {
    final payload = MedicationExtras.none.toPayload();
    expect(payload.keys.toSet(), {
      'prnMaxPer24h',
      'prnMinGapMinutes',
      'expiresOn',
      'prescriberName',
      'prescriberPhone',
      'pharmacyName',
      'pharmacyPhone',
    });
    expect(payload.values.every((v) => v == null), isTrue);
  });

  test('copyWith keeps what it is not told to change and can clear', () {
    const base = MedicationExtras(prnMaxPer24h: 3, pharmacyPhone: '+40 21 555');
    final next = base.copyWith(prnMaxPer24h: null, expiresOn: '2027-01-01');
    expect(next.prnMaxPer24h, isNull);
    expect(next.pharmacyPhone, '+40 21 555');
    expect(next.expiresOn, '2027-01-01');
  });

  test('toString never shows names or numbers', () {
    const extras = MedicationExtras(
      prescriberName: 'Dr Fictional',
      prescriberPhone: '+40 700 000 000',
    );
    expect(extras.toString(), isNot(contains('Fictional')));
    expect(extras.toString(), isNot(contains('700')));
  });

  test('phone pattern matches the server', () {
    for (final ok in ['+40 21 555 0100', '(021) 555-0100', '112', '*#21#']) {
      expect(contactPhonePattern.hasMatch(ok), isTrue, reason: ok);
    }
    for (final bad in ['12', 'call me', 'a123', '1' * 41, '12\t34']) {
      expect(contactPhonePattern.hasMatch(bad), isFalse, reason: bad);
    }
  });
}
