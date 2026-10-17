import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/calendar_month_view.dart';
import 'package:simpastil/shared/scene/dose_bead.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

class _FixedMonthNotifier extends CalendarMonthNotifier {
  _FixedMonthNotifier(this._month);
  final DateTime _month;
  @override
  DateTime build() => _month;
}

class _SpySelectedDate extends SelectedDateNotifier {
  DateTime? lastSelected;
  @override
  void select(DateTime d) {
    lastSelected = dateOnly(d);
    super.select(d);
  }
}

Widget _wrap({
  Map<DateTime, DayAdherence> adherence = const {},
  List<Override> extraOverrides = const [],
  Locale locale = const Locale('en'),
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    monthAdherenceProvider.overrideWith(
      (ref, month) => Stream.value(adherence),
    ),
    ...extraOverrides,
  ],
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: const Scaffold(
      body: SingleChildScrollView(child: CalendarMonthView()),
    ),
  ),
);

Widget _routerApp({
  Map<DateTime, DayAdherence> adherence = const {},
  List<Override> extraOverrides = const [],
}) => ProviderScope(
  overrides: [
    monthAdherenceProvider.overrideWith(
      (ref, month) => Stream.value(adherence),
    ),
    ...extraOverrides,
  ],
  child: MaterialApp.router(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(useMaterial3: true),
    routerConfig: GoRouter(
      initialLocation: '/logs',
      routes: [
        GoRoute(
          path: '/logs',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: CalendarMonthView()),
          ),
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) => const Scaffold(body: Text('HOME')),
        ),
      ],
    ),
  ),
);

Key _cellKey(DateTime day) =>
    ValueKey('day-cell-${day.year}-${day.month}-${day.day}');
Key _dotKey(DateTime day) =>
    ValueKey('day-dot-${day.year}-${day.month}-${day.day}');

List<DoseBead>? _beads(WidgetTester tester, DateTime day) {
  final finder = find.byKey(_dotKey(day));
  if (finder.evaluate().isEmpty) return null;
  final painter =
      tester.widget<CustomPaint>(finder).painter! as MonthDayPainter;
  return [for (final b in painter.beads) b.bead];
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('monthRows', () {
    test('counts the Monday-first weeks a month touches', () {
      // February 2027 starts on a Monday and has 28 days.
      expect(monthRows(DateTime(2027, 2)), 4);
      // October 2026 starts on a Thursday.
      expect(monthRows(DateTime(2026, 10)), 5);
      // August 2026 starts on a Saturday, so it spills into a sixth week.
      expect(monthRows(DateTime(2026, 8)), 6);
    });
  });

  group('CalendarMonthView', () {
    testWidgets('Romanian weekday labels stay in Monday-first grid order', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(locale: const Locale('ro')));
      await tester.pumpAndSettle();

      const labels = ['lun.', 'mar.', 'mie.', 'joi', 'vin.', 'sâm.', 'dum.'];
      var previousX = double.negativeInfinity;
      for (final label in labels) {
        final weekday = find.text(label);
        expect(weekday, findsOneWidget);
        final x = tester.getCenter(weekday).dx;
        expect(x, greaterThan(previousX));
        previousX = x;
      }
      expect(find.text('Mon'), findsNothing);
      expect(find.text('Sun'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('200% Romanian headers keep punctuation on the weekday line', (
      tester,
    ) async {
      // The test font has square numerals; leave grid dates enough width while
      // still reproducing the four-character header wrap at 200%.
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(locale: const Locale('ro'), textScale: 2));
      await tester.pumpAndSettle();

      for (final label in [
        'lun.',
        'mar.',
        'mie.',
        'joi',
        'vin.',
        'sâm.',
        'dum.',
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        final lineTops = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            )
            .map((box) => box.top)
            .toSet();
        expect(lineTops, hasLength(1), reason: '$label must stay intact');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the current month with the right chevron disabled', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      final now = DateTime.now();
      expect(
        find.text(
          DateFormat('MMMM yyyy').format(DateTime(now.year, now.month)),
        ),
        findsOneWidget,
      );
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('left chevron pages back and right chevron returns', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final previousMonth = DateTime(now.year, now.month - 1);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(
        find.text(DateFormat('MMMM yyyy').format(previousMonth)),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(
        find.text(
          DateFormat('MMMM yyyy').format(DateTime(now.year, now.month)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders each finished day as its dose beads, never missed', (
      tester,
    ) async {
      final adherence = {
        DateTime(2026, 3, 2): (
          taken: 2,
          skipped: 0,
          missed: 0,
          expected: 2,
        ), // full
        DateTime(2026, 3, 3): (
          taken: 1,
          skipped: 0,
          missed: 0,
          expected: 2,
        ), // partial
        DateTime(2026, 3, 4): (
          taken: 0,
          skipped: 0,
          missed: 0,
          expected: 2,
        ), // zero
        DateTime(2026, 3, 5): (
          taken: 0,
          skipped: 1,
          missed: 0,
          expected: 1,
        ), // 0%
      };
      await tester.pumpWidget(
        _wrap(
          adherence: adherence,
          extraOverrides: [
            calendarMonthProvider.overrideWith(
              () => _FixedMonthNotifier(DateTime(2026, 3)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(_beads(tester, DateTime(2026, 3, 2)), [
        DoseBead.taken,
        DoseBead.taken,
      ]);
      expect(_beads(tester, DateTime(2026, 3, 3)), [
        DoseBead.taken,
        DoseBead.unrecorded,
      ]);
      expect(_beads(tester, DateTime(2026, 3, 4)), [
        DoseBead.unrecorded,
        DoseBead.unrecorded,
      ]);
      expect(_beads(tester, DateTime(2026, 3, 5)), [DoseBead.skipped]);
      expect(_beads(tester, DateTime(2026, 3, 6)), isNull); // no data
    });

    testWidgets('day beads fit the cell at 200% text on a narrow phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _wrap(
          textScale: 2,
          adherence: {
            DateTime(2026, 3, 2): (
              taken: 2,
              skipped: 0,
              missed: 0,
              expected: 2,
            ),
            DateTime(2026, 3, 3): (
              taken: 1,
              skipped: 0,
              missed: 0,
              expected: 2,
            ),
          },
          extraOverrides: [
            calendarMonthProvider.overrideWith(
              () => _FixedMonthNotifier(DateTime(2026, 3)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(_beads(tester, DateTime(2026, 3, 3)), [
        DoseBead.taken,
        DoseBead.unrecorded,
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('March 2026 renders 31 day cells after 6 leading blanks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          extraOverrides: [
            calendarMonthProvider.overrideWith(
              () => _FixedMonthNotifier(DateTime(2026, 3)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(_cellKey(DateTime(2026, 3, 1))), findsOneWidget);
      expect(find.byKey(_cellKey(DateTime(2026, 3, 31))), findsOneWidget);
      expect(find.text('Mon'), findsOneWidget);
      expect(find.text('Sun'), findsOneWidget);
      // The 1st falls on a Sunday → it sits in the 7th column. Its left edge
      // must be right of the 6 blank columns (> 6/7 of the grid width).
      final gridLeft = tester.getTopLeft(find.byType(GridView)).dx;
      final gridRight = tester.getTopRight(find.byType(GridView)).dx;
      final firstLeft = tester
          .getTopLeft(find.byKey(_cellKey(DateTime(2026, 3, 1))))
          .dx;
      expect(
        firstLeft - gridLeft,
        greaterThan((gridRight - gridLeft) * 6 / 7 - 1),
      );
    });

    testWidgets('today gets an outline ring', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('day-today-ring')), findsOneWidget);
    });

    testWidgets('tapping a past day selects it and navigates home', (
      tester,
    ) async {
      final spy = _SpySelectedDate();
      await tester.pumpWidget(
        _routerApp(
          extraOverrides: [
            calendarMonthProvider.overrideWith(
              () => _FixedMonthNotifier(DateTime(2026, 3)),
            ),
            selectedDateProvider.overrideWith(() => spy),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_cellKey(DateTime(2026, 3, 10))));
      await tester.pumpAndSettle();

      expect(find.text('HOME'), findsOneWidget);
      expect(spy.lastSelected, DateTime(2026, 3, 10));
    });

    testWidgets('swiping right pages back into the past', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final previousMonth = DateTime(now.year, now.month - 1);

      // Reverse PageView: a rightward fling moves to higher indices (the past).
      // fling, not drag: a zero-velocity 400px release snaps back under
      // PageScrollPhysics; a fling's ballistic settle reliably turns the page.
      await tester.fling(find.byType(PageView), const Offset(400, 0), 800);
      await tester.pumpAndSettle();

      expect(
        find.text(DateFormat('MMMM yyyy').format(previousMonth)),
        findsOneWidget,
      );
    });

    testWidgets('rapid double chevron tap moves two months back', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final twoBack = DateTime(now.year, now.month - 2);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump(const Duration(milliseconds: 50)); // mid-animation
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();

      expect(
        find.text(DateFormat('MMMM yyyy').format(twoBack)),
        findsOneWidget,
      );
    });

    testWidgets('three rapid chevron taps move three months back', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final threeBack = DateTime(now.year, now.month - 3);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();

      expect(
        find.text(DateFormat('MMMM yyyy').format(threeBack)),
        findsOneWidget,
      );
    });

    testWidgets('future days do not respond to taps', (tester) async {
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      if (tomorrow.month != now.month) {
        markTestSkipped('last day of the month — no future cell to verify');
        return;
      }
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      final cell = tester.widget<InkWell>(find.byKey(_cellKey(tomorrow)));
      expect(cell.onTap, isNull);
    });
  });

  group('monthDayBeads', () {
    test('today keeps the doses still to come as planned rings', () {
      expect(
        monthDayBeads((
          taken: 1,
          skipped: 1,
          missed: 0,
          expected: 3,
        ), today: true),
        [DoseBead.taken, DoseBead.skipped, DoseBead.planned],
      );
    });

    test('a recorded miss is a missed bead, today included', () {
      const day = (taken: 1, skipped: 1, missed: 1, expected: 4);
      expect(monthDayBeads(day, today: true), [
        DoseBead.taken,
        DoseBead.skipped,
        DoseBead.missed,
        DoseBead.planned,
      ]);
      expect(monthDayBeads(day, today: false), [
        DoseBead.taken,
        DoseBead.skipped,
        DoseBead.missed,
        DoseBead.unrecorded,
      ]);
    });

    test('a busy day keeps its proportions in eight beads', () {
      final beads = monthDayBeads((
        taken: 12,
        skipped: 0,
        missed: 0,
        expected: 16,
      ), today: false);
      expect(beads, hasLength(8));
      expect(beads.where((b) => b == DoseBead.taken), hasLength(6));
      expect(beads.where((b) => b == DoseBead.unrecorded), hasLength(2));
    });

    test('a day with nothing due has no beads', () {
      expect(
        monthDayBeads((
          taken: 0,
          skipped: 0,
          missed: 0,
          expected: 0,
        ), today: false),
        isEmpty,
      );
    });
  });
}
