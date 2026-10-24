import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_summary.dart';

AsNeededDose _dose(int i, MedicationAmount amount) => AsNeededDose(
  occurrenceId: 'o$i',
  pillId: 'p',
  day: DateTime(2026, 10, 22 - i),
  takenAt: null,
  amount: amount,
  note: null,
);

AsNeededSummary _summary(
  List<MedicationAmount> amounts, {
  double value = 14,
  String? unit = 'tablets',
}) => AsNeededSummary(
  pillId: 'p',
  doses: [for (var i = 0; i < amounts.length; i++) _dose(i, amounts[i])],
  today: DateTime(2026, 10, 22),
  stock: AsNeededStock(
    value: value,
    left: '$value',
    unit: unit,
    low: false,
    fraction: null,
  ),
);

void main() {
  final one = MedicationAmount.known('1', 'tablets');
  final two = MedicationAmount.known('2', 'tablets');

  group('daysAtRecentPace', () {
    test('divides the stock by the last 7 days of use', () {
      // 1 + 1 + 2 = 4 tablets a week; 14 tablets last 24.5 days.
      expect(_summary([one, one, two]).daysAtRecentPace, 24);
    });

    test('needs at least 3 doses to judge by', () {
      expect(_summary([one, two]).daysAtRecentPace, isNull);
    });

    test('a plain count spends one per dose', () {
      expect(
        _summary([two, two, two], value: 6, unit: null).daysAtRecentPace,
        14,
      );
    });

    test('is left out when an amount is unknown', () {
      expect(
        _summary([one, one, const MedicationAmount.unknown()]).daysAtRecentPace,
        isNull,
      );
    });

    test('is left out when an amount is in another unit', () {
      expect(
        _summary([
          one,
          one,
          MedicationAmount.known('5', 'ml'),
        ]).daysAtRecentPace,
        isNull,
      );
    });

    test('is left out with nothing left', () {
      expect(_summary([one, one, one], value: 0).daysAtRecentPace, isNull);
      expect(_summary([one, one, one], value: -2).daysAtRecentPace, isNull);
    });

    test('says under a day when the pace outruns the stock', () {
      expect(_summary([two, two, two, two], value: 1).daysAtRecentPace, 0);
    });
  });
}
