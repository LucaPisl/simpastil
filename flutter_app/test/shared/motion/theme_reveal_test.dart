import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/motion/theme_reveal.dart';

class _Host extends StatefulWidget {
  const _Host({super.key, required this.quiet, required this.onTap});
  final bool quiet;
  final VoidCallback onTap;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool dark = false;

  void toggle() => setState(() => dark = !dark);

  @override
  Widget build(BuildContext context) => ThemeReveal(
    child: MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      themeAnimationStyle: AnimationStyle.noAnimation,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: widget.quiet),
        child: Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('apply'),
              onPressed: widget.onTap,
              child: const Text('Apply'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late GlobalKey<_HostState> host;
  var taps = 0;

  Future<void> mount(WidgetTester tester, {bool quiet = false}) async {
    host = GlobalKey<_HostState>();
    taps = 0;
    await tester.pumpWidget(
      _Host(key: host, quiet: quiet, onTap: () => taps++),
    );
  }

  BuildContext button(WidgetTester tester) =>
      tester.element(find.byKey(const ValueKey('apply')));

  Brightness brightness(WidgetTester tester) =>
      Theme.of(button(tester)).brightness;

  Future<void> flip() async => host.currentState!.toggle();

  /// Lets the frame be captured: one frame, real time for the engine to
  /// render the picture, then a pump to deliver it.
  Future<void> capture(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  testWidgets('the new look spreads from the control over a picture of the '
      'old one, then lets go', (tester) async {
    await mount(tester);
    final reveal = ThemeReveal.maybeOf(button(tester))!;
    var finished = false;
    reveal
        .reveal(from: button(tester), change: flip)
        .then((_) => finished = true);
    await capture(tester);

    // The change has happened underneath while the old frame still covers.
    expect(brightness(tester), Brightness.dark);
    expect(reveal.revealing, isTrue);
    expect(find.byKey(const ValueKey('theme-reveal')), findsOneWidget);
    final painter =
        tester
                .widget<CustomPaint>(find.byKey(const ValueKey('theme-reveal')))
                .painter!
            as ThemeRevealPainter;
    expect(
      painter.origin,
      tester.getCenter(find.byKey(const ValueKey('apply'))),
    );

    // The picture never takes a touch meant for the new look.
    await tester.tap(find.byKey(const ValueKey('apply')));
    expect(taps, 1);

    await tester.pump(ThemeReveal.duration ~/ 2);
    expect(painter.spread.value, inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(reveal.revealing, isFalse);
    expect(find.byKey(const ValueKey('theme-reveal')), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet motion changes the look at once, without a picture', (
    tester,
  ) async {
    await mount(tester, quiet: true);
    final reveal = ThemeReveal.maybeOf(button(tester))!;
    await reveal.reveal(from: button(tester), change: flip);
    expect(reveal.revealing, isFalse);
    await tester.pump();
    expect(brightness(tester), Brightness.dark);
    expect(find.byKey(const ValueKey('theme-reveal')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-reveal')), findsNothing);
  });

  testWidgets('a change asked for during a reveal applies straight away', (
    tester,
  ) async {
    await mount(tester);
    final reveal = ThemeReveal.maybeOf(button(tester))!;
    reveal.reveal(from: button(tester), change: flip);
    await capture(tester);
    expect(reveal.revealing, isTrue);

    await reveal.reveal(from: button(tester), change: flip);
    await tester.pump();
    expect(brightness(tester), Brightness.light);
    await tester.pumpAndSettle();
    expect(reveal.revealing, isFalse);
  });

  test('the circle grows until it reaches the farthest corner', () {
    const size = Size(400, 800);
    expect(
      ThemeRevealPainter.reach(size, const Offset(100, 700)),
      moreOrLessEquals(const Offset(300, 700).distance),
    );
    expect(
      ThemeRevealPainter.reach(size, size.center(Offset.zero)),
      moreOrLessEquals(const Offset(200, 400).distance),
    );
  });
}
