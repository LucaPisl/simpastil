import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/layouts/focus_shell.dart';

Widget _host(
  int index, {
  bool quiet = false,
  Brightness b = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: b),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: quiet),
    child: Scaffold(
      body: SizedBox(
        width: 400,
        height: 70,
        child: NavCapsule(index: index, count: 4),
      ),
    ),
  ),
);

Rect _rect(WidgetTester t) => t.getRect(
  find.descendant(
    of: find.byType(NavCapsule),
    matching: find.byType(DecoratedBox),
  ),
);

void main() {
  testWidgets('starts centred on the selected destination', (t) async {
    await t.pumpWidget(_host(0));
    expect(_rect(t).center.dx, closeTo(50, .5));
  });

  testWidgets('slides and stretches, then settles', (t) async {
    await t.pumpWidget(_host(0));
    await t.pumpWidget(_host(3));
    await t.pump(const Duration(milliseconds: 60));
    final mid = _rect(t);
    expect(mid.width, greaterThan(64));
    expect(mid.center.dx, greaterThan(50));
    await t.pumpAndSettle();
    final end = _rect(t);
    expect(end.width, closeTo(64, .5));
    expect(end.center.dx, closeTo(350, .5));
  });

  testWidgets('quiet mode jumps instantly', (t) async {
    await t.pumpWidget(_host(0, quiet: true));
    await t.pumpWidget(_host(2, quiet: true));
    await t.pump();
    expect(_rect(t).center.dx, closeTo(250, .5));
    expect(t.hasRunningAnimations, isFalse);
  });

  testWidgets('is invisible to semantics and works in dark mode', (t) async {
    await t.pumpWidget(_host(1, b: Brightness.dark));
    expect(
      find.descendant(
        of: find.byType(NavCapsule),
        matching: find.byType(ExcludeSemantics),
      ),
      findsWidgets,
    );
  });
}
