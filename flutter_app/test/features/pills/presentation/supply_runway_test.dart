import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/supply_forecast.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/pills/presentation/supply_runway.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

SupplyForecast _forecast(int stock, {int? threshold, int hour = 6}) =>
    forecastSupply(
      stock: stock,
      threshold: threshold,
      versions: [
        (
          effectiveFrom: DateTime.utc(2026, 9, 1),
          definition: RoutineDefinition(
            kind: RoutineKind.daily,
            timeZone: 'UTC',
            times: const [
              RoutineTime(slotId: 'm', hour: 8, minute: 0),
              RoutineTime(slotId: 'e', hour: 20, minute: 0),
            ],
          ),
        ),
      ],
      now: DateTime.utc(2026, 10, 13, hour),
    )!;

Widget _host(SupplyForecast forecast, {bool quiet = false}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: quiet),
    child: Scaffold(
      body: SingleChildScrollView(
        child: SupplyRunway(forecast: forecast, tint: const Color(0xFF6E66FA)),
      ),
    ),
  ),
);

String _headline(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('supply-headline'))).data!;

double _dayOpacity(WidgetTester tester, String key) => tester
    .widget<Opacity>(
      find.descendant(
        of: find.byKey(ValueKey('supply-day-$key')),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('says until when it lasts and when to refill', (tester) async {
    await tester.pumpWidget(_host(_forecast(9, threshold: 4)));
    await tester.pumpAndSettle();
    expect(_headline(tester), 'Enough until Fri, Oct 16');
    expect(
      find.text('Refill by Thu, Oct 15 to stay above your low-stock level'),
      findsOneWidget,
    );
    // Two weeks of days, the run-out day among them.
    expect(find.byKey(const ValueKey('supply-day-2026-10-13')), findsOneWidget);
    expect(find.byKey(const ValueKey('supply-day-2026-10-26')), findsOneWidget);
    expect(find.byKey(const ValueKey('supply-day-2026-10-27')), findsNothing);
  });

  testWidgets('short today, short later, or none left', (tester) async {
    await tester.pumpWidget(_host(_forecast(1)));
    await tester.pumpAndSettle();
    expect(_headline(tester), "Not enough for today's remaining doses");

    // After 20:00 nothing is left to take today; one dose falls short
    // tomorrow.
    await tester.pumpWidget(_host(_forecast(1, hour: 21)));
    await tester.pumpAndSettle();
    expect(_headline(tester), 'Runs short on Wed, Oct 14');

    await tester.pumpWidget(_host(_forecast(-3)));
    await tester.pumpAndSettle();
    expect(_headline(tester), 'No doses left');
  });

  testWidgets('the days drop in one after another', (tester) async {
    await tester.pumpWidget(_host(_forecast(9)));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_dayOpacity(tester, '2026-10-13'), greaterThan(0));
    expect(_dayOpacity(tester, '2026-10-26'), 0);
    await tester.pumpAndSettle();
    expect(_dayOpacity(tester, '2026-10-26'), 1);
  });

  testWidgets('quiet motion shows the whole strip at once', (tester) async {
    await tester.pumpWidget(_host(_forecast(9), quiet: true));
    await tester.pump();
    expect(_dayOpacity(tester, '2026-10-13'), 1);
    expect(_dayOpacity(tester, '2026-10-26'), 1);
  });

  testWidgets('the strip is decoration; the words carry it', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_forecast(9)));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Enough until Fri, Oct 16'), findsOneWidget);
    // No weekday initials or day numbers in the semantics tree.
    expect(find.bySemanticsLabel('26'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the medication card says when the stock runs out', (
    tester,
  ) async {
    // The card is the phone's list.
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = await CareRecordingFixture.create(legacyStock: -2);
    final container = await fixture.workspace.createContainer();
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
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
          home: const PillsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final line = find.byKey(ValueKey('supply-card-${fixture.pill.id}'));
    expect(line, findsOneWidget);
    expect(tester.widget<Text>(line).data, 'No doses left');
  });
}
