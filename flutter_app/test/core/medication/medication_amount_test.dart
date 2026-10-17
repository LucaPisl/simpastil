import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';

void main() {
  test('decimals and fractions retain exact quantities and explicit units', () {
    for (final text in ['0.5', '0,5', '1/2']) {
      final amount = MedicationAmount.known(text, 'tablet');
      expect(amount.numerator, BigInt.one);
      expect(amount.denominator, BigInt.two);
      final reopened = MedicationAmount.fromJson(amount.toJson());
      expect(reopened.quantityText, text);
      expect(reopened.unit, 'tablet');
    }
  });
  test(
    'unknown amount does not invent a quantity, unit or stock conversion',
    () {
      final amount = MedicationAmount.fromJson(
        const MedicationAmount.unknown().toJson(),
      );
      expect(amount.isUnknown, isTrue);
      expect(amount.numerator, isNull);
      expect(amount.unit, isNull);
    },
  );
  test('known amounts require a positive quantity and explicit unit', () {
    expect(() => MedicationAmount.known('1', ''), throwsFormatException);
    expect(() => MedicationAmount.known('0', 'tablet'), throwsFormatException);
    expect(
      () => MedicationAmount.known('1/0', 'tablet'),
      throwsFormatException,
    );
  });

  test('legacy text with one plain quantity and unit reads exactly', () {
    const cases = {
      '1 pastila': ('1', 'pastila'),
      '1mg': ('1', 'mg'),
      '  500 mg  ': ('500', 'mg'),
      '0,5 ml': ('0,5', 'ml'),
      '1/2 tablet': ('1/2', 'tablet'),
      '1 comprimat filmat': ('1', 'comprimat filmat'),
    };
    for (final entry in cases.entries) {
      final amount = MedicationAmount.fromLegacyText(entry.key);
      expect(amount, isNotNull, reason: entry.key);
      expect(amount!.quantityText, entry.value.$1, reason: entry.key);
      expect(amount.unit, entry.value.$2, reason: entry.key);
    }
  });

  test('legacy text carrying a second number is never guessed', () {
    for (final text in [
      '1-2 tablets',
      '2x500mg',
      '2 tablets 500mg',
      '1 to 2 pastile 5mg',
    ]) {
      expect(MedicationAmount.fromLegacyText(text), isNull, reason: text);
    }
  });

  test('legacy text without a quantity and unit stays unreviewed', () {
    for (final text in ['', '   ', 'as needed', 'la nevoie', '2', '0 tablet']) {
      expect(MedicationAmount.fromLegacyText(text), isNull, reason: text);
    }
  });
}
