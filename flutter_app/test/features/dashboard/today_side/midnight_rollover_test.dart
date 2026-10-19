import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_provider.dart'
    show CareDayRequest;
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/utils/app_clock.dart';
import 'package:simpastil/features/dashboard/today_side/coming_up.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';
import 'package:simpastil/features/dashboard/today_side/today_side_column.dart';
import 'package:simpastil/features/dashboard/today_side/week_dots.dart';
import 'package:simpastil/features/pills/medication_activity_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/app/today_rollover.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/today_tablet_fixture.dart';

/// A screen left open overnight must move to the new day. Each read below is
/// anchored on today; the clock is pinned and then moved across midnight.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('TodayRollover', () {
    Future<ProviderContainer> mount(
      WidgetTester tester,
      DateTime Function() clock,
    ) async {
      final container = ProviderContainer(
        overrides: [appClockProvider.overrideWithValue(clock)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TodayRollover(child: SizedBox.shrink()),
        ),
      );
      return container;
    }

    testWidgets('holds the clock day and moves on just after local midnight', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 16, 23, 30);
      final container = await mount(tester, () => now);
      expect(container.read(todayProvider), '2026-10-16');

      // The clock has moved on, but midnight itself is half an hour away.
      now = DateTime(2026, 10, 17, 0, 0, 5);
      await tester.pump(const Duration(minutes: 30));
      expect(container.read(todayProvider), '2026-10-16');

      await tester.pump(const Duration(seconds: 2));
      expect(container.read(todayProvider), '2026-10-17');

      // It keeps going: the next midnight is a day away.
      now = DateTime(2026, 10, 18, 0, 0, 5);
      await tester.pump(const Duration(hours: 24));
      expect(container.read(todayProvider), '2026-10-18');
    });

    testWidgets('catches up when the app returns to the foreground', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 16, 22);
      final container = await mount(tester, () => now);
      expect(container.read(todayProvider), '2026-10-16');

      // A sleeping phone does not run the timer; the day still turns.
      now = DateTime(2026, 10, 17, 7);
      await tester.pump();
      expect(container.read(todayProvider), '2026-10-16');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(container.read(todayProvider), '2026-10-17');
    });

    testWidgets('leaves no timer behind once it is gone', (tester) async {
      await mount(tester, () => DateTime(2026, 10, 16, 22));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  testWidgets('Coming up asks for the new day once midnight has passed', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 16, 23, 59, 30);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appClockProvider.overrideWithValue(() => now),
          comingUpProvider.overrideWith(
            (ref, after) async => [
              ComingUpDose(
                pillId: 'p',
                medication: 'After $after',
                personName: 'Me',
                localDate: after,
                localTime: '08:00',
                plannedAt: DateTime.utc(2026, 10, 17, 8),
                amount: const MedicationAmount.unknown(),
              ),
            ],
          ),
        ],
        child: const TodayRollover(
          child: MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: ComingUpCard()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('After 2026-10-16'), findsOneWidget);

    now = DateTime(2026, 10, 17, 0, 0, 5);
    await tester.pump(const Duration(seconds: 40));
    await tester.pump();
    expect(find.text('After 2026-10-17'), findsOneWidget);
    expect(find.text('After 2026-10-16'), findsNothing);
  });

  group('with a household', () {
    final real = DateTime.now();
    // UTC instants, so the fictional routines (which run in UTC) and the
    // device calendar agree on the day whatever zone the test runs in.
    final evening = DateTime.utc(real.year, real.month, real.day, 23, 30);
    final morning = DateTime.utc(real.year, real.month, real.day + 1, 0, 0, 5);
    late DateTime now;
    setUp(() => now = evening);

    Future<ProviderContainer> container(TodayTabletFixture f) async {
      final c = await f.workspace.createContainer(
        extraOverrides: [appClockProvider.overrideWithValue(() => now)],
      );
      addTearDown(c.dispose);
      return c;
    }

    // What TodayRollover does at midnight; it is covered above.
    Future<void> rollOver(ProviderContainer c) async {
      now = morning;
      c.read(todayProvider.notifier).state = routineDateKey(now);
      await c.pump();
    }

    test('This week marks the new day as today', () async {
      final f = await TodayTabletFixture.create();
      addTearDown(f.db.close);
      final c = await container(f);
      final request = CareDayRequest(
        localDate: routineDateKey(DateTime(real.year, real.month, real.day)),
      );
      c.listen(weekDotsProvider(request), (_, _) {});
      final before = await c.read(weekDotsProvider(request).future);
      expect(before.last.today, isTrue);

      // The strip still ends on the day it was opened on, but that day is
      // now yesterday.
      await rollOver(c);
      final after = await c.read(weekDotsProvider(request).future);
      expect(after.last.today, isFalse);
      expect(after.where((d) => d.today), isEmpty);
    });

    test('a medication reads its last days up to the new day', () async {
      final f = await TodayTabletFixture.create();
      addTearDown(f.db.close);
      final c = await container(f);
      c.listen(medicationActivityProvider(f.morning.id), (_, _) {});
      final before = await c.read(
        medicationActivityProvider(f.morning.id).future,
      );
      expect(before.days.last.date, DateTime(real.year, real.month, real.day));

      await rollOver(c);
      final after = await c.read(
        medicationActivityProvider(f.morning.id).future,
      );
      expect(
        after.days.last.date,
        DateTime(real.year, real.month, real.day + 1),
      );
    });

    test('Stock counts its runway from the new day', () async {
      final f = await TodayTabletFixture.create(morningStock: 40, lowAt: 5);
      addTearDown(f.db.close);
      final c = await container(f);
      await c.read(medicationListProvider.future);
      c.listen(todayStockProvider, (_, _) {});
      c.listen(lowStockNoticesProvider, (_, _) {});
      String firstDay() => routineDateKey(
        c
            .read(todayStockProvider)
            .requireValue
            .rows
            .firstWhere((r) => r.pillId == f.morning.id)
            .forecast!
            .days
            .first
            .date,
      );

      expect(
        firstDay(),
        routineDateKey(DateTime(real.year, real.month, real.day)),
      );
      await rollOver(c);
      expect(
        firstDay(),
        routineDateKey(DateTime(real.year, real.month, real.day + 1)),
      );
    });
  });

  testWidgets('the side column follows the day for Coming up', (tester) async {
    var now = DateTime(2026, 10, 16, 23, 59, 30);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appClockProvider.overrideWithValue(() => now),
          comingUpProvider.overrideWith((ref, after) async => const []),
          todayStockProvider.overrideWithValue(
            const AsyncData(StockOverview.empty()),
          ),
          weekDotsProvider.overrideWith((ref, request) => Stream.value([])),
        ],
        child: const TodayRollover(
          child: MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: TodaySideColumn(
                  request: CareDayRequest(localDate: '2026-10-16'),
                  showAsNeeded: false,
                  showComingUp: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // On the day itself the card is offered; once the day has turned, the
    // request is for yesterday and Coming up is no longer shown.
    expect(find.byKey(const ValueKey('coming-up-card')), findsOneWidget);
    now = DateTime(2026, 10, 17, 0, 0, 5);
    await tester.pump(const Duration(seconds: 40));
    await tester.pump();
    expect(find.byKey(const ValueKey('coming-up-card')), findsNothing);
  });
}
