import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';
import 'package:simpastil/shared/format/clock.dart';

void main() {
  final en = AppLocalizationsEn();
  final ro = AppLocalizationsRo();

  test('the Romanian days-taken summary never reads "o zi"', () {
    expect(ro.tm_daysTaken(1, 1), '1 din 1 zi');
    expect(ro.tm_daysTaken(0, 14), '0 din 14 zile');
    expect(ro.tm_daysTaken(5, 20), '5 din 20 de zile');
    expect(ro.tm_daysTakenSpoken(1, 1), contains('1 din 1 zi'));
    expect(en.tm_daysTaken(1, 1), '1 of 1 day');
    expect(en.tm_daysTaken(3, 14), '3 of 14 days');
  });

  test('the Add stock unit suffix is localized', () {
    expect(stockUnitSuffix(en, 'tablet'), 'tablets');
    expect(stockUnitSuffix(ro, 'tablets'), 'comprimate');
    expect(stockUnitSuffix(ro, 'comprimat'), 'comprimate');
    expect(stockUnitSuffix(ro, 'capsule'), 'capsule');
    expect(stockUnitSuffix(ro, 'pastile'), 'pastile');
    expect(stockUnitSuffix(ro, 'ml'), 'ml');
  });

  test('a separator stays attached to the item after it', () {
    final out = keepSeparatorsAttached('2:58 PM · 3:10 PM · 3:22 PM');
    expect(out, '2:58 PM ·\u00A03:10 PM ·\u00A03:22 PM');
    expect(out.contains(' · '), isFalse);
  });

  for (final lang in ['en', 'ro']) {
    test('the delete-account text is device-neutral in $lang', () {
      final arb =
          jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
              as Map<String, dynamic>;
      final word = lang == 'en' ? 'phone' : 'telefon';
      for (final key in [
        'acct_deleteBody',
        'acct_deleteOthers',
        'acct_countDevices',
      ]) {
        expect((arb[key] as String).toLowerCase(), isNot(contains(word)));
      }
    });
  }
}
