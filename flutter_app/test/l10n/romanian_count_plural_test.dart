import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';

void main() {
  test('Romanian day and dose counts add "de" from 20 up', () {
    final l = AppLocalizationsRo();
    expect(l.mx_expiryDetailSoon(1), 'Expiră în o zi');
    expect(l.mx_expiryDetailSoon(19), 'Expiră în 19 zile');
    expect(l.mx_expiryDetailSoon(20), 'Expiră în 20 de zile');
    expect(l.t09_everyN(3), 'La fiecare 3 zile calendaristice');
    expect(l.t09_everyN(28), 'La fiecare 28 de zile calendaristice');
    expect(l.mx_overDaily('Ibuprofen', 4, 3), startsWith('Ibuprofen: 4 doze '));
    expect(
      l.mx_overDaily('Ibuprofen', 21, 20),
      startsWith('Ibuprofen: 21 de doze '),
    );
  });

  test('Romanian count strings use one, few and other forms', () {
    final l = AppLocalizationsRo();
    expect(l.profiles_pillCount(1), '1 medicament');
    expect(l.profiles_pillCount(5), '5 medicamente');
    expect(l.profiles_pillCount(20), '20 de medicamente');
    expect(l.pills_deletedCount(1), '1 medicament șters');
  });
}
