import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/core/utils/app_clock.dart';
import 'package:simpastil/features/dashboard/day_overview.dart';
import 'package:simpastil/features/dashboard/today_side/coming_up.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/review_rendering.dart';
import '../../helpers/today_tablet_fixture.dart';
import '../../helpers/window_view.dart';

const _phone = Size(412, 915);

/// What a phone sees of Coming up: the tablet's side column is not there, so
/// the Day overview sheet carries the same next planned doses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  testWidgets('on a phone the Day overview ends with the next planned doses', (
    tester,
  ) async {
    final f = await TodayTabletFixture.create();
    await mountToday(tester, f, family: LayoutFamily.focusDeck, size: _phone);
    expect(find.byKey(const ValueKey('coming-up-card')), findsNothing);

    final overview = find.text('Day overview');
    await tester.ensureVisible(overview);
    await settleToday(tester, 300);
    await tester.tap(overview);
    await settleToday(tester, 800);

    final section = find.byKey(const ValueKey('overview-coming-up'));
    await tester.scrollUntilVisible(
      section,
      140,
      scrollable: find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable),
      ),
    );
    await settleToday(tester, 300);
    expect(
      find.descendant(of: section, matching: find.text('Coming up')),
      findsOneWidget,
    );
    // Both daily tablets are planned again tomorrow, as on the tablet card.
    for (final pill in [f.morning, f.evening]) {
      expect(
        find.byKey(ValueKey('overview-coming-up-${pill.id}')),
        findsOneWidget,
      );
    }
    expect(find.text('Planned'), findsNWidgets(2));
    expect(find.textContaining('Tomorrow'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  group('the sheet on its own', () {
    final clock = DateTime(2026, 10, 16, 12);
    final dose = ComingUpDose(
      pillId: 'p1',
      medication: 'Fevarin',
      personName: 'Ana',
      localDate: '2026-10-17',
      localTime: '08:00',
      plannedAt: DateTime.utc(2026, 10, 17, 8),
      amount: const MedicationAmount.unknown(),
    );

    Future<void> open(
      WidgetTester tester,
      List<ComingUpDose> next, {
      String? localDate = '2026-10-16',
    }) async {
      useWindow(tester, _phone);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appClockProvider.overrideWithValue(() => clock),
            comingUpProvider.overrideWith((ref, after) async => next),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showDayOverview(
                      context,
                      const [],
                      null,
                      localDate: localDate,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists what is planned after today', (tester) async {
      await open(tester, [dose]);
      expect(find.text('Day overview'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-coming-up')), findsOneWidget);
      expect(find.text('Fevarin'), findsOneWidget);
      expect(find.textContaining('Tomorrow'), findsOneWidget);
      expect(find.text('Planned'), findsOneWidget);
    });

    testWidgets('is left out when nothing is planned', (tester) async {
      await open(tester, const []);
      expect(find.text('Day overview'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-coming-up')), findsNothing);
      expect(find.text('Coming up'), findsNothing);
      expect(find.text('Nothing is planned after today.'), findsNothing);
    });

    testWidgets('is left out for a day that is not today', (tester) async {
      await open(tester, [dose], localDate: '2026-10-15');
      expect(find.byKey(const ValueKey('overview-coming-up')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    });

    testWidgets('is left out when the caller names no day', (tester) async {
      await open(tester, [dose], localDate: null);
      expect(find.byKey(const ValueKey('overview-coming-up')), findsNothing);
    });
  });
}
