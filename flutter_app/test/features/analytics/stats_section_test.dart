import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/stats_section.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/l10n/app_localizations.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

List<WeekAdherence> _twelveWeeks({
  int takenPerWeek = 1,
  int expectedPerWeek = 2,
}) => [
  for (var i = 0; i < 12; i++)
    (
      weekStart: DateTime(2026, 3, 23 + 7 * i),
      taken: takenPerWeek,
      skipped: 0,
      missed: 0,
      expected: expectedPerWeek,
    ),
];

AdherenceStats _stats({
  double? last7Days,
  double? last30Days,
  int prnTaken = 0,
  List<WeekAdherence>? weeklyTrend,
  List<PillAdherence> perPill = const [],
}) => (
  last7Days: last7Days,
  last30Days: last30Days,
  prnTaken: prnTaken,
  weeklyTrend: weeklyTrend ?? _twelveWeeks(),
  perPill: perPill,
);

TrendStats _trend({
  int current = 5,
  int best = 12,
  bool hasScheduledDoses = true,
  List<int>? hourly,
  int prn7Days = 2,
  List<PrnPillCount> prnByPill = const [
    (pillId: 'p3', pillName: 'Fictional headache pill', count: 4),
    (pillId: 'p4', pillName: 'Fictional cough syrup', count: 2),
  ],
}) => (
  streak: (current: current, best: best),
  hasScheduledDoses: hasScheduledDoses,
  hourlyTaken: hourly ?? [for (var h = 0; h < 24; h++) h == 8 ? 9 : 0],
  prn7Days: prn7Days,
  prn30Days: prnByPill.fold<int>(0, (sum, p) => sum + p.count),
  prnByPill: prnByPill,
);

/// The overrides for the trend read: [trend] when given, else a read that has
/// not answered, so the section shows only what it already has.
List<Override> _trendOverrides(TrendStats? trend) => [
  trendStatsProvider.overrideWith(
    (ref) => trend == null ? const Stream.empty() : Stream.value(trend),
  ),
  pillColorsProvider.overrideWith(
    (ref) => const {'p3': '#8E44AD', 'p4': '#16A085'},
  ),
];

Widget _wrap(AdherenceStats stats, {TrendStats? trend, Locale? locale}) =>
    ProviderScope(
      overrides: [
        adherenceStatsProvider.overrideWith((ref) => Stream.value(stats)),
        ..._trendOverrides(trend),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: SingleChildScrollView(child: StatsSection()),
        ),
      ),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('StatsSection', () {
    testWidgets('shows the day streak and the best run beside the windows', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats(last7Days: 1), trend: _trend()));
      await tester.pumpAndSettle();
      expect(find.text('Day streak'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('Best in 12 weeks: 12'), findsOneWidget);
    });

    testWidgets('the streak is an em dash when nothing was scheduled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          _stats(),
          trend: _trend(current: 0, best: 0, hasScheduledDoses: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Day streak'), findsOneWidget);
      expect(find.textContaining('Best in 12 weeks'), findsNothing);
    });

    testWidgets('shows the 30 day as-needed doses apart from adherence', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats(), trend: _trend()));
      await tester.pumpAndSettle();
      expect(find.text('As-needed doses'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
    });

    testWidgets('the trend read arrives later without blocking the rest', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats(last7Days: 5 / 7)));
      await tester.pumpAndSettle();
      expect(find.text('71%'), findsOneWidget);
      expect(find.text('Day streak'), findsNothing);
      expect(find.text('Time of day'), findsNothing);
      expect(find.text('Weekly trend'), findsOneWidget);
    });

    testWidgets('the time of day chart has 24 bars, the busiest hour full', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats(), trend: _trend()));
      await tester.pumpAndSettle();
      expect(find.text('Time of day'), findsOneWidget);
      for (var h = 0; h < 24; h++) {
        expect(find.byKey(ValueKey('time-of-day-$h')), findsOneWidget);
      }
      double heightOf(int h) =>
          tester.getSize(find.byKey(ValueKey('time-of-day-$h'))).height;
      expect(heightOf(8), 72);
      expect(heightOf(9), 3); // an empty hour keeps a hairline
    });

    testWidgets('an empty time of day says so', (tester) async {
      await tester.pumpWidget(
        _wrap(_stats(), trend: _trend(hourly: List.filled(24, 0))),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No doses with a known time in the last 30 days'),
        findsOneWidget,
      );
    });

    testWidgets('lists as-needed use per medication, most used first', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats(), trend: _trend()));
      await tester.pumpAndSettle();
      expect(find.text('As needed by medication'), findsOneWidget);
      expect(find.text('Fictional headache pill'), findsOneWidget);
      expect(find.text('Fictional cough syrup'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Fictional headache pill')).dy,
        lessThan(tester.getTopLeft(find.text('Fictional cough syrup')).dy),
      );
      expect(find.byKey(const ValueKey('as-needed-p3')), findsOneWidget);
    });

    testWidgets('draws each as-needed bar, the most used one full', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats(), trend: _trend()));
      await tester.pumpAndSettle();
      final bars = find.descendant(
        of: find.byKey(const ValueKey('as-needed-p3')),
        matching: find.byType(FractionallySizedBox),
      );
      expect(bars, findsOneWidget);
      // A bar with no height is invisible: the fill must fill its track.
      expect(tester.getSize(bars).height, greaterThan(0));
      expect(tester.getSize(bars).width, greaterThan(0));
    });

    testWidgets('says so when no as-needed dose was taken', (tester) async {
      await tester.pumpWidget(
        _wrap(_stats(), trend: _trend(prnByPill: const [])),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No as-needed doses in the last 30 days'),
        findsOneWidget,
      );
    });

    testWidgets('the new pieces sit above the weekly trend', (tester) async {
      await tester.pumpWidget(_wrap(_stats(), trend: _trend()));
      await tester.pumpAndSettle();
      final weekly = tester.getTopLeft(find.text('Weekly trend')).dy;
      for (final text in [
        'Day streak',
        'Time of day',
        'As needed by medication',
      ]) {
        expect(
          tester.getTopLeft(find.text(text)).dy,
          lessThan(weekly),
          reason: text,
        );
      }
    });

    testWidgets('the weekly trend names its weeks in the app language', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(_stats(), locale: const Locale('ro')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('^Săptămâna din ')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('^Week of')), findsNothing);
      expect(find.textContaining('PRN'), findsNothing);
      semantics.dispose();
    });

    testWidgets('the weekly trend names its weeks in English', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(_stats()));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('^Week of ')), findsWidgets);
      semantics.dispose();
    });

    testWidgets('shows 7 and 30 day percentages', (tester) async {
      await tester.pumpWidget(
        _wrap(_stats(last7Days: 5 / 7, last30Days: 0.8333)),
      );
      await tester.pumpAndSettle();

      expect(find.text('71%'), findsOneWidget);
      expect(find.text('83%'), findsOneWidget);
      expect(find.text('Last 7 days'), findsOneWidget);
      // Both tiles are headed "Adherence", with the period under it.
      expect(find.text('Adherence'), findsNWidgets(2));
      expect(find.text('Last 30 days'), findsOneWidget);
    });

    testWidgets('shows an em dash for empty windows', (tester) async {
      await tester.pumpWidget(_wrap(_stats()));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsNWidgets(2));
    });

    testWidgets('renders 12 trend bars with height proportional to the ratio', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_stats()));
      await tester.pumpAndSettle();

      for (var i = 0; i < 12; i++) {
        expect(find.byKey(ValueKey('trend-bar-$i')), findsOneWidget);
      }
      final box = tester.widget<FractionallySizedBox>(
        find.ancestor(
          of: find.byKey(const ValueKey('trend-bar-5')),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(box.heightFactor, closeTo(0.5, 1e-9));
      expect(find.text('This week'), findsOneWidget);
    });

    testWidgets('weeks with nothing expected render an empty slot', (
      tester,
    ) async {
      final weeks = _twelveWeeks();
      weeks[3] = (
        weekStart: weeks[3].weekStart,
        taken: 0,
        skipped: 0,
        missed: 0,
        expected: 0,
      );
      await tester.pumpWidget(_wrap(_stats(weeklyTrend: weeks)));
      await tester.pumpAndSettle();

      // The empty week has no bar (a zero-height one would break the chart's
      // intrinsic height) but keeps its place as a stub; weeks with a bar have
      // no stub.
      expect(find.byKey(const ValueKey('trend-bar-3')), findsNothing);
      expect(find.byKey(const ValueKey('trend-bar-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('trend-slot-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('trend-slot-4')), findsNothing);
    });

    testWidgets('renders per-pill rows in the given order with fractions', (
      tester,
    ) async {
      final perPill = <PillAdherence>[
        (
          pillId: 'b',
          pillName: 'Bad Pill',
          color: null,
          taken: 1,
          skipped: 0,
          missed: 0,
          expected: 11,
        ),
        (
          pillId: 'g',
          pillName: 'Good Pill',
          color: '#00FF00',
          taken: 10,
          skipped: 1,
          missed: 0,
          expected: 11,
        ),
      ];
      await tester.pumpWidget(_wrap(_stats(perPill: perPill)));
      await tester.pumpAndSettle();

      expect(find.text('Bad Pill'), findsOneWidget);
      expect(find.text('Good Pill'), findsOneWidget);
      expect(find.text('1/11'), findsOneWidget);
      expect(find.text('10/11'), findsOneWidget); // Skipped doses remain due.
      final badY = tester.getTopLeft(find.text('Bad Pill')).dy;
      final goodY = tester.getTopLeft(find.text('Good Pill')).dy;
      expect(badY, lessThan(goodY)); // worst-first order preserved
    });

    testWidgets('shows a hint when no pills had doses', (tester) async {
      await tester.pumpWidget(_wrap(_stats()));
      await tester.pumpAndSettle();
      expect(find.text('No doses in the last 30 days'), findsOneWidget);
    });

    testWidgets('shows an error state with retry', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adherenceStatsProvider.overrideWith(
              (ref) => Stream<AdherenceStats>.error('boom'),
            ),
            ..._trendOverrides(null),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(useMaterial3: true),
            home: const Scaffold(
              body: SingleChildScrollView(child: StatsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Could not load stats'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('invalid hex color falls back to the primary color', (
      tester,
    ) async {
      final perPill = <PillAdherence>[
        (
          pillId: 'x',
          pillName: 'Odd Pill',
          color: 'not-a-color',
          taken: 1,
          skipped: 0,
          missed: 0,
          expected: 2,
        ),
      ];
      await tester.pumpWidget(_wrap(_stats(perPill: perPill)));
      await tester.pumpAndSettle();

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(
        avatar.backgroundColor,
        ThemeData(useMaterial3: true).colorScheme.primary,
      );
    });

    testWidgets('retry after an error reloads the stats', (tester) async {
      var failed = false;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            adherenceStatsProvider.overrideWith((ref) {
              if (failed) return Stream.value(_stats(last7Days: 1.0));
              failed = true;
              return Stream<AdherenceStats>.error('boom');
            }),
            ..._trendOverrides(null),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(useMaterial3: true),
            home: const Scaffold(
              body: SingleChildScrollView(child: StatsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Could not load stats'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Could not load stats'), findsNothing);
    });
  });
}
