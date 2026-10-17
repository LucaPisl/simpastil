import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_copy.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';

void main() {
  test('low-stock copy is localised and names the medication in full mode', () {
    final en = lowStockReminderCopy(
      AppLocalizationsEn(),
      fullDetails: true,
      pillName: 'Fakeolol',
      dosesLeft: 3,
    );
    expect(en.title, 'Fakeolol is running low');
    expect(en.body, '3 doses left');
    expect(
      lowStockReminderCopy(
        AppLocalizationsEn(),
        fullDetails: true,
        pillName: 'Fakeolol',
        dosesLeft: 1,
      ).body,
      '1 dose left',
    );
    final ro = lowStockReminderCopy(
      AppLocalizationsRo(),
      fullDetails: true,
      pillName: 'Fakeolol',
      dosesLeft: 5,
    );
    expect(ro.title, 'Fakeolol se apropie de final');
    expect(ro.body, 'Au rămas 5 doze');
    expect(
      lowStockReminderCopy(
        AppLocalizationsRo(),
        fullDetails: true,
        pillName: 'X',
        dosesLeft: 20,
      ).body,
      'Au rămas 20 de doze',
    );
  });

  test('private mode never reveals the name or the count', () {
    for (final l in [AppLocalizationsEn(), AppLocalizationsRo()]) {
      final copy = lowStockReminderCopy(
        l,
        fullDetails: false,
        pillName: 'Fakeolol',
        dosesLeft: 3,
      );
      expect(copy, privateReminderCopy(l));
      expect('${copy.title} ${copy.body}', isNot(contains('Fakeolol')));
      expect('${copy.title} ${copy.body}', isNot(contains('3')));
    }
  });
}
