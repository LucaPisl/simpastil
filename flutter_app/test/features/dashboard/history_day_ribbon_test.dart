import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/history_day_ribbon.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';
import 'package:simpastil/shared/scene/dose_bead.dart';

HistoryEntry _entry(
  String id, {
  String? date,
  String? time,
  String state = 'taken',
  String source = 'scheduled',
  DateTime? takenAt,
}) => HistoryEntry(
  doseLogId: id,
  pillName: 'Fictional $id',
  scheduledAt: null,
  takenAt: takenAt,
  plannedLocalDate: date,
  plannedLocalTime: time,
  status: state,
  occurrenceState: state,
  profileName: 'Fictional person',
  scheduleId: id,
  source: source,
);

void main() {
  final today = DateTime(2026, 10, 13, 15, 30);

  test('lists the window newest first, today included, with empty days', () {
    final days = historyRibbonDays(const [], today: today, days: 30);
    expect(days, hasLength(30));
    expect(days.first.date, DateTime(2026, 10, 13));
    expect(days[1].date, DateTime(2026, 10, 12));
    expect(days.last.date, DateTime(2026, 9, 14));
    expect(days.every((d) => d.doses.isEmpty && !d.complete), isTrue);
  });

  test('places each dose at its planned time and counts planned doses', () {
    final days = historyRibbonDays(
      [
        _entry('evening', date: '2026-10-12', time: '18:00:00'),
        _entry('morning', date: '2026-10-12', time: '06:00:00'),
        _entry('noon', date: '2026-10-12', time: '12:00:00', state: 'skipped'),
        _entry(
          'prn',
          date: '2026-10-12',
          source: 'prn',
          takenAt: DateTime(2026, 10, 12, 21),
        ),
        _entry('undated', time: '08:00:00'),
      ],
      today: today,
      days: 3,
    );
    final yesterday = days[1];
    expect(yesterday.doses.map((d) => d.at), [.25, .5, .75, 21 / 24]);
    expect(yesterday.doses.map((d) => d.state), [
      'taken',
      'skipped',
      'taken',
      'taken',
    ]);
    expect(yesterday.doses.last.prn, isTrue);
    expect(yesterday.planned, 3);
    expect(yesterday.taken, 2);
    expect(yesterday.complete, isFalse);
    expect(days[0].doses, isEmpty);
    expect(days[2].doses, isEmpty);
  });

  test('a day is whole only when every planned dose was taken', () {
    final days = historyRibbonDays(
      [
        _entry('a', date: '2026-10-13', time: '08:00:00'),
        _entry('b', date: '2026-10-13', time: '20:00:00'),
        // As-needed doses are never owed, so they neither make nor break it.
        _entry('c', date: '2026-10-11', source: 'prn', takenAt: today),
      ],
      today: today,
      days: 3,
    );
    expect(days[0].complete, isTrue);
    expect(days[2].planned, 0);
    expect(days[2].complete, isFalse);
  });

  test('an entry with no known time stays off the path', () {
    final days = historyRibbonDays(
      [_entry('unknown', date: '2026-10-13', source: 'prn')],
      today: today,
      days: 1,
    );
    expect(days.single.doses, isEmpty);
  });

  test('a dose later today is planned; one gone by is not recorded', () {
    final days = historyRibbonDays(
      [
        _entry('morning', date: '2026-10-13', time: '08:00', state: 'pending'),
        _entry('evening', date: '2026-10-13', time: '20:00', state: 'pending'),
        _entry(
          'yesterday',
          date: '2026-10-12',
          time: '20:00',
          state: 'pending',
        ),
        _entry('prn', date: '2026-10-13', source: 'prn', takenAt: today),
      ],
      today: today,
      days: 2,
    );
    expect(
      [for (final d in days[0].doses) d.bead],
      [DoseBead.unrecorded, DoseBead.asNeeded, DoseBead.planned],
    );
    expect(days[1].doses.single.bead, DoseBead.unrecorded);
  });

  test('a recorded miss is missed, never plain not recorded', () {
    final days = historyRibbonDays(
      [
        _entry('missed', date: '2026-10-12', time: '08:00', state: 'missed'),
        _entry('open', date: '2026-10-12', time: '20:00', state: 'pending'),
      ],
      today: today,
      days: 2,
    );
    expect(
      [for (final d in days[1].doses) d.bead],
      [DoseBead.missed, DoseBead.unrecorded],
    );
    // A miss is still a dose the day owes, so the day is not whole.
    expect(days[1].complete, isFalse);
  });

  test('empty days before the phone knew anyone are unseen', () {
    final days = historyRibbonDays(
      [_entry('restored', date: '2026-10-08', time: '08:00')],
      today: today,
      days: 7,
      seenFrom: DateTime(2026, 10, 10, 14, 20),
    );
    expect(
      {for (final d in days) d.date.day: d.unseen},
      {13: false, 12: false, 11: false, 10: false, 9: true, 8: false, 7: true},
      reason: 'a day with records is never unseen; first-seen day itself is',
    );
    expect(
      historyRibbonDays(const [], today: today, days: 7).any((d) => d.unseen),
      isFalse,
      reason: 'with no first-seen date every day reads as before',
    );
  });

  testWidgets('an unseen tile says whose phone never saw it', (tester) async {
    Future<void> show(String? person) => tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HistoryDayRibbon(
            days: historyRibbonDays(
              const [],
              today: today,
              days: 3,
              seenFrom: DateTime(2026, 10, 12),
            ),
            selected: null,
            person: person,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    await show('Mira');
    expect(
      find.bySemanticsLabel(
        'Sunday, October 11, before Mira was on this phone',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Monday, October 12, no planned doses'),
      findsOneWidget,
    );
    await show(null);
    expect(
      find.bySemanticsLabel(
        'Sunday, October 11, before care began on this phone',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  test('the painter repaints for new beads, halo or well only', () {
    RibbonDayPainter painter(
      List<DoseBead> beads, {
      Color cut = Colors.white,
      bool tray = false,
    }) => RibbonDayPainter(
      beads: [for (final b in beads) (bead: b, color: Colors.green)],
      cut: cut,
      tray: tray,
    );
    const beads = [DoseBead.taken];
    expect(painter(beads).shouldRepaint(painter([...beads])), isFalse);
    expect(painter(beads).shouldRepaint(painter([DoseBead.skipped])), isTrue);
    expect(
      painter(beads).shouldRepaint(painter(beads, cut: Colors.black)),
      isTrue,
    );
    expect(painter(beads).shouldRepaint(painter(beads, tray: true)), isTrue);
  });

  group('on wide windows', () {
    const ribbon = ValueKey('history-day-ribbon');

    Future<void> mountRibbon(WidgetTester tester, Size window) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 688,
                child: HistoryDayRibbon(
                  days: historyRibbonDays(const [], today: today, days: 60),
                  selected: null,
                  person: null,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    double offset(WidgetTester tester) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(ribbon),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;

    testWidgets('only whole day tiles fit the strip, none cut off', (
      tester,
    ) async {
      await mountRibbon(tester, const Size(1205, 753));
      final extent = tester.widget<ListView>(find.byKey(ribbon)).itemExtent!;
      final viewport = tester.getSize(find.byKey(ribbon)).width;
      expect(viewport, 688);
      final tiles = viewport / extent;
      expect(tiles, closeTo(tiles.round(), 1e-9));
      // The tile never shrinks below its natural size to get there.
      expect(extent, greaterThanOrEqualTo(16 * 3.5 + 6));
      // No edge fade: it would dim the outermost day.
      expect(
        find.descendant(
          of: find.byType(HistoryDayRibbon),
          matching: find.byType(ShaderMask),
        ),
        findsNothing,
      );
    });

    testWidgets('a swipe settles on a whole tile', (tester) async {
      await mountRibbon(tester, const Size(753, 1205));
      final extent = tester.widget<ListView>(find.byKey(ribbon)).itemExtent!;
      expect(offset(tester), 0);
      await tester.drag(find.byKey(ribbon), const Offset(90, 0));
      await tester.pumpAndSettle();
      final tilesScrolled = offset(tester) / extent;
      expect(tilesScrolled, greaterThan(0));
      expect(tilesScrolled, closeTo(tilesScrolled.round(), 1e-6));
      await tester.fling(find.byKey(ribbon), const Offset(300, 0), 900);
      await tester.pumpAndSettle();
      final flung = offset(tester) / extent;
      expect(flung, closeTo(flung.round(), 1e-6));
    });

    testWidgets('a phone keeps its natural tile size and the edge fade', (
      tester,
    ) async {
      await mountRibbon(tester, const Size(390, 844));
      final extent = tester.widget<ListView>(find.byKey(ribbon)).itemExtent!;
      expect(extent, 16 * 3.5 + 6);
      expect(
        find.descendant(
          of: find.byType(HistoryDayRibbon),
          matching: find.byType(ShaderMask),
        ),
        findsOneWidget,
      );
    });
  });
}
