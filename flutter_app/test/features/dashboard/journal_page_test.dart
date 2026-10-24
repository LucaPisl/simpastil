import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/today_layout/journal_page.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

JournalInkWellPainter _well(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(JournalInkWell),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as JournalInkWellPainter;

// One theme for every pump, so the app doesn't animate between equal ones.
final _light = AppTheme.light();

Widget _wellHost(
  List<String> states, {
  List<String>? from,
  bool quiet = false,
}) => MaterialApp(
  theme: _light,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: quiet),
    child: Scaffold(
      body: Center(
        child: JournalInkWell(
          states: states,
          from: from,
          time: JournalPeriodTime.now,
        ),
      ),
    ),
  ),
);

void main() {
  group('journal periods', () {
    test('a period is past, now or ahead of the clock', () {
      final noon = DateTime(2026, 10, 13, 12, 30);
      expect(journalPeriodTime('morning', noon), JournalPeriodTime.past);
      expect(journalPeriodTime('afternoon', noon), JournalPeriodTime.now);
      expect(journalPeriodTime('evening', noon), JournalPeriodTime.future);
      expect(journalPeriodTime('night', noon), JournalPeriodTime.future);

      final late = DateTime(2026, 10, 13, 22);
      expect(journalPeriodTime('evening', late), JournalPeriodTime.past);
      expect(journalPeriodTime('night', late), JournalPeriodTime.now);
    });

    test('before dawn it is still night and the whole day is ahead', () {
      final early = DateTime(2026, 10, 13, 3, 10);
      expect(journalPeriodTime('night', early), JournalPeriodTime.now);
      for (final period in ['morning', 'afternoon', 'evening']) {
        expect(journalPeriodTime(period, early), JournalPeriodTime.future);
      }
      expect(
        journalPeriodTime('morning', DateTime(2026, 10, 13, 5)),
        JournalPeriodTime.now,
      );
    });
  });

  group('ink well', () {
    testWidgets('the ink is as high as the period is recorded', (tester) async {
      await tester.pumpWidget(_wellHost(['taken', 'skipped', 'pending']));
      final semantic = _light.extension<AppSemanticColors>()!;
      final painter = _well(tester);
      expect(painter.level, closeTo(2 / 3, 1e-9));
      expect(painter.marks, 3);
      expect(painter.bands, [semantic.statusTaken, semantic.statusSkipped]);
      expect(painter.tilt, 0);
      expect(painter.edge, _light.colorScheme.primary);
    });

    testWidgets('a recorded miss draws its own band, unlike a pending dose', (
      tester,
    ) async {
      await tester.pumpWidget(_wellHost(['taken', 'missed', 'pending']));
      final semantic = _light.extension<AppSemanticColors>()!;
      final painter = _well(tester);
      expect(painter.level, closeTo(2 / 3, 1e-9));
      expect(painter.marks, 3);
      expect(painter.bands, [semantic.statusTaken, semantic.statusMissed]);
    });

    testWidgets('recording a dose raises the ink and rocks the well once', (
      tester,
    ) async {
      await tester.pumpWidget(_wellHost(['taken', 'pending']));
      await tester.pumpWidget(_wellHost(['taken', 'taken']));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_well(tester).level, inExclusiveRange(.5, 1));
      expect(_well(tester).bands, hasLength(2));
      // Upright while the ink is still on its way; it rocks as it lands.
      expect(_well(tester).tilt, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_well(tester).tilt, isNot(0));
      await tester.pumpAndSettle();
      expect(_well(tester).level, 1);
      expect(_well(tester).tilt, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('an undo lowers the ink without rocking, then drops the band', (
      tester,
    ) async {
      await tester.pumpWidget(_wellHost(['taken', 'taken']));
      await tester.pumpWidget(_wellHost(['taken', 'pending']));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_well(tester).level, inExclusiveRange(.5, 1));
      // The band on its way out stays until the level has passed it.
      expect(_well(tester).bands, hasLength(2));
      expect(_well(tester).tilt, 0);
      await tester.pumpAndSettle();
      expect(_well(tester).level, .5);
      expect(_well(tester).bands, hasLength(1));
    });

    testWidgets('quiet motion shows the new level at once', (tester) async {
      await tester.pumpWidget(_wellHost(['pending'], quiet: true));
      await tester.pumpWidget(_wellHost(['taken'], quiet: true));
      await tester.pump();
      expect(_well(tester).level, 1);
      expect(_well(tester).tilt, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a well that appears for a dose just recorded fills from '
        'where it was', (tester) async {
      await tester.pumpWidget(_wellHost(['taken'], from: ['pending']));
      expect(_well(tester).level, 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_well(tester).level, inExclusiveRange(0, 1));
      expect(_well(tester).tilt, isNot(0));
      await tester.pumpAndSettle();
      expect(_well(tester).level, 1);
      expect(_well(tester).tilt, 0);
    });

    testWidgets('a well that appears with nothing new shows at rest', (
      tester,
    ) async {
      await tester.pumpWidget(_wellHost(['taken'], from: ['taken']));
      expect(_well(tester).level, 1);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('quiet motion fills an appearing well at once', (tester) async {
      await tester.pumpWidget(
        _wellHost(['taken'], from: ['pending'], quiet: true),
      );
      await tester.pump();
      expect(_well(tester).level, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    test('the rock starts and ends upright', () {
      expect(JournalInkWellPainter.tiltAt(0), 0);
      expect(JournalInkWellPainter.tiltAt(1), 0);
      expect(JournalInkWellPainter.tiltAt(.15).abs(), greaterThan(.05));
    });
  });
}
