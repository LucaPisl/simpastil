import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/history_day_line.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/layouts/tab_hand_off.dart';
import 'package:simpastil/shared/scene/dose_bead.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

HistoryEntry _entry(
  String id,
  String time, {
  String state = 'taken',
  String date = '2026-10-12',
  String source = 'scheduled',
}) => HistoryEntry(
  doseLogId: id,
  pillName: 'Fictional $id',
  scheduledAt: null,
  plannedLocalDate: date,
  plannedLocalTime: time,
  status: state,
  occurrenceState: state,
  profileName: 'Fictional person',
  scheduleId: id,
  occurrenceId: 'occ-$id',
  source: source,
);

DayLineDose _dose(String id, int minute, [DoseBead bead = DoseBead.taken]) =>
    DayLineDose(
      id: id,
      minute: minute,
      bead: bead,
      label: 'label $id',
      occurrenceId: 'occ-$id',
    );

Widget _app(Widget child, {bool quiet = false}) => ProviderScope(
  overrides: [
    sceneClockProvider.overrideWithValue(() => DateTime(2026, 10, 13, 15, 30)),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(alwaysUse24HourFormat: true, disableAnimations: quiet),
        child: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    ),
  ),
);

DayLinePainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(find.byKey(const ValueKey('history-day-line')))
            .painter!
        as DayLinePainter;

void main() {
  group('DayLineFrame', () {
    test('spans 06:00 to 22:00 for an ordinary day', () {
      final frame = DayLineFrame.of([_dose('a', 8 * 60)], width: 320);
      expect((frame.start, frame.end), (360, 1320));
    });

    test('widens to an hour past early and late doses, and to now', () {
      final frame = DayLineFrame.of([
        _dose('a', 5 * 60 + 10),
        _dose('b', 22 * 60 + 30),
      ], width: 320);
      expect((frame.start, frame.end), (240, 1440));
      final late = DayLineFrame.of(const [], width: 320, now: 23 * 60 + 50);
      expect(late.end, 1440);
    });

    test('doses whose dots would touch share one dot', () {
      final frame = DayLineFrame.of([
        _dose('a', 8 * 60),
        _dose('b', 8 * 60 + 20, DoseBead.unrecorded),
        _dose('c', 13 * 60),
      ], width: 320);
      expect(frame.clusters.map((c) => c.doses.length), [2, 1]);
      // The shared dot shows what still needs a look.
      expect(frame.clusters.first.bead, DoseBead.unrecorded);
      expect(frame.clusters.first.key, 'a');
    });

    test('a recorded miss outranks everything in a shared dot', () {
      final frame = DayLineFrame.of([
        _dose('a', 8 * 60, DoseBead.unrecorded),
        _dose('b', 8 * 60 + 20, DoseBead.missed),
        _dose('c', 8 * 60 + 25),
      ], width: 320);
      expect(frame.clusters.single.bead, DoseBead.missed);
    });
  });

  testWidgets('a day\'s doses carry their time, medicine, person and outcome', (
    tester,
  ) async {
    late List<DayLineDose> doses;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            doses = historyLineDoses(
              context,
              [
                _entry('evening', '20:00', state: 'pending'),
                _entry('morning', '08:00', state: 'missed'),
                _entry('noon', '12:00', state: 'skipped'),
                _entry('other day', '09:00', date: '2026-10-11'),
              ],
              day: DateTime(2026, 10, 12),
              now: DateTime(2026, 10, 13, 9),
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(doses.map((d) => d.id), ['morning', 'noon', 'evening']);
    expect(doses.map((d) => d.bead), [
      DoseBead.missed,
      DoseBead.skipped,
      // Yesterday's pending dose is gone by, but nobody recorded it: not
      // recorded, and only a recorded miss is "missed".
      DoseBead.unrecorded,
    ]);
    expect(
      doses.first.label,
      '08:00 · Fictional morning for Fictional person · Missed',
    );
    expect(
      doses.last.label,
      '20:00 · Fictional evening for Fictional person · Not recorded',
    );
  });

  testWidgets('tapping a dot shows its label, and the label opens the story', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        HistoryDayLine(
          day: DateTime(2026, 10, 12),
          doses: [_dose('a', 8 * 60), _dose('b', 18 * 60)],
          onOpen: opened.add,
        ),
      ),
    );
    expect(find.text('label a'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('history-line-dot-a')));
    await tester.pumpAndSettle();
    expect(find.text('label a'), findsOneWidget);
    expect(_painter(tester).selected, 'a');
    await tester.tap(find.text('label a'));
    expect(opened, ['occ-a']);
    // Tapping the dot again puts the label away.
    await tester.tap(find.byKey(const ValueKey('history-line-dot-a')));
    await tester.pumpAndSettle();
    expect(find.text('label a'), findsNothing);
  });

  testWidgets('a screen reader opens a lone dose\'s story straight away', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        HistoryDayLine(
          day: DateTime(2026, 10, 12),
          doses: [_dose('a', 8 * 60)],
          onOpen: opened.add,
        ),
      ),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('label a'));
    expect(node.flagsCollection.isButton, isTrue);
    tester.semantics.tap(find.semantics.byLabel('label a'));
    expect(opened, ['occ-a']);
    handle.dispose();
  });

  testWidgets('changing day slides the old dots off, threads the new on, '
      'then sways once', (tester) async {
    Widget line(DateTime day, List<DayLineDose> doses, int direction) => _app(
      HistoryDayLine(
        day: day,
        doses: doses,
        direction: direction,
        onOpen: (_) {},
      ),
    );
    await tester.pumpWidget(
      line(DateTime(2026, 10, 12), [_dose('a', 8 * 60)], 1),
    );
    await tester.pumpWidget(
      line(DateTime(2026, 10, 11), [_dose('b', 9 * 60)], -1),
    );
    // A ticker counts from its first frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final mid = _painter(tester);
    expect(mid.previous, isNotNull);
    expect(mid.direction, -1);
    expect(mid.change.value, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_painter(tester).previous, isNull);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_painter(tester).sway.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_painter(tester).sway.value, 1);
    expect(DayLinePainter.swayAt(0), 0);
    expect(DayLinePainter.swayAt(1), 0);

    // Days changed in quick succession do not wobble the line.
    await tester.pumpWidget(
      line(DateTime(2026, 10, 10), [_dose('c', 9 * 60)], -1),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(
      line(DateTime(2026, 10, 9), [_dose('d', 9 * 60)], -1),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(_painter(tester).previous, isNull);
    expect(_painter(tester).sway.value, 1);
    await tester.pumpAndSettle();
    // At rest nothing is left running.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet mode changes the day with no slide', (tester) async {
    await tester.pumpWidget(
      _app(
        HistoryDayLine(
          day: DateTime(2026, 10, 12),
          doses: [_dose('a', 8 * 60)],
          onOpen: (_) {},
        ),
        quiet: true,
      ),
    );
    await tester.pumpWidget(
      _app(
        HistoryDayLine(
          day: DateTime(2026, 10, 11),
          doses: [_dose('b', 8 * 60)],
          direction: -1,
          onOpen: (_) {},
        ),
        quiet: true,
      ),
    );
    expect(_painter(tester).previous, isNull);
    expect(_painter(tester).change.value, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_painter(tester).change.value, 1);
    expect(_painter(tester).sway.value, 1);
  });

  testWidgets('the line sags under the pull it is given', (tester) async {
    final pull = ValueNotifier(0.0);
    addTearDown(pull.dispose);
    await tester.pumpWidget(
      _app(
        HistoryDayLine(
          day: DateTime(2026, 10, 12),
          doses: [_dose('a', 8 * 60)],
          pull: pull,
          onOpen: (_) {},
        ),
      ),
    );
    expect(_painter(tester).pull, same(pull));
    pull.value = .8;
    // The painter listens to the pull itself: no rebuild, one repaint.
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the hand-off finds the line on the glass and can veil it', (
    tester,
  ) async {
    final locator = HandOffLineLocator();
    addTearDown(locator.dispose);
    await tester.pumpWidget(
      _app(
        HistoryDayLine(
          day: DateTime(2026, 10, 12),
          doses: [_dose('a', 8 * 60)],
          locator: locator,
          onOpen: (_) {},
        ),
      ),
    );
    final line = locator.line()!;
    final paint = find.byKey(const ValueKey('history-day-line'));
    final left = tester.getTopLeft(paint);
    final width = tester.getSize(paint).width;
    // 06:00 to 22:00 for this day; earlier minutes hold to the line's end.
    expect(
      line.at(6 * 60),
      left + const Offset(DayLineFrame.pad, HistoryDayLine.lineY),
    );
    expect(line.at(0), left + const Offset(0, HistoryDayLine.lineY));
    expect(line.at(1440), left + Offset(width, HistoryDayLine.lineY));
    expect(line.now, isNull);
    double shown() => tester
        .widget<Opacity>(
          find.ancestor(of: paint, matching: find.byType(Opacity)).first,
        )
        .opacity;
    expect(shown(), 1);
    locator.veil.value = 1;
    await tester.pump();
    expect(shown(), 0);
    await tester.pumpWidget(_app(const SizedBox()));
    expect(locator.line(), isNull);
  });

  testWidgets('today carries the now pin at the clock\'s minute', (
    tester,
  ) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sceneClockProvider.overrideWithValue(
            () => DateTime(now.year, now.month, now.day, 15, 30),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: HistoryDayLine(
              day: DateUtils.dateOnly(now),
              doses: [_dose('a', 8 * 60)],
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(_painter(tester).now, 15 * 60 + 30);
  });

  testWidgets('the docked line lights the dot of the record at the top', (
    tester,
  ) async {
    final lit = ValueNotifier<String?>(null);
    addTearDown(lit.dispose);
    await tester.pumpWidget(
      _app(
        HistoryDockedLine(
          day: DateTime(2026, 10, 12),
          doses: [_dose('a', 8 * 60), _dose('b', 18 * 60)],
          highlight: lit,
          summary: 'Monday, 1 of 2 planned doses taken',
        ),
      ),
    );
    DayLinePainter docked() =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(HistoryDockedLine),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as DayLinePainter;
    expect(docked().compact, isTrue);
    expect(docked().selected, isNull);
    lit.value = 'b';
    await tester.pump();
    expect(docked().selected, 'b');
    expect(
      find.bySemanticsLabel('Monday, 1 of 2 planned doses taken'),
      findsOneWidget,
    );
  });
}
