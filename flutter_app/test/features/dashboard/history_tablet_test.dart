import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/calendar_month_view.dart';
import 'package:simpastil/features/analytics/stats_section.dart';
import 'package:simpastil/features/analytics/stock_changes.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/analytics/trends_view.dart';
import 'package:simpastil/features/dashboard/history_provider.dart';
import 'package:simpastil/features/dashboard/history_screen.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/review_rendering.dart';
import '../../helpers/held_provider_read.dart';

const _landscape = Size(1205, 753);
const _portrait = Size(753, 1205);
const _phone = Size(412, 915);
const _smallPhone = Size(360, 800);

final _today = DateUtils.dateOnly(DateTime.now());
final _yesterday = DateTime(_today.year, _today.month, _today.day - 1);

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

HistoryEntry _entry(
  String personId,
  String name,
  DateTime day,
  int hour,
  String state, {
  bool prn = false,
}) {
  final at = DateTime(day.year, day.month, day.day, hour);
  return HistoryEntry(
    doseLogId: '$name-${_date(day)}',
    pillName: name,
    scheduledAt: at,
    takenAt: state == 'taken' ? at : null,
    plannedLocalDate: _date(day),
    plannedLocalTime: '${hour.toString().padLeft(2, '0')}:00:00',
    recordedAt: state == 'pending' ? null : at.add(const Duration(minutes: 5)),
    status: state,
    occurrenceState: state,
    profileName: 'Fictional Alex',
    personId: personId,
    scheduleId: 'schedule-$name',
    source: prn ? 'prn' : 'scheduled',
  );
}

/// Today (two taken, one outstanding, one as-needed dose) and yesterday (one
/// taken, one skipped).
List<HistoryEntry> _records(String person) => [
  _entry(person, 'Fictional morning pill', _today, 0, 'taken'),
  _entry(person, 'Fictional second pill', _today, 0, 'taken'),
  _entry(person, 'Fictional evening pill', _today, 23, 'pending'),
  _entry(person, 'Fictional headache pill', _today, 1, 'taken', prn: true),
  _entry(person, 'Fictional morning pill', _yesterday, 8, 'taken'),
  _entry(person, 'Fictional second pill', _yesterday, 9, 'skipped'),
];

Map<DateTime, DayAdherence> _month() => {
  for (var d = 1; d <= _today.day; d++)
    DateTime(_today.year, _today.month, d): (
      taken: d.isEven ? 2 : 1,
      skipped: 0,
      missed: 0,
      expected: 2,
    ),
};

AdherenceStats _stats() => (
  last7Days: 6 / 7,
  last30Days: 0.82,
  prnTaken: 4,
  weeklyTrend: [
    for (var i = 0; i < 12; i++)
      (
        weekStart: DateTime(
          _today.year,
          _today.month,
          _today.day - 7 * (11 - i),
        ),
        taken: 8 + i % 5,
        skipped: i % 3,
        missed: 0,
        expected: 14,
      ),
  ],
  perPill: <PillAdherence>[
    (
      pillId: 'p1',
      pillName: 'Fictional evening pill',
      color: '#C0392B',
      taken: 20,
      skipped: 1,
      missed: 0,
      expected: 30,
    ),
    (
      pillId: 'p2',
      pillName: 'Fictional morning pill',
      color: '#2E86C1',
      taken: 29,
      skipped: 0,
      missed: 0,
      expected: 30,
    ),
  ],
);

TrendStats _trend() => (
  streak: (current: 5, best: 12),
  hasScheduledDoses: true,
  hourlyTaken: [
    for (var h = 0; h < 24; h++)
      h == 8 ? 28 : (h == 21 ? 19 : (h == 13 ? 4 : 0)),
  ],
  prn7Days: 2,
  prn30Days: 6,
  prnByPill: <PrnPillCount>[
    (pillId: 'p3', pillName: 'Fictional headache pill', count: 4),
    (pillId: 'p4', pillName: 'Fictional cough syrup', count: 2),
  ],
);

List<StockChange> _stock() => [
  StockChange(
    eventId: 'e2',
    pillId: 'p1',
    pillName: 'Fictional evening pill',
    pillColor: '#C0392B',
    profileId: 'a',
    kind: 'refill',
    before: 6,
    after: 36,
    at: DateTime(_today.year, _today.month, _today.day, 9, 15),
  ),
  StockChange(
    eventId: 'e1',
    pillId: 'p2',
    pillName: 'Fictional morning pill',
    pillColor: '#2E86C1',
    profileId: 'a',
    kind: 'dose',
    before: 47,
    after: 46,
    at: DateTime(_today.year, _today.month, _today.day, 8, 5),
  ),
];

/// The History tab inside the real shell, with fictional data in the
/// providers that read the occurrence and inventory ledgers.
Future<GoRouter> _mount(
  WidgetTester tester,
  Size size, {
  bool dark = false,
  double textScale = 1,
  Locale locale = const Locale('en'),
  List<HistoryEntry> Function(String person)? records,
  bool withStock = true,
  bool withTrend = true,
  bool trendFailsFirst = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = await CareRecordingFixture.create();
  final draft = (await fixture.db.select(fixture.db.setupDrafts).get()).single;
  final setup = SetupRepository(
    database: fixture.db,
    access: fixture.workspace.access,
    context: fixture.workspace.context,
  );
  final ready = await setup.advanceOrSkip(
    draft.id,
    draft.revision,
    SetupStep.ready,
  );
  await setup.advanceOrSkip(ready.id, ready.revision, SetupStep.complete);
  var trendReads = 0;
  final container = await fixture.workspace.createContainer(
    extraOverrides: [
      historyLogsProvider.overrideWith(
        (ref) => Stream.value((records ?? _records)(fixture.person.id)),
      ),
      monthAdherenceProvider.overrideWith(
        (ref, month) => Stream.value(
          month.year == _today.year && month.month == _today.month
              ? _month()
              : const <DateTime, DayAdherence>{},
        ),
      ),
      monthPrnCountsProvider.overrideWith(
        (ref, month) => Stream.value(
          month.year == _today.year && month.month == _today.month
              ? {_today: 1}
              : const <DateTime, int>{},
        ),
      ),
      adherenceStatsProvider.overrideWith((ref) => Stream.value(_stats())),
      trendStatsProvider.overrideWith((ref) {
        if (trendFailsFirst && trendReads++ == 0) {
          return Stream.error(StateError('the trend read failed'));
        }
        return withTrend ? Stream.value(_trend()) : const Stream.empty();
      }),
      pillColorsProvider.overrideWith(
        (ref) => const {
          'p1': '#C0392B',
          'p2': '#2E86C1',
          'p3': '#8E44AD',
          'p4': '#16A085',
        },
      ),
      dayStockChangesProvider.overrideWith(
        (ref, key) => Stream.value(
          withStock && key == _date(_today) ? _stock() : const <StockChange>[],
        ),
      ),
    ],
  );
  await container.readHeld(profileListProvider);
  await container.readHeld(selectedProfileIdProvider);
  await container.readHeld(unfinishedSetupDraftProvider);
  final router = container.read(routerProvider)..go(AppPaths.logs);
  addTearDown(() async {
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  final theme = dark ? AppTheme.dark() : AppTheme.light();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: _withReviewFont(
          theme.copyWith(platform: TargetPlatform.android),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(textScale),
          ),
          child: RepaintBoundary(key: reviewCaptureKey, child: child!),
        ),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// The review typeface for the rail's own label styles (which the shared
/// helper leaves alone), so screenshots show real text.
ThemeData _withReviewFont(ThemeData theme) {
  final themed = reviewRenderingTheme(theme);
  if (identical(themed, theme)) return theme;
  final rail = theme.navigationRailTheme;
  return themed.copyWith(
    navigationRailTheme: rail.copyWith(
      selectedLabelTextStyle: rail.selectedLabelTextStyle?.copyWith(
        fontFamily: 'Roboto',
      ),
      unselectedLabelTextStyle: rail.unselectedLabelTextStyle?.copyWith(
        fontFamily: 'Roboto',
      ),
    ),
  );
}

Finder _cell(DateTime day) =>
    find.byKey(ValueKey('day-cell-${day.year}-${day.month}-${day.day}'));

String _name(Size size) => '${size.width.toInt()}x${size.height.toInt()}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  group('expanded window (1205x753)', () {
    testWidgets('puts the month beside the selected day', (tester) async {
      await _mount(tester, _landscape);
      await captureReview(tester, 'history-calendar-${_name(_landscape)}');
      expect(find.byType(HistoryScreen), findsOneWidget);

      // The title bar: the view toggle and the search field.
      expect(find.byKey(const ValueKey('history-view-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-search')), findsOneWidget);

      // Left: the month with its legend and totals.
      expect(find.byType(CalendarMonthView), findsOneWidget);
      expect(find.textContaining('so far'), findsOneWidget);
      // Right: the day, its figures, its records and its stock changes.
      expect(find.text('Planned doses recorded'), findsOneWidget);
      expect(find.text('1 of 2'), findsNothing);
      expect(find.text('Fictional morning pill'), findsOneWidget);
      expect(find.text('Fictional headache pill'), findsOneWidget);
      expect(find.text('Stock changes'), findsOneWidget);
      expect(
        find.text('Fictional morning pill, 47 to 46'),
        findsOneWidget,
        reason: 'the stock change row',
      );
      // The two panes sit side by side.
      final calendar = tester.getRect(find.byType(CalendarMonthView));
      final stock = tester.getRect(find.text('Stock changes'));
      expect(calendar.right, lessThan(stock.left));
      expect(tester.takeException(), isNull);
      await captureReview(tester, 'history-calendar-${_name(_landscape)}');
    });

    testWidgets('tapping a day in the calendar selects it in the day pane', (
      tester,
    ) async {
      await _mount(tester, _landscape);
      expect(find.text('Fictional evening pill'), findsOneWidget);
      if (_yesterday.month != _today.month) {
        await tester.tap(find.byIcon(Icons.chevron_left));
        await tester.pumpAndSettle();
      }
      await tester.tap(_cell(_yesterday));
      await tester.pumpAndSettle();

      // Yesterday's two records; today's evening pill is gone from the pane.
      expect(find.text('Fictional evening pill'), findsNothing);
      expect(find.text('Fictional second pill'), findsOneWidget);
      expect(find.text('Fictional morning pill'), findsOneWidget);
      // A day without stock changes shows no section.
      expect(find.text('Stock changes'), findsNothing);
      // The calendar stays put, with the chosen day marked.
      expect(find.byType(CalendarMonthView), findsOneWidget);
      final semantics = tester.ensureSemantics();
      await tester.pump();
      expect(
        tester.getSemantics(_cell(_yesterday)).flagsCollection.isSelected.name,
        'isTrue',
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the toggle moves between the calendar and the trends', (
      tester,
    ) async {
      await _mount(tester, _landscape);
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();

      expect(find.byType(TrendsView), findsOneWidget);
      expect(find.byType(CalendarMonthView), findsNothing);
      // The weekly chart takes the height its card is given, level with the
      // per-medication card beside it, instead of a fixed strip over blank.
      final trendCard = find
          .ancestor(of: find.text('Weekly trend'), matching: find.byType(Card))
          .first;
      final bars = tester.getRect(find.byKey(const ValueKey('trend-bar-11')));
      expect(
        tester.getRect(trendCard).bottom - bars.bottom,
        lessThan(40),
        reason: 'the bars reach the foot of the card, labels under them',
      );
      for (final text in [
        'Last 7 days',
        'Day streak',
        'As-needed doses',
        'Weekly trend',
        'By medication',
        'As needed by medication',
        'Time of day',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      // Once as a figure's label and once as the as-needed figure's note.
      expect(find.text('Last 30 days'), findsNWidgets(2));
      expect(find.text('5'), findsOneWidget, reason: 'the current streak');
      expect(find.text('Best in 12 weeks: 12'), findsOneWidget);
      expect(find.text('86%'), findsOneWidget);
      expect(find.text('82%'), findsOneWidget);
      for (var i = 0; i < 12; i++) {
        expect(find.byKey(ValueKey('trend-bar-$i')), findsOneWidget);
      }
      for (var h = 0; h < 24; h++) {
        expect(find.byKey(ValueKey('time-of-day-$h')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('as-needed-p3')), findsOneWidget);
      expect(find.text('Fictional headache pill'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureReview(tester, 'history-trends-${_name(_landscape)}');

      await tester.tap(find.text('Calendar').first);
      await tester.pumpAndSettle();
      expect(find.byType(TrendsView), findsNothing);
      expect(find.byType(CalendarMonthView), findsOneWidget);
    });

    testWidgets('the header search looks through the loaded days, and typing '
        'in Trends goes back to the records', (tester) async {
      await _mount(tester, _landscape);
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('history-search')),
        'second',
      );
      await tester.pumpAndSettle();

      expect(find.byType(TrendsView), findsNothing);
      // Both days' second pill records, none of the other medications.
      expect(find.text('Fictional second pill'), findsNWidgets(2));
      expect(find.text('Fictional morning pill'), findsNothing);

      // Choosing a day ends the search.
      await tester.tap(_cell(_today));
      await tester.pumpAndSettle();
      expect(find.text('Fictional morning pill'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('history-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Romanian renders the new strings', (tester) async {
      await _mount(tester, _landscape, locale: const Locale('ro'));
      expect(find.byKey(const ValueKey('history-view-toggle')), findsOneWidget);
      expect(find.text('Calendar'), findsWidgets);
      expect(find.text('Tendințe'), findsOneWidget);
      expect(find.text('Modificări de stoc'), findsOneWidget);
      await tester.tap(find.text('Tendințe'));
      await tester.pumpAndSettle();
      expect(find.text('Zile la rând'), findsOneWidget);
      expect(find.text('Ora din zi'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a month with nothing recorded and no trends still renders', (
      tester,
    ) async {
      await _mount(
        tester,
        _landscape,
        records: (_) => const [],
        withStock: false,
        withTrend: false,
      );
      expect(find.byType(CalendarMonthView), findsOneWidget);
      expect(find.text('Stock changes'), findsNothing);
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
      expect(find.byType(TrendsView), findsOneWidget);
      expect(find.text('Time of day'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the bar and the page share their edges', () {
    // The title and the share button sit on the left and right edges of the
    // page's column, the same edges as the cards below the bar.
    for (final size in [_landscape, _portrait]) {
      testWidgets('title and share button line up with the cards at '
          '${_name(size)}', (tester) async {
        await _mount(tester, size);
        final card = tester.getRect(
          find
              .ancestor(
                of: find.byType(CalendarMonthView),
                matching: find.byType(Card),
              )
              .first,
        );
        expect(
          tester
              .getRect(
                find.descendant(
                  of: find.byType(AppBar),
                  matching: find.text('History'),
                ),
              )
              .left,
          closeTo(card.left, 1),
          reason: 'the title starts where the cards do',
        );
        final share = tester.getRect(find.byIcon(Icons.ios_share));
        final rightmost = size == _landscape
            ? tester.getRect(
                find
                    .ancestor(
                      of: find.text('Planned doses recorded'),
                      matching: find.byType(Card),
                    )
                    .last,
              )
            : card;
        expect(
          share.right,
          closeTo(rightmost.right, 1),
          reason: 'the share button ends where the cards do',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the calendar takes the rows its month needs', () {
    for (final size in [_landscape, _portrait, _phone]) {
      testWidgets('at ${_name(size)} it is no taller than those rows', (
        tester,
      ) async {
        await _mount(tester, size);
        if (size == _phone) {
          await tester.tap(find.byTooltip('Calendar'));
          await tester.pumpAndSettle();
        }
        final now = DateTime.now();
        final rows = monthRows(DateTime(now.year, now.month));
        final box = tester.getSize(
          find.descendant(
            of: find.byType(CalendarMonthView),
            matching: find.byType(PageView),
          ),
        );
        // Square cells, but never taller than 64 dp.
        final row = (box.width / 7).clamp(0.0, 64.0);
        expect(box.height, closeTo(rows * row, 0.5));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('medium window (753x1205)', () {
    testWidgets('stacks the month, three figures and the day', (tester) async {
      await _mount(tester, _portrait);
      expect(find.byKey(const ValueKey('history-view-toggle')), findsOneWidget);
      // No wide search field; a search button opens the pinned one.
      expect(find.byKey(const ValueKey('history-search')), findsNothing);
      expect(find.byType(CalendarMonthView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('history-week-figures')),
        findsOneWidget,
      );
      expect(find.text('Planned doses recorded'), findsOneWidget);
      expect(find.text('Stock changes'), findsOneWidget);
      // The month sits above the day.
      expect(
        tester.getRect(find.byType(CalendarMonthView)).bottom,
        lessThan(tester.getRect(find.text('Planned doses recorded')).top),
      );
      expect(tester.takeException(), isNull);
      await captureReview(tester, 'history-calendar-${_name(_portrait)}');

      await tester.tap(find.byTooltip('Search history'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history-search')), findsOneWidget);
    });

    testWidgets('says so when the streak and charts cannot be read', (
      tester,
    ) async {
      await _mount(tester, _portrait, trendFailsFirst: true);
      expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
      expect(find.text('Could not load the streak and charts'), findsOneWidget);
      // The figures that did load are still there.
      expect(
        find.byKey(const ValueKey('history-week-figures')),
        findsOneWidget,
      );
      expect(find.text('As-needed doses'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('trends-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-error')), findsNothing);
      expect(find.text('As-needed doses'), findsOneWidget);
    });

    testWidgets('the Trends view is the statistics column', (tester) async {
      await _mount(tester, _portrait);
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
      expect(find.byType(StatsSection), findsOneWidget);
      expect(find.byType(CalendarMonthView), findsNothing);
      expect(find.text('Day streak'), findsOneWidget);
      expect(find.text('Time of day'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureReview(tester, 'history-trends-${_name(_portrait)}');
    });
  });

  group('phone (412x915)', () {
    testWidgets('keeps the list and calendar toggle, and shows the day\'s '
        'stock changes under the records', (tester) async {
      await _mount(tester, _phone);
      expect(find.byKey(const ValueKey('history-view-toggle')), findsNothing);
      expect(find.byType(StatsSection), findsNothing);
      expect(find.byTooltip('Calendar'), findsOneWidget);
      expect(find.text('Fictional morning pill'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Stock changes'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Stock changes'), findsOneWidget);
      expect(find.text('Fictional morning pill, 47 to 46'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the calendar view ends with the statistics, with the '
        'streak and the charts', (tester) async {
      await _mount(tester, _phone);
      await tester.tap(find.byTooltip('Calendar'));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarMonthView), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Time of day'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      for (final text in [
        'Day streak',
        'As-needed doses',
        'Time of day',
        'As needed by medication',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      // The charts come above the weekly trend and the per-medication rows.
      expect(
        tester.getTopLeft(find.text('Time of day')).dy,
        lessThan(tester.getTopLeft(find.text('Weekly trend')).dy),
      );
      expect(
        tester.getTopLeft(find.text('As needed by medication')).dy,
        lessThan(tester.getTopLeft(find.text('Weekly trend')).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a day with no stock changes shows no section', (tester) async {
      await _mount(tester, _phone, withStock: false);
      await tester.scrollUntilVisible(
        find.text('Fictional headache pill'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Stock changes'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('every size, text scale and theme renders without overflow', () {
    for (final size in [_landscape, _portrait, _phone, _smallPhone]) {
      for (final scale in [1.0, 1.3]) {
        for (final dark in [false, true]) {
          final label = '${_name(size)} x$scale ${dark ? 'dark' : 'light'}';
          testWidgets(label, (tester) async {
            await _mount(tester, size, dark: dark, textScale: scale);
            final tag =
                '${_name(size)}-${scale == 1 ? '1' : '13'}-'
                '${dark ? 'dark' : 'light'}';
            expect(tester.takeException(), isNull, reason: 'list/calendar');
            if (size.width >= 600) {
              await captureReview(tester, 'matrix-calendar-$tag');
              await tester.tap(find.text('Trends'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: 'trends');
              await captureReview(tester, 'matrix-trends-$tag');
              return;
            }
            await captureReview(tester, 'matrix-list-$tag');
            await tester.scrollUntilVisible(
              find.text('Stock changes'),
              300,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.ensureVisible(find.text('Stock changes').first);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'list');
            await captureReview(tester, 'matrix-stock-$tag');
            await tester.tap(find.byTooltip('Calendar'));
            await tester.pumpAndSettle();
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .jumpTo(0);
            await tester.pumpAndSettle();
            await captureReview(tester, 'matrix-calendar-$tag');
            await tester.scrollUntilVisible(
              find.text('By medication (30 days)'),
              400,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'stats');
            await captureReview(tester, 'matrix-stats-$tag');
          });
        }
      }
    }
  });
}
