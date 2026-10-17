import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/schedules/presentation/dose_dial.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

void main() {
  // A phone, so the dial keeps its words in the middle.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 2.625;
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Widget app(
    Widget child, {
    bool quiet = false,
    double textScale = 1,
    bool twentyFourHour = false,
  }) => MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, page) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: quiet,
        textScaler: TextScaler.linear(textScale),
        alwaysUse24HourFormat: twentyFourHour,
      ),
      child: page!,
    ),
    home: Scaffold(body: child),
  );

  DoseDialPainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(find.byKey(const ValueKey('dose-dial')))
              .painter!
          as DoseDialPainter;

  /// Where [minute]'s capsule sits on screen.
  Offset capsuleAt(WidgetTester tester, double minute) {
    final box = tester.getRect(find.byKey(const ValueKey('dose-dial')));
    final r = DoseDialPainter.radiusIn(box.size);
    final a = DoseDial.angleOf(minute);
    return box.center + Offset(math.cos(a), math.sin(a)) * r;
  }

  test('midnight sits at the bottom, noon at the top, morning on the left', () {
    expect(DoseDial.angleOf(0), closeTo(math.pi / 2, 1e-9));
    expect(DoseDial.angleOf(720), closeTo(math.pi * 3 / 2, 1e-9));
    expect(math.cos(DoseDial.angleOf(6 * 60)), closeTo(-1, 1e-9));
    for (final m in [0.0, 90.0, 555.0, 1439.0]) {
      expect(DoseDial.minuteAt(DoseDial.angleOf(m)), closeTo(m, 1e-6));
    }
    expect(DoseDial.snap(9 * 60 + 7), 9 * 60);
    expect(DoseDial.snap(9 * 60 + 8), 9 * 60 + 15);
    expect(DoseDial.snap(1439), 0);
  });

  testWidgets('a new time glides the short way round, then rests', (
    tester,
  ) async {
    Widget dial(TimeOfDay t) => app(Center(child: DoseDial(times: [t])));
    await tester.pumpWidget(dial(const TimeOfDay(hour: 23, minute: 0)));
    await tester.pumpWidget(dial(const TimeOfDay(hour: 1, minute: 0)));
    await tester.pump(const Duration(milliseconds: 160));
    final mid = painter(tester).minutes.single % 1440;
    // Through midnight, never past noon.
    expect(mid > 23 * 60 || mid < 60, isTrue, reason: '$mid');
    await tester.pumpAndSettle();
    expect(painter(tester).minutes.single % 1440, 60);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet mode puts a new time in place at once', (tester) async {
    Widget dial(TimeOfDay t) =>
        app(Center(child: DoseDial(times: [t])), quiet: true);
    await tester.pumpWidget(dial(const TimeOfDay(hour: 8, minute: 0)));
    await tester.pumpWidget(dial(const TimeOfDay(hour: 20, minute: 0)));
    expect(painter(tester).minutes.single, 20 * 60);
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter(tester).minutes.single, 20 * 60);
  });

  testWidgets('a time added drops into its place', (tester) async {
    const morning = TimeOfDay(hour: 8, minute: 0);
    const evening = TimeOfDay(hour: 20, minute: 0);
    await tester.pumpWidget(
      app(const Center(child: DoseDial(times: [morning]))),
    );
    await tester.pumpWidget(
      app(const Center(child: DoseDial(times: [morning, evening], focus: 1))),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(painter(tester).dropped, 1);
    expect(painter(tester).drop, inExclusiveRange(0, 1));
    // It is not also gliding in from the old focus.
    expect(painter(tester).minutes[1], 20 * 60);
    await tester.pumpAndSettle();
    expect(painter(tester).dropped, isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('dragging a capsule steps its time with the finger, over a '
      'scrolling sheet', (tester) async {
    var time = const TimeOfDay(hour: 9, minute: 0);
    final changes = <TimeOfDay>[];
    final scroll = ScrollController();
    var taps = 0;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => ListView(
            controller: scroll,
            children: [
              const SizedBox(height: 120),
              InkWell(
                onTap: () => taps++,
                child: DoseDial(
                  times: [time],
                  onChanged: (_, t) => setState(() {
                    changes.add(t);
                    time = t;
                  }),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byKey(const ValueKey('dose-dial')));
    final gesture = await tester.startGesture(capsuleAt(tester, 9 * 60));
    // Up and over to the top of the ring: noon.
    await gesture.moveTo(capsuleAt(tester, 10 * 60));
    await tester.pump();
    await gesture.moveTo(box.center + const Offset(0, -50));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(time, const TimeOfDay(hour: 12, minute: 0));
    expect(changes, isNotEmpty);
    expect(changes.every((t) => t.minute % DoseDial.step == 0), isTrue);
    // The sheet did not scroll, and the card was not tapped.
    expect(scroll.offset, 0);
    expect(taps, 0);
    expect(painter(tester).minutes.single, 12 * 60);

    // A press away from the capsules is the card's: a tap opens the picker,
    // a drag scrolls.
    await tester.tapAt(box.center);
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.dragFrom(box.center, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
  });

  testWidgets('a screen reader steps the focused time by a quarter hour', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var time = const TimeOfDay(hour: 9, minute: 10);
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => Center(
            child: DoseDial(
              times: [time],
              onChanged: (_, t) => setState(() => time = t),
            ),
          ),
        ),
      ),
    );
    final dialLabel = RegExp('^Dose times on the day dial');
    final node = find.bySemanticsLabel(dialLabel);
    expect(
      tester.getSemantics(node),
      matchesSemantics(
        label: 'Dose times on the day dial: 9:10 AM, Morning',
        value: '9:10 AM',
        increasedValue: '9:25 AM',
        decreasedValue: '8:55 AM',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    tester.semantics.decrease(find.semantics.byLabel(dialLabel));
    await tester.pumpAndSettle();
    // Off the grid, it steps onto it first.
    expect(time, const TimeOfDay(hour: 9, minute: 0));
    tester.semantics.increase(find.semantics.byLabel(dialLabel));
    await tester.pumpAndSettle();
    expect(time, const TimeOfDay(hour: 9, minute: 15));
    handle.dispose();
  });

  testWidgets('a 24-hour phone hears and sees the dial in 24 hours', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        Center(
          child: DoseDial(
            times: const [TimeOfDay(hour: 9, minute: 10)],
            onChanged: (_, _) {},
          ),
        ),
        twentyFourHour: true,
      ),
    );
    expect(find.text('09:10'), findsOneWidget);
    expect(find.text('9:10 AM'), findsNothing);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(RegExp('^Dose times on the day dial')),
      ),
      matchesSemantics(
        label: 'Dose times on the day dial: 09:10, Morning',
        value: '09:10',
        increasedValue: '09:25',
        decreasedValue: '08:55',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('display-only offers no steps and no drag', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        const Center(child: DoseDial(times: [TimeOfDay(hour: 9, minute: 0)])),
      ),
    );
    final node = find.bySemanticsLabel(RegExp('^Dose times on the day dial'));
    final data = tester.getSemantics(node).getSemanticsData();
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    expect(
      find.descendant(
        of: find.byType(DoseDial),
        matching: find.byType(RawGestureDetector),
      ),
      findsNothing,
    );
    handle.dispose();
  });

  testWidgets('at large text the words move beside the ring', (tester) async {
    await tester.pumpWidget(
      app(
        const Center(child: DoseDial(times: [TimeOfDay(hour: 9, minute: 0)])),
      ),
    );
    final ring = tester.getRect(find.byKey(const ValueKey('dose-dial')));
    expect(ring.contains(tester.getCenter(find.text('9:00 AM'))), isTrue);

    await tester.pumpWidget(
      app(
        const Center(child: DoseDial(times: [TimeOfDay(hour: 9, minute: 0)])),
        textScale: 2,
      ),
    );
    final big = tester.getRect(find.byKey(const ValueKey('dose-dial')));
    expect(big.width, closeTo(DoseDial.diameter, .01));
    expect(big.height, closeTo(DoseDial.diameter, .01));
    expect(tester.getRect(find.text('9:00 AM')).left, greaterThan(big.right));
    expect(tester.takeException(), isNull);
  });
}
