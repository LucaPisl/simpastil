import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_copy.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';

void main() {
  final locales = <String, AppLocalizations>{
    'en': AppLocalizationsEn(),
    'ro': AppLocalizationsRo(),
  };

  group('dose reminder copy (EN)', () {
    final l = AppLocalizationsEn();

    test('names the medication in the title and the amount in the body', () {
      final copy = doseReminderCopy(
        l,
        fullDetails: true,
        pillName: 'Fakeolol',
        dosage: '1 tablet',
      );
      expect(copy.title, 'Time for Fakeolol');
      expect(copy.body, '1 tablet, when you’re ready');
    });

    test('a missing or blank amount never repeats the name in the body', () {
      for (final dosage in [null, '', '   ']) {
        final copy = doseReminderCopy(
          l,
          fullDetails: true,
          pillName: 'Fakeolol',
          dosage: dosage,
        );
        expect(copy.title, 'Time for Fakeolol');
        expect(copy.body, 'When you’re ready.');
      }
    });

    test('follow-ups say the dose is still waiting, gently', () {
      final copy = doseReminderCopy(
        l,
        fullDetails: true,
        pillName: 'Fakeolol',
        dosage: '1 tablet',
        followUpMinutes: 30,
      );
      expect(copy.title, 'Fakeolol is still waiting');
      expect(copy.body, '1 tablet, only if you haven’t yet');
    });

    test('snoozed reminders keep the name and say why they are back', () {
      final copy = snoozedReminderCopy(
        l,
        fullDetails: true,
        pillName: 'Fakeolol',
      );
      expect(copy.title, 'Time for Fakeolol');
      expect(copy.body, 'Back again, as you asked');
    });
  });

  for (final entry in locales.entries) {
    final l = entry.value;
    group('private copy (${entry.key})', () {
      test('never reveals name, amount or follow-up state', () {
        final variants = [
          doseReminderCopy(
            l,
            fullDetails: false,
            pillName: 'Fakeolol',
            dosage: '250 mg',
          ),
          doseReminderCopy(
            l,
            fullDetails: false,
            pillName: 'Fakeolol',
            dosage: '250 mg',
            followUpMinutes: 15,
          ),
          snoozedReminderCopy(l, fullDetails: false, pillName: 'Fakeolol'),
        ];
        for (final copy in variants) {
          expect(copy, privateReminderCopy(l));
          expect('${copy.title} ${copy.body}', isNot(contains('Fakeolol')));
          expect('${copy.title} ${copy.body}', isNot(contains('250')));
        }
      });
    });

    group('full copy (${entry.key})', () {
      test('is translated, distinct per kind and keeps the name', () {
        final first = doseReminderCopy(
          l,
          fullDetails: true,
          pillName: 'Fakeolol',
          dosage: '1',
        );
        final followUp = doseReminderCopy(
          l,
          fullDetails: true,
          pillName: 'Fakeolol',
          dosage: '1',
          followUpMinutes: 10,
        );
        final snoozed = snoozedReminderCopy(
          l,
          fullDetails: true,
          pillName: 'Fakeolol',
        );
        for (final copy in [first, followUp, snoozed]) {
          expect(copy.title, contains('Fakeolol'));
          expect(copy.body, isNotEmpty);
        }
        expect({first, followUp, snoozed}, hasLength(3));
      });

      test('depends only on its own occurrence', () {
        ReminderCopy build() => doseReminderCopy(
          l,
          fullDetails: true,
          pillName: 'Placebotin',
          dosage: '2 drops',
          followUpMinutes: 0,
        );
        expect(build(), build());
      });
    });
  }

  test('Romanian copy is not English', () {
    final en = doseReminderCopy(
      AppLocalizationsEn(),
      fullDetails: true,
      pillName: 'Fakeolol',
      dosage: '1',
    );
    final ro = doseReminderCopy(
      AppLocalizationsRo(),
      fullDetails: true,
      pillName: 'Fakeolol',
      dosage: '1',
    );
    expect(ro.title, isNot(en.title));
    expect(ro.body, isNot(en.body));
    expect(
      privateReminderCopy(AppLocalizationsRo()),
      isNot(privateReminderCopy(AppLocalizationsEn())),
    );
  });
}
