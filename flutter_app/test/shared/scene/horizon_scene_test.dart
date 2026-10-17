import 'dart:ui';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/horizon_model.dart';
import 'package:simpastil/shared/scene/horizon_painter.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';

import 'scene_test_support.dart';

Widget _app(Widget child, {bool disableAnimations = false}) => MaterialApp(
  theme: themeFor(Brightness.light),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('idle scene paints zero frames after entry has finished', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    await tester.pumpWidget(_app(sceneOf(model)));
    await tester.pumpAndSettle();
    final before = HorizonPainter.debugPaintCount;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(HorizonPainter.debugPaintCount, before);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet mode shows the final frame with no running animation', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    await tester.pumpWidget(_app(sceneOf(model), disableAnimations: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a held entry waits, then rises once it is let go', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final hold = ValueNotifier(true);
    addTearDown(hold.dispose);
    double entry() => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(HorizonScene),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((c) => c.painter)
        .whereType<HorizonPainter>()
        .first
        .entry!
        .value;
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            entryHold: hold,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(entry(), 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    hold.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(entry(), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(entry(), 1);
    // Holding again later changes nothing.
    hold.value = true;
    await tester.pump();
    expect(entry(), 1);
  });

  testWidgets('quiet mode ignores the hold', (tester) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final hold = ValueNotifier(true);
    addTearDown(hold.dispose);
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            entryHold: hold,
          ),
        ),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(HorizonScene),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((c) => c.painter)
        .whereType<HorizonPainter>()
        .first;
    expect(painter.entry!.value, 1);
  });

  testWidgets('the locator reads the day path and sun where they are drawn', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final locator = HorizonMarkLocator();
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            markLocator: locator,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    final arc = locator.arc()!;
    expect(arc.points.first, origin + model.pathAt(0));
    expect(arc.at(.5), origin + model.pathAt(.5));
    expect(arc.sun, origin + model.sun!);
    expect(arc.now, model.dayProgress);
    await tester.pumpWidget(_app(const SizedBox()));
    expect(locator.arc(), isNull);
  });

  testWidgets('tap on a mark reports its id, empty sky reports nothing', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final tapped = <String>[];
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            onMarkTapped: tapped.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    final mark = model.marks.firstWhere((m) => m.id == 'e');
    await tester.tapAt(origin + mark.rect.center + const Offset(4, 3));
    await tester.tapAt(origin + const Offset(200, 20));
    expect(tapped, ['e']);
  });

  testWidgets('scrubbing reports each dose once as the finger crosses it', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final scrubbed = <String>[];
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            onScrub: scrubbed.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    final gesture = await tester.startGesture(origin + const Offset(30, 60));
    for (var x = 30.0; x < 380; x += 10) {
      await gesture.moveTo(origin + Offset(x, 60));
    }
    await gesture.up();
    expect(scrubbed.toSet().length, scrubbed.length);
    expect(scrubbed.first, anyOf('a', 'b', 'c', 'd'));
    expect(scrubbed.last, 'h');
  });

  testWidgets('tapping the sun says what is next; marks win the tap', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final tapped = <String>[];
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            onMarkTapped: tapped.add,
            sunLabel: 'Next: 13:00 · Mihai · Metformin',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    final bubble = find.text('Next: 13:00 · Mihai · Metformin');
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: bubble, matching: find.byType(AnimatedOpacity)),
        )
        .opacity;
    expect(opacity(), 0);

    final mark = model.marks.firstWhere((m) => m.id == 'e');
    await tester.tapAt(origin + mark.rect.center);
    await tester.pump();
    expect(tapped, ['e']);
    expect(opacity(), 0);

    // A finger a little off the disc still counts: the target is 56 dp.
    await tester.tapAt(origin + model.sun! + const Offset(18, 12));
    await tester.pump();
    expect(opacity(), 1);
    expect(tapped, ['e']);

    await tester.pump(const Duration(seconds: 4));
    expect(opacity(), 0);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the sun bubble goes with a folding header', (tester) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final collapse = ValueNotifier<double>(0);
    addTearDown(collapse.dispose);
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            sunLabel: 'Next',
            collapse: collapse,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    await tester.tapAt(origin + model.sun!);
    await tester.pump();
    expect(find.text('Next'), findsOneWidget);
    collapse.value = .8;
    await tester.pump();
    await tester.pump();
    expect(find.text('Next'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('long-pressing the sun scrubs a ghost; the real sun stays', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final followed = <String>[];
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            onSunScrub: followed.add,
            sunLabel: 'Next',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    final gesture = await tester.startGesture(origin + model.sun!);
    await tester.pump(const Duration(milliseconds: 700));
    for (var x = model.sun!.dx; x < model.size.width * .88; x += 8) {
      await gesture.moveTo(origin + Offset(x, model.sun!.dy));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    // Each dose the ghost passes is followed once, in time order.
    expect(followed.toSet().length, followed.length);
    expect(followed, isNotEmpty);
    // The ghost follows the dose marks under the finger, evening ones too.
    expect(followed.last, 'h');
    expect(tester.binding.hasScheduledFrame, isFalse);

    // A press away from the sun scrubs nothing.
    followed.clear();
    final away = await tester.startGesture(origin + const Offset(40, 140));
    await tester.pump(const Duration(milliseconds: 700));
    await away.moveTo(origin + const Offset(300, 140));
    await away.up();
    await tester.pumpAndSettle();
    expect(followed, isEmpty);
  });

  testWidgets('a held tap on a mark still opens it; sun scrub is separate', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    final tapped = <String>[];
    final followed = <String>[];
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'sky',
            onMarkTapped: tapped.add,
            onSunScrub: followed.add,
            sunLabel: 'Next',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(HorizonScene));
    final mark = model.marks.firstWhere((m) => m.id == 'e');
    final held = await tester.startGesture(origin + mark.rect.center);
    await tester.pump(const Duration(milliseconds: 700));
    await held.up();
    await tester.pumpAndSettle();
    expect(tapped, ['e']);
    expect(followed, isEmpty);
  });

  testWidgets('semantics: one label plus a show-next action', (tester) async {
    final handle = tester.ensureSemantics();
    final model = modelFor(at(12, 0), Brightness.light);
    var shown = 0;
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'Day sky: 2 of 4 recorded',
            showNextLabel: 'Show next dose',
            onShowNext: () => shown++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(
      find.bySemanticsLabel('Day sky: 2 of 4 recorded'),
    );
    expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
    final id = node.getSemanticsData().customSemanticsActionIds!.single;
    tester.binding.platformDispatcher.onSemanticsActionEvent?.call(
      SemanticsActionEvent(
        viewId: tester.view.viewId,
        nodeId: node.id,
        type: SemanticsAction.customAction,
        arguments: id,
      ),
    );
    await tester.pump();
    expect(shown, 1);
    handle.dispose();
  });

  testWidgets('screen readers can have the sun line read out on demand', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final model = modelFor(at(12, 0), Brightness.light);
    final announced = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (message) async {
        announced.add(message);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          ),
    );
    await tester.pumpWidget(
      _app(
        SizedBox.fromSize(
          size: model.size,
          child: HorizonScene(
            model: model,
            semanticsLabel: 'Day sky',
            showNextLabel: 'Show next dose',
            readNextLabel: 'Read what is next',
            onShowNext: () {},
            sunLabel: 'Next: 13:00 · Mihai · Metformin',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.bySemanticsLabel('Day sky'));
    final ids = node.getSemanticsData().customSemanticsActionIds!;
    final labels = [
      for (final id in ids) CustomSemanticsAction.getAction(id)!.label,
    ];
    expect(labels, containsAll(['Show next dose', 'Read what is next']));
    final readId = ids.firstWhere(
      (id) => CustomSemanticsAction.getAction(id)!.label == 'Read what is next',
    );
    tester.binding.platformDispatcher.onSemanticsActionEvent?.call(
      SemanticsActionEvent(
        viewId: tester.view.viewId,
        nodeId: node.id,
        type: SemanticsAction.customAction,
        arguments: readId,
      ),
    );
    await tester.pump();
    expect(
      announced.any(
        (m) => m.toString().contains('Next: 13:00 · Mihai · Metformin'),
      ),
      isTrue,
    );
    await tester.pumpAndSettle(const Duration(seconds: 4));
    handle.dispose();
  });

  testWidgets('celebrate plays once and then goes idle', (tester) async {
    final model = modelFor(at(12, 0), Brightness.light);
    Widget build(String? id) => _app(sceneOf(model, celebrateId: id));
    await tester.pumpWidget(build(null));
    await tester.pumpAndSettle();
    final before = HorizonPainter.debugPaintCount;
    await tester.pumpWidget(build('e'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(HorizonPainter.debugPaintCount, greaterThan(before));
    await tester.pumpAndSettle();
    final settled = HorizonPainter.debugPaintCount;
    await tester.pump(const Duration(seconds: 30));
    expect(HorizonPainter.debugPaintCount, settled);
  });

  group('a dose taken at night', () {
    final doses = [
      for (final d in sampleDoses)
        if (d.id == 'c')
          HorizonDose(
            id: d.id,
            plannedLocalTime: d.plannedLocalTime,
            state: 'taken',
            person: d.person,
          )
        else
          d,
    ];
    final before = modelFor(at(23, 0), Brightness.dark);
    final after = modelFor(at(23, 0), Brightness.dark, doses: doses);
    Set<String> held(WidgetTester tester) => {
      for (final paint in tester.widgetList<CustomPaint>(
        find.byType(CustomPaint),
      ))
        if (paint.painter case final HorizonPainter p) ...p.heldStars,
    };

    testWidgets('keeps its star in the mark until the check lands', (
      tester,
    ) async {
      expect(after.constellation.map((s) => s.id), contains('c'));
      await tester.pumpWidget(_app(sceneOf(before)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(sceneOf(after)));
      await tester.pump();
      expect(held(tester), {'c'});
      await tester.pumpWidget(_app(sceneOf(after, celebrateId: 'c')));
      await tester.pump();
      expect(held(tester), isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('lets the star out by itself when nothing celebrates', (
      tester,
    ) async {
      await tester.pumpWidget(_app(sceneOf(before)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(sceneOf(after)));
      await tester.pump();
      expect(held(tester), {'c'});
      await tester.pump(const Duration(milliseconds: 2500));
      expect(held(tester), isEmpty);
    });
  });

  testWidgets('settled sweep plays once for its token and then goes idle', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    Widget build(String? id) => _app(sceneOf(model, sweepId: id));
    await tester.pumpWidget(build(null));
    await tester.pumpAndSettle();
    final before = HorizonPainter.debugPaintCount;
    await tester.pumpWidget(build('settled'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(HorizonPainter.debugPaintCount, greaterThan(before));
    await tester.pumpAndSettle();
    final done = HorizonPainter.debugPaintCount;
    await tester.pump(const Duration(seconds: 30));
    expect(HorizonPainter.debugPaintCount, done);
    // The same token never replays.
    await tester.pumpWidget(build('settled'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(HorizonPainter.debugPaintCount, done);
  });

  testWidgets('quiet motion: the settled sweep shows only its final frame', (
    tester,
  ) async {
    final model = modelFor(at(12, 0), Brightness.light);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    Widget build(String? id) => _app(sceneOf(model, sweepId: id));
    await tester.pumpWidget(build(null));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build('settled'));
    await tester.pumpAndSettle();
    // The rebuild has painted; no sweep animation follows it.
    final painted = HorizonPainter.debugPaintCount;
    await tester.pump(const Duration(seconds: 5));
    expect(HorizonPainter.debugPaintCount, painted);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('scene clock ticks on the minute and stops when offstage', (
    tester,
  ) async {
    var now = DateTime(2026, 4, 15, 12, 0, 30);
    var builds = 0;
    final shown = <int>[];
    Widget app(bool ticking) => ProviderScope(
      overrides: [sceneClockProvider.overrideWithValue(() => now)],
      child: MaterialApp(
        home: TickerMode(
          enabled: ticking,
          child: SceneClock(
            builder: (context, t) {
              builds++;
              shown.add(t.minute);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(true));
    expect(builds, 1);
    now = DateTime(2026, 4, 15, 12, 1, 0, 100);
    await tester.pump(const Duration(seconds: 31));
    expect(shown.last, 1);
    final count = builds;
    await tester.pumpWidget(app(false));
    final afterToggle = builds;
    now = DateTime(2026, 4, 15, 12, 2, 0, 100);
    await tester.pump(const Duration(minutes: 5));
    expect(builds, afterToggle);
    expect(count, lessThanOrEqualTo(afterToggle));
    unawaited(Future<void>.value());
  });
}
