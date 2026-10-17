import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/stats_section.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/analytics/trends_view.dart';
import 'package:simpastil/l10n/app_localizations.dart';

/// The streak, the as-needed figures and the two charts share one read. When
/// it fails they used to vanish without a word, which looks like "no data".
final TrendStats _trend = (
  streak: (current: 4, best: 6),
  hasScheduledDoses: true,
  hourlyTaken: [for (var h = 0; h < 24; h++) h == 8 ? 9 : 0],
  prn7Days: 2,
  prn30Days: 6,
  prnByPill: <PrnPillCount>[
    (pillId: 'p3', pillName: 'Fictional headache pill', count: 4),
  ],
);

const AdherenceStats _stats = (
  last7Days: 0.86,
  last30Days: 0.79,
  prnTaken: 4,
  weeklyTrend: <WeekAdherence>[],
  perPill: <PillAdherence>[],
);

Future<int> _mount(
  WidgetTester tester,
  Widget view, {
  required Locale locale,
  Size size = const Size(1205, 753),
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var reads = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adherenceStatsProvider.overrideWith((ref) => Stream.value(_stats)),
        trendStatsProvider.overrideWith(
          (ref) => reads++ == 0
              ? Stream.error(StateError('the trend read failed'))
              : Stream.value(_trend),
        ),
        pillColorsProvider.overrideWith((ref) => const {'p3': '#8E44AD'}),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: view,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return reads;
}

void main() {
  for (final entry in {
    'the tablet Trends view': (const TrendsView(), 'Day streak'),
    'the phone statistics section': (const StatsSection(), 'Day streak'),
  }.entries) {
    group(entry.key, () {
      testWidgets('says the streak and charts could not load, then retries', (
        tester,
      ) async {
        await _mount(tester, entry.value.$1, locale: const Locale('en'));
        expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
        expect(
          find.text('Could not load the streak and charts'),
          findsOneWidget,
        );
        // What did load is still shown, and the missing tile is not faked.
        expect(find.text('Adherence'), findsWidgets);
        expect(find.text(entry.value.$2), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('trends-error')), findsNothing);
        expect(find.text(entry.value.$2), findsOneWidget);
      });

      testWidgets('speaks Romanian', (tester) async {
        await _mount(tester, entry.value.$1, locale: const Locale('ro'));
        expect(
          find.text('Nu s-au putut încărca seria de zile și graficele'),
          findsOneWidget,
        );
        expect(find.text('Reîncearcă'), findsOneWidget);
      });
    });
  }

  testWidgets('a read that is still loading shows no error', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adherenceStatsProvider.overrideWith((ref) => Stream.value(_stats)),
          trendStatsProvider.overrideWith((ref) => const Stream.empty()),
          pillColorsProvider.overrideWith((ref) => const {}),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: StatsSection())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('trends-error')), findsNothing);
  });
}
