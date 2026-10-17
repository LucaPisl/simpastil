import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/care_record_form.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/review_rendering.dart';
import '../../helpers/today_tablet_fixture.dart';

const _layoutKeys = <LayoutFamily, String>{
  LayoutFamily.focusDeck: 'focus-current-card',
  LayoutFamily.timeline: 'timeline-layout',
  LayoutFamily.peopleLanes: 'people-lanes-layout',
  LayoutFamily.dayPlanner: 'planner-layout',
  LayoutFamily.actionInbox: 'inbox-layout',
  LayoutFamily.dailyJournal: 'journal-layout',
};

const _landscape = Size(1205, 753);
const _portrait = Size(753, 1205);
const _phone = Size(412, 915);
const _smallPhone = Size(360, 800);

Finder _key(String key) => find.byKey(ValueKey(key));

/// Presses the first "Dose details" and lets the panel or page arrive.
Future<void> _openDetails(WidgetTester tester) async {
  final button = find.text('Dose details').first;
  await tester.ensureVisible(button);
  await settleToday(tester, 300);
  await tester.tap(button);
  await settleToday(tester, 800);
}

/// The notice a layout draws for one low medication, in its own form.
Finder _lowNotice(LayoutFamily family, String pillId) => switch (family) {
  LayoutFamily.dailyJournal => _key('journal-stock-$pillId'),
  _ => _key('low-stock-$pillId'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  group('expanded: two panes', () {
    for (final entry in _layoutKeys.entries) {
      testWidgets('${entry.key.name} sits left of the shared right column', (
        tester,
      ) async {
        final f = await TodayTabletFixture.create(morningStock: 40, lowAt: 5);
        await mountToday(tester, f, family: entry.key);
        expect(_key(entry.value), findsOneWidget);
        // The same column, whatever the layout: As needed, Stock, This week.
        expect(_key('today-side-column'), findsOneWidget);
        expect(_key('as-needed-card'), findsOneWidget);
        expect(_key('stock-card'), findsOneWidget);
        expect(_key('week-card'), findsOneWidget);
        expect(_key('coming-up-card'), findsNothing);
        final layout = tester.getRect(_key(entry.value));
        final side = tester.getRect(_key('today-side-column'));
        expect(layout.right, lessThanOrEqualTo(side.left + 1));
        // The tablet's sky card; the phone's week strip is not drawn.
        expect(_key('today-sky-card'), findsOneWidget);
        expect(_key('week-strip'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the panes scroll on their own', (tester) async {
      final f = await TodayTabletFixture.create(
        morningStock: 40,
        lowAt: 5,
        asNeeded: 6,
      );
      await mountToday(
        tester,
        f,
        family: LayoutFamily.timeline,
        textScale: 1.3,
      );
      final layoutTop = tester.getTopLeft(_key('timeline-layout')).dy;
      final sideTop = tester.getTopLeft(_key('today-side-column')).dy;
      await tester.drag(_key('today-side-column'), const Offset(0, -300));
      await settleToday(tester, 400);
      // The right column moved up; the chosen layout did not move.
      expect(
        tester.getTopLeft(_key('today-side-column')).dy,
        lessThan(sideTop),
      );
      expect(tester.getTopLeft(_key('timeline-layout')).dy, layoutTop);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the right column shows tracked stock and the week', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(morningStock: 40, lowAt: 5);
      await mountToday(tester, f);
      final morning = f.morning.id;
      // Only medication whose stock is counted is listed.
      expect(_key('stock-row-$morning'), findsOneWidget);
      expect(_key('stock-row-${f.evening.id}'), findsNothing);
      expect(
        find.descendant(
          of: _key('stock-row-$morning'),
          matching: find.textContaining('40'),
        ),
        findsWidgets,
      );
      // Seven days, the viewed one last, each with a dot.
      final today = TodayTabletFixture.today;
      for (var i = 0; i < 7; i++) {
        final day = DateTime(today.year, today.month, today.day - i);
        expect(_key('week-dot-${day.day}'), findsOneWidget, reason: '$day');
      }
      expect(
        find.descendant(
          of: _key('week-card'),
          matching: find.text('0 recorded'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the Stock card says so when nothing is counted', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f);
      expect(
        find.text('Stock counts you keep for your medicines show up here.'),
        findsOneWidget,
      );
    });

    testWidgets('the week counts a dose when it is recorded', (tester) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f, family: LayoutFamily.focusDeck);
      await tester.tap(_key('focus-taken'));
      await settleToday(tester, 2500);
      expect(
        find.descendant(
          of: _key('week-card'),
          matching: find.text('1 recorded'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('as needed is a grid of up to three ring cards', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(asNeeded: 4);
      await mountToday(tester, f);
      final cards = [
        for (final pill in f.asNeeded)
          tester.getRect(_key('as-needed-card-${pill.id}')),
      ];
      expect(cards.where((c) => c.top == cards.first.top), hasLength(3));
      expect(cards.last.top, greaterThan(cards.first.top));
    });
  });

  group('Focus deck on a tablet', () {
    testWidgets('records at another time and skips through the same form', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f, family: LayoutFamily.focusDeck);
      expect(_key('focus-other-time'), findsOneWidget);
      expect(_key('focus-skip'), findsOneWidget);
      await tester.tap(_key('focus-other-time'));
      await settleToday(tester, 600);
      expect(find.byType(CareRecordForm), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Skip opens the same form set to skipped', (tester) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f, family: LayoutFamily.focusDeck);
      await tester.tap(_key('focus-skip'));
      await settleToday(tester, 600);
      final form = tester.widget<CareRecordForm>(find.byType(CareRecordForm));
      expect(form.initialState.name, 'skipped');
    });

    testWidgets('a phone keeps one primary action, with both others in Dose '
        'details', (tester) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f, family: LayoutFamily.focusDeck, size: _phone);
      expect(_key('focus-taken'), findsOneWidget);
      expect(_key('focus-other-time'), findsNothing);
      expect(_key('focus-skip'), findsNothing);
    });
  });

  group('Dose details', () {
    testWidgets('open beside Today on an expanded window and close again', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(asNeeded: 3);
      final mount = await mountToday(tester, f);
      expect(_key('dose-details-panel'), findsNothing);
      await _openDetails(tester);
      // A panel in place of the right column; no page was pushed.
      expect(_key('dose-details-panel'), findsOneWidget);
      expect(_key('dose-details-close'), findsOneWidget);
      expect(_key('today-side-column'), findsNothing);
      expect(mount.location, '/');
      await captureReview(tester, 'today-details-panel-1205x753-light');
      // As needed moves under the layout in the left pane.
      expect(_key('as-needed-card'), findsOneWidget);
      expect(
        tester.getRect(_key('as-needed-card')).right,
        lessThanOrEqualTo(tester.getRect(_key('dose-details-panel')).left + 1),
      );
      await tester.tap(_key('dose-details-close'));
      await settleToday(tester, 800);
      expect(_key('dose-details-panel'), findsNothing);
      expect(_key('today-side-column'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('the panel fits in the dark theme at x$scale', (
        tester,
      ) async {
        final f = await TodayTabletFixture.create(
          morningStock: 40,
          lowAt: 5,
          asNeeded: 3,
        );
        await mountToday(tester, f, dark: true, textScale: scale);
        await _openDetails(tester);
        expect(_key('dose-details-panel'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureReview(
          tester,
          'today-details-panel-1205x753-x$scale-dark',
        );
      });
    }

    testWidgets('close when the day changes', (tester) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f);
      await _openDetails(tester);
      expect(_key('dose-details-panel'), findsOneWidget);
      await tester.tap(_key('today-card-Previous day'));
      await settleToday(tester, 1000);
      expect(_key('dose-details-panel'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('close when the window stops being expanded', (tester) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f);
      await _openDetails(tester);
      expect(_key('dose-details-panel'), findsOneWidget);
      tester.view.physicalSize = _portrait;
      await settleToday(tester, 800);
      expect(_key('dose-details-panel'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final size in [_phone, _portrait]) {
      testWidgets('push the page on ${size.width.toInt()} wide windows', (
        tester,
      ) async {
        final f = await TodayTabletFixture.create();
        final mount = await mountToday(tester, f, size: size);
        await _openDetails(tester);
        expect(mount.location, startsWith('/doses/'));
        expect(_key('dose-details-panel'), findsNothing);
        expect(tester.takeException(), isNull);
        await captureReview(
          tester,
          'today-details-page-${size.width.toInt()}x${size.height.toInt()}',
        );
      });
    }

    testWidgets('the panel has the actions, stock left and earlier slots', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(morningStock: 40, lowAt: 5);
      await mountToday(tester, f, family: LayoutFamily.focusDeck);
      await _openDetails(tester);
      final panel = _key('dose-details-panel');
      expect(
        find.descendant(of: panel, matching: find.text('Taken now')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.text('Taken at another time'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.text('Skipped')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('low stock', () {
    for (final family in LayoutFamily.values) {
      testWidgets('${family.name}: a notice only when a medication runs low', (
        tester,
      ) async {
        final f = await TodayTabletFixture.create(morningStock: 3, lowAt: 5);
        await mountToday(tester, f, family: family, size: _phone);
        expect(
          _lowNotice(family, f.morning.id),
          findsOneWidget,
          reason: 'the morning tablet is down to 3',
        );
        // Only that one medication; the others are not tracked.
        expect(_lowNotice(family, f.evening.id), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${family.name}: no notice while stock is comfortable', (
        tester,
      ) async {
        final f = await TodayTabletFixture.create(morningStock: 300, lowAt: 5);
        await mountToday(tester, f, family: family, size: _phone);
        expect(_lowNotice(family, f.morning.id), findsNothing);
        expect(_key('low-stock-add'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Action inbox puts it under Needs you, with Add stock and '
        'Later', (tester) async {
      final f = await TodayTabletFixture.create(morningStock: 3, lowAt: 5);
      await mountToday(
        tester,
        f,
        family: LayoutFamily.actionInbox,
        size: _phone,
      );
      expect(_key('inbox-stock-${f.morning.id}'), findsOneWidget);
      expect(_key('low-stock-add'), findsOneWidget);
      expect(_key('low-stock-later'), findsOneWidget);
      await tester.ensureVisible(_key('low-stock-later'));
      await tester.tap(_key('low-stock-later'));
      await settleToday(tester, 600);
      // Put off until tomorrow, on this device only.
      expect(_key('inbox-stock-${f.morning.id}'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add stock opens the existing medication editor', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(morningStock: 3, lowAt: 5);
      await mountToday(tester, f, family: LayoutFamily.timeline, size: _phone);
      await tester.ensureVisible(_key('low-stock-add'));
      await tester.tap(_key('low-stock-add'));
      await settleToday(tester, 1500);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tablet shows it in the Stock card, not as a notice', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create(morningStock: 3, lowAt: 5);
      await mountToday(tester, f, family: LayoutFamily.actionInbox);
      expect(_key('low-stock-${f.morning.id}'), findsNothing);
      expect(_key('stock-row-${f.morning.id}'), findsOneWidget);
      expect(_key('stock-add-${f.morning.id}'), findsOneWidget);
      await tester.ensureVisible(_key('stock-add-${f.morning.id}'));
      await settleToday(tester, 500);
      await tester.tap(_key('stock-add-${f.morning.id}'));
      await settleToday(tester, 1500);
      // Wide windows open the editor as a dialog with its preview column.
      expect(find.byType(Dialog), findsOneWidget);
      expect(_key('edit-medication-stock'), findsOneWidget);
    });
  });

  group('phone week strip', () {
    testWidgets('sits in the header with seven days', (tester) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f, size: _phone);
      expect(_key('week-strip'), findsOneWidget);
      expect(_key('today-side-column'), findsNothing);
      for (var i = 0; i < 7; i++) {
        final day = DateTime.now().subtract(Duration(days: i));
        expect(_key('week-dot-${day.day}'), findsNothing);
      }
      final strip = tester.getRect(_key('week-strip'));
      // In the sky header, above the cards.
      expect(strip.top, lessThan(180));
      expect(strip.right, lessThanOrEqualTo(_phone.width));
      expect(tester.takeException(), isNull);
    });

    testWidgets('is not on a tablet, where the This week card carries it', (
      tester,
    ) async {
      final f = await TodayTabletFixture.create();
      await mountToday(tester, f, size: _portrait);
      expect(_key('week-strip'), findsNothing);
      expect(_key('week-card'), findsOneWidget);
    });
  });

  group('medium: one column', () {
    testWidgets('stacks the sky, layout, As needed, Stock beside This week '
        'and Coming up', (tester) async {
      final f = await TodayTabletFixture.create(morningStock: 40, lowAt: 5);
      await mountToday(tester, f, size: _portrait);
      expect(_key('today-sky-card'), findsOneWidget);
      final sky = tester.getRect(_key('today-sky-card'));
      final asNeeded = tester.getRect(_key('as-needed-card'));
      final stock = tester.getRect(_key('stock-card'));
      final week = tester.getRect(_key('week-card'));
      expect(asNeeded.top, greaterThan(sky.bottom));
      // Stock and This week share a row.
      expect(stock.top, closeTo(week.top, 1));
      expect(stock.right, lessThanOrEqualTo(week.left + 1));
      expect(stock.top, greaterThan(asNeeded.bottom - 1));
      await tester.scrollUntilVisible(
        _key('coming-up-card'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.getRect(_key('coming-up-card')).top,
        greaterThan(tester.getRect(_key('stock-card')).top),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('no overflow', () {
    final capturing = Platform.environment['REVIEW_CAPTURE_DIR'] != null;
    for (final size in [_landscape, _portrait, _phone, _smallPhone]) {
      for (final family in LayoutFamily.values) {
        for (final scale in [1.0, 1.3]) {
          for (final dark in [false, if (capturing) true]) {
            final label =
                '${family.name} ${size.width.toInt()}x${size.height.toInt()} '
                'x$scale ${dark ? 'dark' : 'light'}';
            testWidgets(label, (tester) async {
              final f = await TodayTabletFixture.create(
                morningStock: 3,
                lowAt: 5,
                asNeeded: 3,
                second: true,
              );
              await mountToday(
                tester,
                f,
                family: family,
                size: size,
                textScale: scale,
                dark: dark,
              );
              expect(tester.takeException(), isNull);
              if (family == LayoutFamily.focusDeck && size.width >= 600) {
                // The deck has settled: its actions can be pressed.
                expect(
                  tester
                      .widget<OutlinedButton>(_key('focus-other-time'))
                      .onPressed,
                  isNotNull,
                );
              }
              await captureReview(
                tester,
                'today-${family.name}-${size.width.toInt()}x'
                '${size.height.toInt()}-x$scale-${dark ? 'dark' : 'light'}',
              );
            });
          }
        }
      }
    }
  });
}
