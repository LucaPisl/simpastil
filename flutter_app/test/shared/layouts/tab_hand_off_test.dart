import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/layouts/tab_hand_off.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';

/// Today's sky as the shell sees it: an arc, or none when it is folded.
class _Sky extends HorizonMarkLocator {
  _Sky(this.shown);
  final HorizonArc? shown;
  @override
  HorizonArc? arc() => shown;
}

final _arc = HorizonArc(
  points: [
    for (var i = 0; i <= 8; i++)
      Offset(20 + i * 45.0, 120 - 40 * (1 - ((i - 4) / 4) * ((i - 4) / 4))),
  ],
  line: Colors.indigo,
  now: .5,
  sun: const Offset(200, 60),
  sunColor: Colors.amber,
);

HandOffLineLocator _lineAt(double y, {bool shown = true}) =>
    HandOffLineLocator()..attach(
      () => shown
          ? HandOffLine(
              at: (minute) => Offset(20 + minute / 1440 * 360, y),
              color: Colors.grey,
              pin: Colors.purple,
              now: 720,
            )
          : null,
    );

Widget _shell(
  int index, {
  required HorizonMarkLocator sky,
  required HandOffLineLocator line,
  bool quiet = false,
}) => ProviderScope(
  overrides: [
    todaySkyLocatorProvider.overrideWithValue(sky),
    historyLineLocatorProvider.overrideWithValue(line),
  ],
  child: MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: quiet),
      child: TabHandOff(
        index: index,
        child: SizedBox.expand(key: ValueKey('tab-$index')),
      ),
    ),
  ),
);

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(find.byType(FadeTransition).last)
    .opacity
    .value;

final _overlay = find.byKey(const ValueKey('tab-hand-off'));

void main() {
  testWidgets('Today to History lays the arc onto the line, then rests', (
    tester,
  ) async {
    final line = _lineAt(300);
    addTearDown(line.dispose);
    await tester.pumpWidget(_shell(0, sky: _Sky(_arc), line: line));
    await tester.pumpWidget(_shell(2, sky: _Sky(_arc), line: line));
    // The real line is veiled from the first frame, before the flight starts.
    expect(line.veil.value, 1);
    await tester.pump();
    expect(_overlay, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(line.veil.value, 1);
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 220));
    // The drawn line fades as the real one shows through.
    expect(line.veil.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(line.veil.value, 0);
    expect(_overlay, findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the drawn line starts on the arc and ends on the line', (
    tester,
  ) async {
    final flight = AnimationController(vsync: const TestVSync());
    addTearDown(flight.dispose);
    final line = _lineAt(300);
    addTearDown(line.dispose);
    final painter = HandOffPainter(
      flight: flight,
      arc: _arc,
      line: line.line()!,
      origin: Offset.zero,
    );
    final start = _Recorder();
    painter.paint(start, const Size(400, 400));
    expect(start.path!.getBounds().top, lessThan(100));
    expect(start.circles.last.$1, _arc.sun);
    flight.value = .69;
    final late = _Recorder();
    painter.paint(late, const Size(400, 400));
    // Nearly flat on the line at y 300 by the time it starts to fade.
    final bounds = late.path!.getBounds();
    expect(bounds.top, greaterThan(270));
    // The sun has become the pin's head over "now".
    expect(late.circles.last.$1.dx, closeTo(200, 1));
    expect(late.circles.last.$2, closeTo(2.6, .3));
    flight.value = 1;
    final end = _Recorder();
    painter.paint(end, const Size(400, 400));
    expect(end.path, isNull);
  });

  testWidgets('other tabs only fade in', (tester) async {
    final line = _lineAt(300);
    addTearDown(line.dispose);
    await tester.pumpWidget(_shell(0, sky: _Sky(_arc), line: line));
    await tester.pumpWidget(_shell(1, sky: _Sky(_arc), line: line));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_opacity(tester), inExclusiveRange(0, 1));
    expect(_overlay, findsNothing);
    expect(line.veil.value, 0);
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
  });

  testWidgets('a folded sky or a missing line leaves just the fade', (
    tester,
  ) async {
    final line = _lineAt(300);
    addTearDown(line.dispose);
    await tester.pumpWidget(_shell(0, sky: _Sky(null), line: line));
    await tester.pumpWidget(_shell(2, sky: _Sky(null), line: line));
    expect(line.veil.value, 0);
    await tester.pump();
    expect(_overlay, findsNothing);

    await tester.pumpAndSettle();
    final gone = _lineAt(300, shown: false);
    addTearDown(gone.dispose);
    // A fresh shell, so it reads the new locators.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_shell(0, sky: _Sky(_arc), line: gone));
    await tester.pumpWidget(_shell(2, sky: _Sky(_arc), line: gone));
    await tester.pump();
    expect(_overlay, findsNothing);
    // Never left veiled.
    expect(gone.veil.value, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('quiet mode changes tab at once', (tester) async {
    final line = _lineAt(300);
    addTearDown(line.dispose);
    await tester.pumpWidget(
      _shell(0, sky: _Sky(_arc), line: line, quiet: true),
    );
    await tester.pumpWidget(
      _shell(2, sky: _Sky(_arc), line: line, quiet: true),
    );
    await tester.pump();
    expect(_overlay, findsNothing);
    expect(_opacity(tester), 1);
    expect(line.veil.value, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}

/// Records the last path and every circle a painter draws.
class _Recorder implements Canvas {
  Path? path;
  final circles = <(Offset, double)>[];

  @override
  void drawPath(Path p, Paint paint) => path = p;

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((c, radius));

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
