import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/calendar_month_view.dart';
import 'package:simpastil/features/analytics/stats_section.dart';
import 'package:simpastil/features/analytics/stock_changes.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/dashboard/history_day_line.dart';
import 'package:simpastil/features/dashboard/history_day_ribbon.dart';
import 'package:simpastil/features/dashboard/history_provider.dart';
import 'package:simpastil/features/dashboard/history_quiet_day.dart';
import 'package:simpastil/features/dashboard/history_screen.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import '../../helpers/protected_workspace_fixture.dart';

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Stream<List<HistoryEntry>> stream, {
  Locale locale = const Locale('en'),
  bool twentyFourHour = false,
  Size size = const Size(412, 915),
  Future<void> Function(ProtectedWorkspaceFixture fixture)? seed,
}) async {
  // These tests read the phone's day view. The default test window is 800
  // wide, which the tablet layouts treat as a medium window with its own
  // arrangement (see history_tablet_test.dart).
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  final fixture = await ProtectedWorkspaceFixture.create();
  await seed?.call(fixture);
  final container = await fixture.createContainer(
    extraOverrides: [
      historyLogsProvider.overrideWith((ref) => stream),
      monthAdherenceProvider.overrideWith(
        (ref, month) => Stream.value(const <DateTime, DayAdherence>{}),
      ),
      // The wider layouts read these too; like the two above, each would
      // otherwise start a midnight timer on the real database.
      monthPrnCountsProvider.overrideWith(
        (ref, month) => Stream.value(const <DateTime, int>{}),
      ),
      trendStatsProvider.overrideWith(
        (ref) => Stream.value((
          streak: (current: 0, best: 0),
          hasScheduledDoses: false,
          hourlyTaken: List<int>.filled(24, 0),
          prn7Days: 0,
          prn30Days: 0,
          prnByPill: <PrnPillCount>[],
        )),
      ),
      dayStockChangesProvider.overrideWith(
        (ref, day) => Stream.value(const <StockChange>[]),
      ),
      adherenceStatsProvider.overrideWith(
        (ref) => Stream.value((
          last7Days: null,
          last30Days: null,
          prnTaken: 0,
          weeklyTrend: <WeekAdherence>[],
          perPill: <PillAdherence>[],
        )),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        builder: (context, page) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(alwaysUse24HourFormat: twentyFourHour),
          child: page!,
        ),
        home: const HistoryScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

void main() {
  testWidgets(
    'History day and outcome filters keep exact facts and widen reads for older days',
    (tester) async {
      final today = DateUtils.dateOnly(DateTime.now());
      String date(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      HistoryEntry entry(String id, String state, DateTime day) => HistoryEntry(
        doseLogId: id,
        pillName: 'Fictional $id',
        scheduledAt: day,
        plannedLocalDate: date(day),
        plannedLocalTime: '08:00:00',
        recordedAt: day.add(const Duration(hours: 9)),
        status: state,
        occurrenceState: state,
        profileName: 'Fictional person',
        scheduleId: id,
      );
      final container = await _mount(
        tester,
        Stream.value([
          entry('taken', 'taken', today),
          entry('undo', 'pending', today),
          entry('earlier', 'skipped', today.subtract(const Duration(days: 1))),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fictional taken'), findsOneWidget);
      expect(find.text('Fictional earlier'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('history-outcome-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not recorded').last);
      await tester.pumpAndSettle();
      expect(find.text('Fictional undo'), findsOneWidget);
      expect(find.text('Fictional taken'), findsNothing);
      expect(find.text('Missed'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('history-outcome-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All records').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      expect(find.text('Fictional earlier'), findsOneWidget);
      expect(find.text('Fictional taken'), findsNothing);
      for (var i = 0; i < 30; i++) {
        await tester.tap(find.byTooltip('Previous day'));
        await tester.pumpAndSettle();
      }
      expect(
        container.read(historyWindowDaysProvider),
        greaterThanOrEqualTo(32),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final example in [
    (locale: 'en', name: null, label: 'Author name not recorded'),
    (locale: 'ro', name: null, label: 'Numele autorului nu este înregistrat'),
    (locale: 'en', name: 'Retained author', label: 'Retained author'),
  ]) {
    testWidgets('History preserves known attribution: ${example.label}', (
      tester,
    ) async {
      await _mount(
        tester,
        Stream.value([
          HistoryEntry(
            doseLogId: 'known-author',
            pillName: 'Fictional medication',
            scheduledAt: null,
            status: 'taken',
            profileName: 'Fictional person',
            scheduleId: '',
            source: 'prn',
            authorId: 'retained-author-id',
            authorName: example.name,
          ),
        ]),
        locale: Locale(example.locale),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(example.label),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(example.label), findsOneWidget);
      expect(find.text('Author unknown'), findsNothing);
      expect(find.text('Autor necunoscut'), findsNothing);
    });
  }
  testWidgets(
    'factual history is default and preserves calendar plus export entry',
    (tester) async {
      await _mount(tester, Stream.value([]));
      await tester.pumpAndSettle();
      expect(find.text('No records yet'), findsOneWidget);
      expect(find.byTooltip('Export dose history'), findsOneWidget);
      await tester.tap(find.byTooltip('Calendar'));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarMonthView), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(StatsSection),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(StatsSection), findsOneWidget);
      await tester.tap(find.byTooltip('List'));
      await tester.pumpAndSettle();
      expect(find.text('No records yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('a dose not recorded yet shows no actual, entry or author rows', (
    tester,
  ) async {
    await _mount(
      tester,
      Stream.value([
        HistoryEntry(
          doseLogId: 'due',
          pillName: 'Fictional evening medication',
          scheduledAt: DateTime(2026, 9, 30, 23),
          takenAt: null,
          actualTimeKnown: false,
          status: 'pending',
          occurrenceState: 'pending',
          plannedLocalTime: '23:00',
          profileName: 'Fictional person',
          scheduleId: 's',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fictional evening medication'), findsOneWidget);
    expect(find.text('Actual time unknown'), findsNothing);
    expect(find.text('Not specified'), findsNothing);
    expect(find.text('Author unknown'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('a recorded miss shows when the app entered it, never an actual '
      'time or author', (tester) async {
    await _mount(
      tester,
      Stream.value([
        HistoryEntry(
          doseLogId: 'missed',
          pillName: 'Fictional morning medication',
          scheduledAt: DateTime(2026, 9, 30, 8),
          takenAt: null,
          actualTimeKnown: false,
          status: 'missed',
          occurrenceState: 'missed',
          plannedLocalTime: '08:00',
          profileName: 'Fictional person',
          scheduleId: 's',
          recordedAt: DateTime(2026, 9, 30, 8, 20),
        ),
        HistoryEntry(
          doseLogId: 'late',
          pillName: 'Fictional late medication',
          scheduledAt: DateTime(2026, 9, 30, 9),
          takenAt: DateTime(2026, 9, 30, 11),
          status: 'taken',
          occurrenceState: 'taken',
          plannedLocalTime: '09:00',
          profileName: 'Fictional person',
          scheduleId: 's2',
          recordedAt: DateTime(2026, 9, 30, 11, 1),
          takenLate: true,
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fictional morning medication'), findsOneWidget);
    expect(find.text('Missed'), findsWidgets);
    expect(find.text('Taken (late)'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Author unknown'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    // Both rows say when the app entered them; only the late take has an
    // author, and a miss has no actual time to be unknown.
    expect(find.text('Recorded in Simpastil:'), findsNWidgets(2));
    expect(find.text('Author unknown'), findsOneWidget);
    expect(find.text('Actual time unknown'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'PRN unknown facts stay separate from recorded timestamp and author',
    (tester) async {
      await _mount(
        tester,
        Stream.value([
          HistoryEntry(
            doseLogId: 'unknown',
            pillName: 'Retained medication',
            scheduledAt: null,
            takenAt: null,
            actualTimeKnown: false,
            recordedAt: DateTime(2026, 9, 30, 12, 7),
            status: 'taken',
            profileName: 'Retained person',
            scheduleId: '',
            source: 'prn',
            provenance: 'legacy_estimated',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retained medication'), findsOneWidget);
      expect(find.text('Date unknown'), findsOneWidget);
      expect(find.text('As needed'), findsOneWidget);
      expect(find.text('Actual time unknown'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Author unknown'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('12:07'), findsOneWidget);
      expect(find.text('Author unknown'), findsOneWidget);
      expect(
        find.text('Older record · some details are unknown'),
        findsOneWidget,
      );
      expect(find.textContaining('%'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'past pending and Undo display Unrecorded, never inferred Missed',
    (tester) async {
      await _mount(
        tester,
        Stream.value([
          HistoryEntry(
            doseLogId: 'withdrawn',
            pillName: 'Exact medication',
            plannedLocalDate: '2026-09-30',
            plannedLocalTime: '08:00:00',
            scheduledAt: DateTime(2026, 9, 30, 8),
            status: 'missed',
            occurrenceState: 'pending',
            profileName: 'Alex',
            scheduleId: 'slot',
            source: 'scheduled',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Not recorded'), findsOneWidget);
      expect(find.text('Missed'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.text('8:00 AM'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('a 24-hour phone shows history times in 24 hours', (
    tester,
  ) async {
    await _mount(
      tester,
      Stream.value([
        HistoryEntry(
          doseLogId: 'morning',
          pillName: 'Exact medication',
          plannedLocalDate: '2026-09-30',
          plannedLocalTime: '08:00:00',
          scheduledAt: DateTime(2026, 9, 30, 8),
          status: 'missed',
          occurrenceState: 'pending',
          profileName: 'Alex',
          scheduleId: 'slot',
          source: 'scheduled',
        ),
      ]),
      twentyFourHour: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('8:00 AM'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('loading and failed history never become empty care', (
    tester,
  ) async {
    final stream = StreamController<List<HistoryEntry>>();
    await _mount(tester, stream.stream);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('No records yet'), findsNothing);
    stream.addError(StateError('fictional read failure'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load history'), findsOneWidget);
    expect(find.text('No records yet'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await stream.close();
  });
  test('earlier records still expand the existing protected window', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(historyWindowDaysProvider), 30);
    container.read(historyWindowDaysProvider.notifier).state += 30;
    expect(container.read(historyWindowDaysProvider), 60);
  });

  group('the day ribbon', () {
    final today = DateUtils.dateOnly(DateTime.now());
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    String date(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    HistoryEntry entry(String id, String state, DateTime day, String time) =>
        HistoryEntry(
          doseLogId: id,
          pillName: 'Fictional $id',
          scheduledAt: day,
          plannedLocalDate: date(day),
          plannedLocalTime: time,
          recordedAt: day.add(const Duration(hours: 9)),
          status: state,
          occurrenceState: state,
          profileName: 'Fictional person',
          scheduleId: id,
        );
    final records = [
      entry('today', 'taken', today, '08:00:00'),
      entry('morning', 'taken', yesterday, '08:00:00'),
      entry('evening', 'skipped', yesterday, '20:00:00'),
    ];

    double slideOf(WidgetTester tester, String text) => tester
        .widget<FractionalTranslation>(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byType(FractionalTranslation),
              )
              .first,
        )
        .translation
        .dx;

    testWidgets('shows each day with what was taken and picks a day', (
      tester,
    ) async {
      await _mount(tester, Stream.value(records));
      await tester.pumpAndSettle();
      expect(find.byType(HistoryDayRibbon), findsOneWidget);
      final handle = tester.ensureSemantics();
      final locale = DateFormat.MMMMEEEEd('en');
      expect(
        find.bySemanticsLabel(
          '${locale.format(yesterday)}, 1 of 2 planned doses taken',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          '${locale.format(today)}, 1 of 1 planned doses taken',
        ),
        findsOneWidget,
      );
      handle.dispose();

      await tester.tap(
        find.byKey(ValueKey('history-ribbon-${date(yesterday)}')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      // The past arrives from the left, today leaves to the right.
      expect(slideOf(tester, 'Fictional morning'), lessThan(0));
      expect(slideOf(tester, 'Fictional today'), greaterThan(0));
      await tester.pumpAndSettle();
      expect(find.text('Fictional morning'), findsOneWidget);
      expect(find.text('Fictional today'), findsNothing);
      expect(slideOf(tester, 'Fictional morning'), 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets(
      'a sideways swipe turns the day, and the future comes from the right',
      (tester) async {
        await _mount(tester, Stream.value(records));
        await tester.pumpAndSettle();
        await tester.fling(
          find.text('Fictional today'),
          const Offset(320, 0),
          1200,
        );
        await tester.pumpAndSettle();
        expect(find.text('Fictional evening'), findsOneWidget);
        expect(find.text('Fictional today'), findsNothing);

        // Grab the top of the day's records: the lower rows are off screen.
        await tester.fling(
          find.text('Latest entry'),
          const Offset(-320, 0),
          1200,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(slideOf(tester, 'Fictional today'), greaterThan(0));
        await tester.pumpAndSettle();
        expect(find.text('Fictional today'), findsOneWidget);

        // Nothing lies beyond today.
        await tester.fling(
          find.text('Fictional today'),
          const Offset(-320, 0),
          1200,
        );
        await tester.pumpAndSettle();
        expect(find.text('Fictional today'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('a day before this phone knew anyone is not called quiet', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _mount(
        tester,
        Stream.value([entry('today', 'taken', today, '08:00:00')]),
        // A person arriving now: the real trigger stamps first-seen today.
        seed: (fixture) async {
          final now = DateTime.now().toUtc();
          await fixture.db.profilesDao.upsert(
            ProfilesCompanion.insert(
              id: 'fictional-ana',
              userId: fixture.context.ownerUserId,
              name: 'Fictional Ana',
              createdAt: now,
              updatedAt: now,
            ),
          );
        },
      );
      await tester.pumpAndSettle();
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      expect(
        find.bySemanticsLabel(
          RegExp(
            '^${DateFormat.MMMMEEEEd('en').format(yesterday)}, before '
            '(Fictional Ana was|care began) on this phone\$',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing recorded on'), findsNothing);
      expect(
        find.textContaining(RegExp('^Before (Fictional Ana was|care began)')),
        findsOneWidget,
      );
      expect(find.textContaining('Earlier:'), findsNothing);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('an empty day says which day it is and offers the nearest '
        'days with records', (tester) async {
      final older = DateTime(today.year, today.month, today.day - 3);
      final gap = DateTime(today.year, today.month, today.day - 1);
      await _mount(
        tester,
        Stream.value([
          entry('today', 'taken', today, '08:00:00'),
          entry('older', 'taken', older, '08:00:00'),
        ]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // The day's empty thread falls slack once, then rests.
      final path =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('history-quiet-path')),
                  )
                  .painter!
              as QuietPathPainter;
      expect(path.progress.value, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(path.progress.value, 1);

      final long = DateFormat.MMMMEEEEd('en');
      final short = DateFormat.MMMEd('en');
      expect(
        find.text('Nothing recorded on ${long.format(gap)}'),
        findsOneWidget,
      );
      expect(find.text('No matching records'), findsNothing);
      expect(find.text('Later: ${short.format(today)}'), findsOneWidget);
      await tester.ensureVisible(find.text('Earlier: ${short.format(older)}'));
      // An earlier day exists, so the thread's end is not tied off.
      expect(path.knot, isFalse);
      expect(path.loose, isFalse);
      await tester.tap(find.text('Earlier: ${short.format(older)}'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      // The link tugs the slack its way before the day slides over.
      expect(path.tug.value, inExclusiveRange(0, 1));
      expect(find.text('Fictional older'), findsNothing);
      await tester.pump(HistoryQuietDay.tugDuration);
      await tester.pump(const Duration(milliseconds: 90));
      // Jumping into the past still arrives from the left.
      expect(slideOf(tester, 'Fictional older'), lessThan(0));
      await tester.pumpAndSettle();
      expect(find.text('Fictional older'), findsOneWidget);
      expect(find.textContaining('Nothing recorded on'), findsNothing);

      // A search that finds nothing still says so, not "nothing recorded".
      await tester.tap(find.byTooltip('Search history'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No matching records'), findsOneWidget);
      expect(find.textContaining('Nothing recorded on'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('the day is a line of dose dots on the plain page, no sky', (
      tester,
    ) async {
      await _mount(tester, Stream.value(records));
      await tester.pumpAndSettle();
      expect(find.byType(HistoryDayLine), findsOneWidget);
      expect(find.byType(HorizonScene), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        isNull,
      );
      final line =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('history-day-line')),
                  )
                  .painter!
              as DayLinePainter;
      expect(line.frame.clusters.single.key, 'today');
      // At rest the page asks for no frames.
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('scrolled down, the line docks under the title and lights the '
        'record at the top', (tester) async {
      final busy = [
        for (var h = 6; h < 22; h += 2)
          entry('h$h', 'taken', yesterday, '${'$h'.padLeft(2, '0')}:00:00'),
        entry('today', 'taken', today, '08:00:00'),
      ];
      await _mount(tester, Stream.value(busy));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('history-ribbon-${date(yesterday)}')),
      );
      await tester.pumpAndSettle();
      AnimatedOpacity dock() => tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('history-docked-line')),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(dock().opacity, 0);
      await tester.drag(find.byType(ListView).first, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(dock().opacity, 1);
      final docked =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byKey(const ValueKey('history-docked-line')),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as DayLinePainter;
      expect(docked.selected, startsWith('h'));
      await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(dock().opacity, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('quiet mode changes the day with no slide', (tester) async {
      await _mount(tester, Stream.value(records));
      await tester.pumpAndSettle();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pump();
      expect(find.text('Fictional morning'), findsOneWidget);
      expect(find.text('Fictional today'), findsNothing);
      expect(
        find.ancestor(
          of: find.text('Fictional morning'),
          matching: find.byType(AnimatedSwitcher),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  group('search', () {
    final today = DateUtils.dateOnly(DateTime.now());
    String date(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    HistoryEntry entry(String name, int hour) => HistoryEntry(
      doseLogId: name,
      pillName: name,
      scheduledAt: today,
      plannedLocalDate: date(today),
      plannedLocalTime: '${hour.toString().padLeft(2, '0')}:00:00',
      recordedAt: today.add(Duration(hours: hour + 1)),
      status: 'taken',
      occurrenceState: 'taken',
      profileName: 'Fictional person',
      scheduleId: name,
    );
    // Enough records to push the end of the day well below a short window.
    final records = [
      for (var i = 0; i < 12; i++) entry('Fictional filler ${i + 1}', 6 + i),
      entry('Fictional needle', 19),
    ];
    final field = find.byKey(const ValueKey('history-search'));

    Future<void> mountTall(WidgetTester tester, Size size) async {
      await _mount(tester, Stream.value(records), size: size);
      await tester.pumpAndSettle();
    }

    for (final size in [const Size(390, 600), const Size(753, 1205)]) {
      testWidgets(
        'the field is in view and focused wherever the list is scrolled '
        '(${size.width.toInt()}x${size.height.toInt()})',
        (tester) async {
          await mountTall(tester, size);
          expect(field, findsNothing);
          // Scrolled well past the day line and ribbon, where the field used
          // to sit out of sight.
          await tester.drag(find.byType(ListView).first, const Offset(0, -700));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Search history'));
          await tester.pumpAndSettle();
          expect(field, findsOneWidget);
          final box = tester.getRect(field);
          final window = Offset.zero & size;
          expect(window.contains(box.topLeft), isTrue);
          expect(window.contains(box.bottomRight), isTrue);
          // It is pinned above the list, not a row inside it.
          expect(
            find.descendant(of: find.byType(ListView), matching: field),
            findsNothing,
          );
          expect(
            box.bottom,
            lessThanOrEqualTo(tester.getRect(find.byType(ListView).first).top),
          );
          // Ready to type: the field has focus, so no second tap is needed.
          final editable = tester.widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          expect(editable.focusNode.hasFocus, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('on an expanded window the field sits in the header from the '
        'start', (tester) async {
      await mountTall(tester, const Size(1205, 753));
      expect(field, findsOneWidget);
      // There is no button to open it, and it is not inside the records.
      expect(find.byTooltip('Search history'), findsNothing);
      expect(
        find.descendant(of: find.byType(ListView), matching: field),
        findsNothing,
      );
      expect(tester.getRect(field).bottom, lessThan(80));
      await tester.enterText(field, 'needle');
      await tester.pumpAndSettle();
      expect(find.text('Fictional needle'), findsOneWidget);
      expect(find.text('Fictional filler 1'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing filters the records and closing the field restores '
        'them', (tester) async {
      await mountTall(tester, const Size(753, 1205));
      await tester.tap(find.byTooltip('Search history'));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'needle');
      await tester.pumpAndSettle();
      expect(find.text('Fictional needle'), findsOneWidget);
      expect(find.text('Fictional filler 1'), findsNothing);
      // The close button in the field clears the query and the field.
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(find.text('Fictional filler 1'), findsOneWidget);
    });

    testWidgets('the search button toggles the field and drops the query', (
      tester,
    ) async {
      await mountTall(tester, const Size(753, 1205));
      await tester.tap(find.byTooltip('Search history'));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'needle');
      await tester.pumpAndSettle();
      expect(find.text('Fictional filler 1'), findsNothing);
      // Closing it with the same button must not leave the filter on unseen.
      await tester.tap(find.byTooltip('Search history'));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(find.text('Fictional filler 1'), findsOneWidget);
      // Opening it again starts empty.
      await tester.tap(find.byTooltip('Search history'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    });
  });
}
