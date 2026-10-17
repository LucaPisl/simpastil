import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/analytics/trends_view.dart';
import 'package:simpastil/l10n/app_localizations.dart';

/// Twelve weeks, the first [empty] of them with nothing due (as a new account
/// has: only its latest weeks carry a scheduled dose).
List<WeekAdherence> _weeks({int empty = 0}) => [
  for (var i = 0; i < 12; i++)
    (
      weekStart: DateTime(2026, 3, 23 + 7 * i),
      taken: i < empty ? 0 : 1 + i % 3,
      skipped: 0,
      missed: 0,
      expected: i < empty ? 0 : 4,
    ),
];

AdherenceStats _stats(List<WeekAdherence> weeks) => (
  last7Days: 0.86,
  last30Days: 0.79,
  prnTaken: 4,
  weeklyTrend: weeks,
  perPill: <PillAdherence>[
    (
      pillId: 'p1',
      pillName: 'Fictional morning pill',
      color: '#2E86C1',
      taken: 20,
      skipped: 1,
      missed: 0,
      expected: 30,
    ),
  ],
);

final TrendStats _trend = (
  streak: (current: 4, best: 4),
  hasScheduledDoses: true,
  hourlyTaken: [for (var h = 0; h < 24; h++) h == 8 ? 9 : 0],
  prn7Days: 2,
  prn30Days: 6,
  prnByPill: <PrnPillCount>[
    (pillId: 'p3', pillName: 'Fictional headache pill', count: 4),
  ],
);

Future<void> _mount(WidgetTester tester, List<WeekAdherence> weeks) async {
  tester.view.physicalSize = const Size(1205, 753);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adherenceStatsProvider.overrideWith(
          (ref) => Stream.value(_stats(weeks)),
        ),
        trendStatsProvider.overrideWith((ref) => Stream.value(_trend)),
        pillColorsProvider.overrideWith((ref) => const {'p1': '#2E86C1'}),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: TrendsView(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TrendsView', () {
    testWidgets('lays out when the early weeks had nothing due', (
      tester,
    ) async {
      // A week with nothing due has no bar. It must not turn the weekly chart's
      // intrinsic height into a division by zero, which blanks the whole view.
      await _mount(tester, _weeks(empty: 7));

      expect(tester.takeException(), isNull);
      for (final text in [
        'Weekly trend',
        'By medication',
        'Time of day',
        'Day streak',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      final weekly = find
          .ancestor(of: find.text('Weekly trend'), matching: find.byType(Card))
          .first;
      final other = find
          .ancestor(of: find.text('By medication'), matching: find.byType(Card))
          .first;
      expect(
        tester.getSize(weekly).height,
        tester.getSize(other).height,
        reason: 'the two cards stay level',
      );
      for (var i = 0; i < 7; i++) {
        expect(find.byKey(ValueKey('trend-slot-$i')), findsOneWidget);
      }
    });

    testWidgets('lays out when no week had anything due', (tester) async {
      await _mount(tester, _weeks(empty: 12));

      expect(tester.takeException(), isNull);
      expect(find.text('Weekly trend'), findsOneWidget);
      expect(find.text('By medication'), findsOneWidget);
    });

    testWidgets('lays out with every week filled', (tester) async {
      await _mount(tester, _weeks());

      expect(tester.takeException(), isNull);
      for (var i = 0; i < 12; i++) {
        expect(find.byKey(ValueKey('trend-bar-$i')), findsOneWidget);
      }
    });
  });
}
