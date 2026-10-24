import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/other_time_sheet.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Opens the sheet from a button and returns what it gave back, or null.
Future<OtherTimeChoice? Function()> _open(
  WidgetTester tester, {
  required DateTime now,
  String plannedLocalDate = '2026-09-30',
  TimeOfDay plannedTime = const TimeOfDay(hour: 9, minute: 0),
  String zone = 'Europe/Bucharest',
  Size size = const Size(412, 915),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  OtherTimeChoice? result;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await showOtherTimeSheet(
                  context,
                  personName: 'Fictional Alex',
                  medicationName: 'Fictional medication',
                  amountLabel: '1 tablet',
                  zone: tz.getLocation(zone),
                  plannedLocalDate: plannedLocalDate,
                  plannedTime: plannedTime,
                  now: () => now,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

String _summary(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('other-time-summary'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('starts on the planned day and time and saves that moment', (
    tester,
  ) async {
    // Two days later, at noon in Bucharest.
    final result = await _open(tester, now: DateTime.utc(2026, 10, 2, 9));
    expect(find.text('When did Fictional Alex take it?'), findsOneWidget);
    expect(_summary(tester), contains('Wednesday, September 30 at 9:00 AM'));
    // The planned day, the day after, and today, as one row of chips.
    for (final day in ['2026-09-30', '2026-10-01', '2026-10-02']) {
      expect(find.byKey(ValueKey('other-time-day-$day')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('other-time-save')));
    await tester.pumpAndSettle();
    final choice = result();
    expect(choice, isA<TakenAtChoice>());
    // 09:00 in Bucharest (UTC+3 in summer time) is 06:00 UTC.
    expect((choice! as TakenAtChoice).at, DateTime.utc(2026, 9, 30, 6));
  });

  testWidgets('another day keeps the time and moves the moment', (
    tester,
  ) async {
    final result = await _open(tester, now: DateTime.utc(2026, 10, 2, 9));
    await tester.tap(find.byKey(const ValueKey('other-time-day-2026-10-01')));
    await tester.pumpAndSettle();
    expect(_summary(tester), contains('Thursday, October 1 at 9:00 AM'));
    await tester.tap(find.byKey(const ValueKey('other-time-save')));
    await tester.pumpAndSettle();
    expect((result()! as TakenAtChoice).at, DateTime.utc(2026, 10, 1, 6));
  });

  testWidgets('a dose not due yet starts on the time it is now', (
    tester,
  ) async {
    // 07:30 in Bucharest, before the 09:00 dose.
    await _open(
      tester,
      now: DateTime.utc(2026, 9, 30, 4, 30),
      plannedTime: const TimeOfDay(hour: 9, minute: 0),
    );
    expect(_summary(tester), contains('at 7:30 AM'));
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('other-time-save')),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('a time still ahead cannot be saved', (tester) async {
    // 09:30 in Bucharest; the planned 09:00 is fine, then pick a later one.
    await _open(tester, now: DateTime.utc(2026, 9, 30, 6, 30));
    await tester.tap(find.byKey(const ValueKey('other-time-change')));
    await tester.pumpAndSettle();
    final material = MaterialLocalizations.of(
      tester.element(find.byType(TimePickerDialog)),
    );
    await tester.tap(find.byTooltip(material.inputTimeModeButtonLabel));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '11');
    await tester.enterText(find.byType(TextField).last, '00');
    await tester.tap(find.text(material.okButtonLabel));
    await tester.pumpAndSettle();
    expect(
      find.text("That time hasn't come yet. Choose an earlier one."),
      findsOneWidget,
    );
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('other-time-save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('Dose details hands over to the full form', (tester) async {
    final result = await _open(tester, now: DateTime.utc(2026, 10, 2, 9));
    await tester.ensureVisible(
      find.byKey(const ValueKey('other-time-details')),
    );
    await tester.tap(find.byKey(const ValueKey('other-time-details')));
    await tester.pumpAndSettle();
    expect(result(), isA<OpenDetailsChoice>());
  });

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('fits a phone at ${scale}x text in dark', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ro'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: OtherTimeForm(
                personName: 'Fictional Alex',
                medicationName: 'Fictional long medication name for review',
                amountLabel: '1 comprimat',
                zone: tz.getLocation('Europe/Bucharest'),
                plannedLocalDate: '2026-09-28',
                plannedTime: const TimeOfDay(hour: 21, minute: 0),
                now: () => DateTime.utc(2026, 10, 2, 9),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final key in ['other-time-save', 'other-time-details']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
    });
  }
}
