import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/notifications/next_reminders.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/features/settings/presentation/next_reminders_card.dart';
import 'package:simpastil/features/settings/presentation/reminder_privacy_settings.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../../helpers/planned_dose_fixture.dart';

const _userId = 'next-card-user';
const _alex = '00000000-0000-4000-8000-0000000000a1';
const _sam = '00000000-0000-4000-8000-0000000000b2';

/// A moment in the test machine's own time zone, the way the lists read it.
DateTime _local(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 9, day, hour, minute);

typedef _Dose = ({
  String id,
  DateTime at,
  String pill,
  String profileId,
  String profileName,
});

_Dose _dose(
  String id,
  DateTime at, {
  String pill = 'Fictional vitamin',
  String profileId = _alex,
  String profileName = 'Alex',
}) => (
  id: id,
  at: at,
  pill: pill,
  profileId: profileId,
  profileName: profileName,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tz_data.initializeTimeZones();
    await initializeDateFormatting('en');
    await initializeDateFormatting('ro');
  });

  group('reminderWhenLabel', () {
    final en = AppLocalizationsEn();
    final ro = AppLocalizationsRo();
    // A Thursday, in the middle of the morning.
    final now = _local(24, 10);

    String label(
      AppLocalizations l,
      DateTime at, {
      String time = '23:00',
      String locale = 'en',
    }) => reminderWhenLabel(l, at: at, now: now, time: time, locale: locale);

    test('says tonight from six in the evening, today before it', () {
      expect(label(en, _local(24, 23)), 'Tonight 23:00');
      expect(label(en, _local(24, 18)), 'Tonight 23:00');
      expect(label(en, _local(24, 17, 59), time: '17:59'), 'Today 17:59');
      expect(label(en, _local(24, 11), time: '11:00'), 'Today 11:00');
    });

    test('counts days on the calendar, not in twenty-four hour steps', () {
      // Late evening to early morning is the next day, only hours apart.
      final late = _local(24, 23, 30);
      expect(
        reminderWhenLabel(
          en,
          at: _local(25, 6),
          now: late,
          time: '06:00',
          locale: 'en',
        ),
        'Tomorrow 06:00',
      );
      expect(label(en, _local(25, 8), time: '08:00'), 'Tomorrow 08:00');
    });

    test('names the weekday within the week and the date after it', () {
      expect(label(en, _local(26, 23)), 'Sat 23:00');
      expect(label(en, _local(30, 8), time: '08:00'), 'Wed 08:00');
      // Seven days out the weekday would repeat today's: use the date.
      expect(
        label(en, DateTime(2026, 10, 1, 18), time: '18:00'),
        'Oct 1 18:00',
      );
    });

    test('reads in Romanian', () {
      expect(label(ro, _local(24, 23), locale: 'ro'), 'Diseară 23:00');
      expect(
        label(ro, _local(24, 9), time: '09:00', locale: 'ro'),
        'Azi 09:00',
      );
      expect(
        label(ro, _local(25, 8), time: '08:00', locale: 'ro'),
        'Mâine 08:00',
      );
      expect(label(ro, _local(26, 23), locale: 'ro'), startsWith('sâm'));
      expect(
        label(ro, DateTime(2026, 10, 1, 18), time: '18:00', locale: 'ro'),
        '1 oct. 18:00',
      );
    });
  });

  group('Next reminders and Preview cards', () {
    Future<NextRemindersSource> sourceOf(
      WidgetTester tester, {
      List<_Dose> doses = const [],
      bool fullDetails = true,
      Set<String> people = const {_alex},
    }) async {
      final source = await tester.runAsync(() async {
        final db = AppDatabase.forTesting();
        try {
          final now = DateTime.utc(2026, 9, 24);
          await db.usersDao.upsert(
            UsersCompanion.insert(
              id: _userId,
              email: 'next-card@test.invalid',
              createdAt: now,
              updatedAt: now,
            ),
          );
          final rows = <MedicationOccurrence>[];
          for (final dose in doses) {
            rows.add(
              await storePlannedDose(
                db,
                userId: _userId,
                id: dose.id,
                at: dose.at.toUtc(),
                now: now,
                pill: dose.pill,
                profileId: dose.profileId,
                profileName: dose.profileName,
                scheduleId: 'schedule-${dose.id}',
              ),
            );
          }
          return NextRemindersSource(
            userId: _userId,
            identity: null,
            activeProfileIds: people,
            occurrences: rows,
            preferences: ReminderPreferences(fullDetails: fullDetails),
          );
        } finally {
          await db.close();
        }
      });
      return source!;
    }

    Future<void> pumpCards(
      WidgetTester tester, {
      required Stream<NextRemindersSource> source,
      DateTime Function()? clock,
      bool savedFullDetails = true,
      Locale locale = const Locale('en'),
      TextScaler textScaler = TextScaler.noScaling,
      Size size = const Size(412, 915),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nextRemindersSourceProvider.overrideWith((ref) => source),
            reminderDisplayPreferencesProvider.overrideWith(
              (ref) async => ReminderPreferences(fullDetails: savedFullDetails),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: textScaler, alwaysUse24HourFormat: true),
              child: child!,
            ),
            home: Scaffold(
              body: NextRemindersScope(
                clock: clock ?? () => _local(24, 10),
                child: const SingleChildScrollView(
                  child: Column(
                    children: [NextRemindersCard(), ReminderPreviewCard()],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final preview = find.byKey(const ValueKey('reminder-preview'));
    Finder inPreview(Finder finder) =>
        find.descendant(of: preview, matching: finder);

    testWidgets('lists the next reminders nearest first with their times', (
      tester,
    ) async {
      final source = await sourceOf(
        tester,
        doses: [
          _dose('sat', _local(26, 23), pill: 'Saturday pill'),
          _dose('tonight', _local(24, 23), pill: 'Evening pill'),
          _dose('tomorrow', _local(25, 8), pill: 'Morning pill'),
        ],
      );
      await pumpCards(tester, source: Stream.value(source));
      expect(find.text('Next reminders on this device'), findsOneWidget);
      final rows = ['tonight', 'tomorrow', 'sat'];
      final tops = [
        for (final id in rows)
          tester.getTopLeft(find.byKey(ValueKey('next-$id'))).dy,
      ];
      expect(tops, [...tops]..sort());
      expect(find.text('Evening pill'), findsOneWidget);
      expect(find.textContaining('Tonight'), findsOneWidget);
      expect(find.textContaining('Tomorrow'), findsOneWidget);
      expect(find.textContaining('Sat '), findsOneWidget);
      expect(find.text('10 mg'), findsNWidgets(3));
      // One person on this device: the rows do not repeat whose dose it is.
      expect(find.textContaining('Alex'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('names the person when several are switched on', (
      tester,
    ) async {
      final source = await sourceOf(
        tester,
        doses: [
          _dose('alex', _local(24, 22)),
          _dose('sam', _local(24, 23), profileId: _sam, profileName: 'Sam'),
        ],
        people: const {_alex, _sam},
      );
      await pumpCards(tester, source: Stream.value(source));
      expect(find.text('10 mg · Alex'), findsOneWidget);
      expect(find.text('10 mg · Sam'), findsOneWidget);
    });

    testWidgets('reads in Romanian', (tester) async {
      final source = await sourceOf(
        tester,
        doses: [_dose('tonight', _local(24, 23))],
      );
      await pumpCards(
        tester,
        source: Stream.value(source),
        locale: const Locale('ro'),
      );
      expect(
        find.text('Următoarele mementouri pe acest dispozitiv'),
        findsOneWidget,
      );
      expect(find.text('Diseară 23:00'), findsOneWidget);
      expect(find.text('Previzualizare'), findsOneWidget);
    });

    testWidgets('says so when nothing is planned', (tester) async {
      final source = await sourceOf(tester);
      await pumpCards(tester, source: Stream.value(source));
      expect(
        find.text('No reminders are planned for the next 30 days.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('next-tonight')), findsNothing);
    });

    testWidgets('says why when nobody is switched on', (tester) async {
      final source = await sourceOf(
        tester,
        doses: [_dose('tonight', _local(24, 23))],
        people: const {},
      );
      await pumpCards(tester, source: Stream.value(source));
      expect(
        find.text(
          'No one is switched on for reminders on this device, so none are '
          'planned.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('next-tonight')), findsNothing);
    });

    testWidgets('shows a quiet placeholder while it reads', (tester) async {
      await pumpCards(tester, source: const Stream.empty());
      expect(find.byKey(const ValueKey('next-loading')), findsOneWidget);
      // With no plan yet the preview is the example, and says so.
      expect(
        find.text('An example. No reminder is planned yet.'),
        findsOneWidget,
      );
    });

    testWidgets('offers a retry when the read fails', (tester) async {
      await pumpCards(
        tester,
        source: Stream<NextRemindersSource>.error(StateError('fictional')),
      );
      expect(
        find.text('The planned reminders could not be read.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });

    group('preview', () {
      testWidgets('is the next reminder in its own words, with its actions', (
        tester,
      ) async {
        final source = await sourceOf(
          tester,
          doses: [_dose('tonight', _local(24, 23), pill: 'Evening pill')],
        );
        await pumpCards(tester, source: Stream.value(source));
        expect(preview, findsOneWidget);
        expect(inPreview(find.textContaining('Evening pill')), findsWidgets);
        expect(inPreview(find.text('Taken')), findsOneWidget);
        expect(inPreview(find.text('Snooze')), findsOneWidget);
        expect(inPreview(find.text('Skip')), findsOneWidget);
        expect(inPreview(find.text('Open')), findsNothing);
        expect(
          find.text('Your next reminder, as it will appear.'),
          findsOneWidget,
        );
      });

      testWidgets('keeps names and care actions off when private', (
        tester,
      ) async {
        final source = await sourceOf(
          tester,
          doses: [_dose('tonight', _local(24, 23), pill: 'Evening pill')],
          fullDetails: false,
        );
        await pumpCards(tester, source: Stream.value(source));
        expect(preview, findsOneWidget);
        expect(inPreview(find.textContaining('Evening pill')), findsNothing);
        expect(inPreview(find.textContaining('10 mg')), findsNothing);
        expect(inPreview(find.text('A gentle reminder')), findsOneWidget);
        expect(inPreview(find.text('Open')), findsOneWidget);
        expect(inPreview(find.text('Taken')), findsNothing);
        expect(inPreview(find.text('Snooze')), findsNothing);
        expect(inPreview(find.text('Skip')), findsNothing);
      });

      testWidgets('follows the privacy choice when it changes', (tester) async {
        final doses = [_dose('tonight', _local(24, 23), pill: 'Evening pill')];
        final full = await sourceOf(tester, doses: doses);
        final private = await sourceOf(
          tester,
          doses: doses,
          fullDetails: false,
        );
        final changes = StreamController<NextRemindersSource>();
        addTearDown(changes.close);
        await pumpCards(tester, source: changes.stream);
        changes.add(full);
        await tester.pumpAndSettle();
        expect(inPreview(find.text('Taken')), findsOneWidget);
        expect(inPreview(find.textContaining('Evening pill')), findsWidgets);
        changes.add(private);
        await tester.pumpAndSettle();
        expect(inPreview(find.text('Open')), findsOneWidget);
        expect(inPreview(find.text('Taken')), findsNothing);
        expect(inPreview(find.textContaining('Evening pill')), findsNothing);
        // The list itself keeps naming the medicine: it is inside the app.
        expect(find.text('Evening pill'), findsOneWidget);
      });

      testWidgets('shows an example that follows the privacy choice', (
        tester,
      ) async {
        final empty = await sourceOf(tester, fullDetails: false);
        await pumpCards(tester, source: Stream.value(empty));
        expect(
          find.text('An example. No reminder is planned yet.'),
          findsOneWidget,
        );
        expect(inPreview(find.text('A gentle reminder')), findsOneWidget);
        expect(inPreview(find.text('Open')), findsOneWidget);
        expect(inPreview(find.text('Taken')), findsNothing);
      });

      testWidgets('uses the saved choice while the plan is still being read', (
        tester,
      ) async {
        await pumpCards(
          tester,
          source: const Stream.empty(),
          savedFullDetails: false,
        );
        expect(inPreview(find.text('A gentle reminder')), findsOneWidget);
        expect(inPreview(find.text('Open')), findsOneWidget);
        expect(inPreview(find.text('Taken')), findsNothing);
      });

      testWidgets('shows the example with names when they are chosen', (
        tester,
      ) async {
        final empty = await sourceOf(tester);
        await pumpCards(tester, source: Stream.value(empty));
        expect(inPreview(find.text('Taken')), findsOneWidget);
        expect(inPreview(find.text('Open')), findsNothing);
      });
    });

    testWidgets('plans again when the first reminder has passed', (
      tester,
    ) async {
      final source = await sourceOf(
        tester,
        doses: [
          _dose('soon', _local(24, 23), pill: 'Soon pill'),
          _dose('later', _local(25, 8), pill: 'Later pill'),
        ],
      );
      var now = _local(24, 22, 59);
      await pumpCards(tester, source: Stream.value(source), clock: () => now);
      expect(find.byKey(const ValueKey('next-soon')), findsOneWidget);
      // The page stays open past the time of the first reminder.
      now = _local(24, 23, 1);
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('next-soon')), findsNothing);
      expect(find.byKey(const ValueKey('next-later')), findsOneWidget);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('fits a phone at text scale $scale without overflow', (
        tester,
      ) async {
        final source = await sourceOf(
          tester,
          doses: [
            _dose(
              'long',
              _local(24, 23),
              pill: 'A fictional medicine with a very long name indeed',
              profileName: 'Alexandra-Maria',
            ),
            _dose('other', _local(26, 23), profileId: _sam, profileName: 'Sam'),
          ],
          people: const {_alex, _sam},
        );
        await pumpCards(
          tester,
          source: Stream.value(source),
          size: const Size(360, 800),
          textScaler: TextScaler.linear(scale),
          locale: const Locale('ro'),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
