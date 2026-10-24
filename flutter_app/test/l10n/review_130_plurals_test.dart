import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_extras_fields.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';

void main() {
  final en = AppLocalizationsEn();
  final ro = AppLocalizationsRo();

  test('English limit and day strings take the singular', () {
    expect(
      en.mx_overDaily('X', 1, 1),
      'X: 1 dose in the last 24 hours. Your limit is 1.',
    );
    expect(en.mx_overDaily('X', 4, 3), contains('4 doses'));
    expect(en.mx_overGap('X', '1', 1), contains('1 hour ago'));
    expect(en.mx_overGap('X', '4', 4), contains('4 hours ago'));
    expect(en.mx_overGap('X', '1.5', 1.5), contains('1.5 hours ago'));
    expect(en.mx_gapLine('1', 1), 'At least 1 hour apart');
    expect(en.mx_gapLine('4.5', 4.5), 'At least 4.5 hours apart');
    expect(en.tm_daysTaken(1, 1), '1 of 1 day');
    expect(en.tm_daysTaken(3, 14), '3 of 14 days');
    expect(en.tm_daysTakenSpoken(1, 1), 'Every dose taken on 1 of 1 day');
  });

  test('Romanian day, hour and doses use one, few and other with "de"', () {
    expect(ro.tm_daysTaken(1, 1), '1 din 1 zi');
    expect(ro.tm_daysTaken(3, 14), '3 din 14 zile');
    expect(ro.tm_daysTaken(5, 21), '5 din 21 de zile');
    expect(ro.tm_daysTakenSpoken(2, 20), contains('2 din 20 de zile'));
    expect(ro.mx_gapLine('1', 1), 'La cel puțin 1 oră distanță');
    expect(ro.mx_gapLine('4', 4), 'La cel puțin 4 ore distanță');
    expect(ro.mx_gapLine('1,5', 1.5), 'La cel puțin 1,5 ore distanță');
    expect(ro.mx_gapLine('20', 20), 'La cel puțin 20 de ore distanță');
    expect(ro.mx_overGap('X', '2', 2), contains('2 ore.'));
    expect(ro.mx_overDaily('X', 1, 1), startsWith('X: o doză '));
    expect(ro.tm_refillAt(1), contains('rămâne o unitate'));
    expect(ro.tm_refillAt(5), endsWith('rămân 5 unități'));
  });

  test(
    'Romanian left-over strings take a pre-formatted amount without agreement',
    () {
      expect(ro.pills_stockLeft('1½'), 'Rămase: 1½');
      expect(ro.sc_stockLeft('1'), 'Rămase: 1');
      expect(ro.asn_stockLeft('2'), 'Rămase: 2');
      expect(ro.tt_stockLeft('1'), 'Rămase: 1');
      expect(ro.tt_refillSoon('1'), 'De reînnoit curând · rămase: 1');
      expect(ro.stock_lowLeft('1'), 'Redus · rămase: 1');
      expect(ro.stock_needsRecountLeft('1'), 'Rămase: 1 · trebuie renumărat');
      expect(ro.blister_cellFull('A', '1'), 'A, rămase: 1');
      expect(
        ro.blister_cellRefill('A', '1'),
        'A, e timpul să reînnoiești, rămase: 1',
      );
      // No plural form of "rămas" follows the amount any more.
      for (final text in [
        ro.pills_stockLeft('1'),
        ro.sc_stockLeft('1'),
        ro.stock_lowLeft('1'),
      ]) {
        expect(text, isNot(endsWith('rămase')));
      }
    },
  );

  test('gap hours follow the locale decimal separator', () {
    expect(MedicationExtrasEditor.formatGapHours(90), '1.5');
    expect(MedicationExtrasEditor.formatGapHours(90, locale: 'en'), '1.5');
    expect(MedicationExtrasEditor.formatGapHours(90, locale: 'ro'), '1,5');
    expect(MedicationExtrasEditor.formatGapHours(240, locale: 'ro'), '4');
    expect(MedicationExtrasEditor.gapHoursCount(60), isA<int>());
    expect(MedicationExtrasEditor.gapHoursCount(90), 1.5);
  });
}
