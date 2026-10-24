import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/unit_names.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  AppLocalizations l(String code) => lookupAppLocalizations(Locale(code));

  test('a tablet form is named in the app language', () {
    expect(medicationFormName(l('en'), 'Tablet'), 'Tablet');
    expect(medicationFormName(l('ro'), 'Tablet'), 'Comprimat');
    expect(medicationFormName(l('ro'), ' tablets '), 'Comprimat');
    expect(medicationFormName(l('ro'), 'Capsule'), 'Capsulă');
  });

  test('other known forms are localized, either spelling', () {
    expect(medicationFormName(l('ro'), 'Syrup'), 'Sirop');
    expect(medicationFormName(l('en'), 'sirop'), 'Syrup');
    expect(medicationFormName(l('ro'), 'Drops'), 'Picături');
  });

  test('an unknown form is shown as written', () {
    expect(medicationFormName(l('ro'), ' Elixir '), 'Elixir');
  });

  test('every form name starts with a capital, in both languages', () {
    for (final code in ['en', 'ro']) {
      for (final form in [
        'Tablet',
        'tablets',
        'Capsule',
        'Syrup',
        'Drops',
        'Cream',
        'Patch',
      ]) {
        final name = medicationFormName(l(code), form);
        expect(name[0], name[0].toUpperCase(), reason: '$code $form');
      }
    }
    expect(medicationFormName(l('en'), 'Capsule'), 'Capsule');
  });

  test('a unit field shows the app language and stores the unit unchanged', () {
    final ro = l('ro');
    expect(unitFieldText(ro, 'tablet'), 'comprimat');
    expect(unitFieldText(l('en'), 'tablet'), 'tablet');
    expect(unitFieldText(ro, 'mg'), 'mg');
    expect(unitFieldText(ro, null), '');
    // Untouched, the prefilled word stores the original unit, so stock that
    // is counted in "tablet" still matches.
    expect(unitFromFieldText(ro, 'comprimat', 'tablet'), 'tablet');
    expect(unitFromFieldText(ro, ' Comprimate ', 'tablet'), 'tablet');
    // Anything else is stored as typed.
    expect(unitFromFieldText(ro, 'mg', 'tablet'), 'mg');
    expect(unitFromFieldText(ro, ' ml ', null), 'ml');
    expect(unitFromFieldText(ro, 'comprimat', 'mg'), 'comprimat');
  });
}
