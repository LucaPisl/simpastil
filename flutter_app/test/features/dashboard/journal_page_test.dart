import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/today_layout/journal_page.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

InkSignaturePainter? _ink(WidgetTester tester) {
  final paints = tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(InkSignature),
          matching: find.byType(CustomPaint),
        ),
      )
      .map((p) => p.painter)
      .whereType<InkSignaturePainter>();
  return paints.isEmpty ? null : paints.single;
}

Widget _host(String state, {bool quiet = false}) => MaterialApp(
  theme: AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: quiet),
    child: Scaffold(
      body: SizedBox(
        width: 320,
        child: InkSignature(state: state, seed: 'occurrence-1'),
      ),
    ),
  ),
);

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

  group('ink signature', () {
    test('each line keeps its own hand, inside its box', () {
      expect(inkSeed('occurrence-1'), inkSeed('occurrence-1'));
      expect(inkSeed('occurrence-1'), isNot(inkSeed('occurrence-2')));
      const size = Size(320, 14);
      final a = InkSignaturePainter.strokeFor(size, inkSeed('occurrence-1'));
      final b = InkSignaturePainter.strokeFor(size, inkSeed('occurrence-2'));
      expect(a.getBounds(), isNot(b.getBounds()));
      for (final seed in List.generate(40, (i) => inkSeed('o-$i'))) {
        for (final dashed in [false, true]) {
          final bounds = InkSignaturePainter.strokeFor(
            size,
            seed,
            dashed: dashed,
          ).getBounds();
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThan(size.width * .72));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(size.height));
        }
      }
    });

    testWidgets('a planned line has no ink; a recorded one rests written', (
      tester,
    ) async {
      await tester.pumpWidget(_host('pending'));
      expect(_ink(tester), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host('taken'));
      expect(_ink(tester)!.progress, 1);
      expect(_ink(tester)!.dashed, isFalse);
    });

    testWidgets('taking writes the ink; undo lifts it off', (tester) async {
      await tester.pumpWidget(_host('pending'));
      await tester.pumpWidget(_host('taken'));
      await tester.pump(const Duration(milliseconds: 300));
      final writing = _ink(tester)!;
      expect(writing.progress, inExclusiveRange(0, 1));
      expect(writing.writing, isTrue);
      await tester.pumpAndSettle();
      expect(_ink(tester)!.progress, 1);
      expect(_ink(tester)!.writing, isFalse);

      await tester.pumpWidget(_host('pending'));
      await tester.pump(const Duration(milliseconds: 120));
      expect(_ink(tester)!.progress, inExclusiveRange(0, 1));
      // The ink keeps the colour it was written in while it lifts.
      expect(_ink(tester)!.dashed, isFalse);
      await tester.pumpAndSettle();
      expect(_ink(tester), isNull);
    });

    testWidgets('a skipped line gets a dashed stroke in its own colour', (
      tester,
    ) async {
      await tester.pumpWidget(_host('pending'));
      await tester.pumpWidget(_host('skipped'));
      await tester.pumpAndSettle();
      final ink = _ink(tester)!;
      expect(ink.dashed, isTrue);
      final semantic = _light.extension<AppSemanticColors>()!;
      expect(ink.color, semantic.statusSkipped);
    });

    testWidgets('quiet motion shows the written ink at once', (tester) async {
      await tester.pumpWidget(_host('pending', quiet: true));
      await tester.pumpWidget(_host('taken', quiet: true));
      await tester.pump();
      expect(_ink(tester)!.progress, 1);
      await tester.pumpWidget(_host('pending', quiet: true));
      await tester.pump();
      expect(_ink(tester), isNull);
    });
  });
}
