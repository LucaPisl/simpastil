import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/motion/ambient_motion.dart';
import 'package:simpastil/shared/motion/app_motion.dart';
import 'package:simpastil/shared/motion/pressable.dart';
import 'package:simpastil/shared/motion/staggered_entrance.dart';

Widget _app(Widget child, {bool quiet = false, bool accessible = false}) =>
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: quiet,
            accessibleNavigation: accessible,
          ),
          child: Scaffold(body: child),
        ),
      ),
    );

double _scaleOf(WidgetTester tester, Finder child) {
  final transform = tester.widget<Transform>(
    find
        .ancestor(
          of: child,
          matching: find.descendant(
            of: find.byType(Pressable),
            matching: find.byType(Transform),
          ),
        )
        .first,
  );
  return transform.transform.storage[0];
}

double _opacityOf(WidgetTester tester, Finder child) => tester
    .widget<Opacity>(
      find.ancestor(of: child, matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  group('AppMotion', () {
    testWidgets('quiet follows reduced motion, not accessible navigation', (
      tester,
    ) async {
      late bool normal, reduced, accessible, bare;
      await tester.pumpWidget(
        _app(Builder(builder: (c) => Text('${normal = AppMotion.quiet(c)}'))),
      );
      await tester.pumpWidget(
        _app(
          Builder(builder: (c) => Text('${reduced = AppMotion.quiet(c)}')),
          quiet: true,
        ),
      );
      await tester.pumpWidget(
        _app(
          Builder(builder: (c) => Text('${accessible = AppMotion.quiet(c)}')),
          accessible: true,
        ),
      );
      await tester.pumpWidget(
        Builder(
          builder: (c) => Text(
            '${bare = AppMotion.quiet(c)}',
            textDirection: TextDirection.ltr,
          ),
        ),
      );
      expect([normal, reduced, accessible, bare], [false, true, false, false]);
    });

    test('tokens and spring', () {
      expect(AppMotion.micro, const Duration(milliseconds: 120));
      expect(AppMotion.standard, const Duration(milliseconds: 240));
      expect(AppMotion.emphasis, const Duration(milliseconds: 320));
      expect(AppMotion.ambient, const Duration(milliseconds: 900));
      expect(AppMotion.spring.stiffness, 420);
      expect(AppMotion.spring.damping, 32);
    });
  });

  group('Pressable', () {
    testWidgets('springs down while held and back on release, then taps', (
      tester,
    ) async {
      var taps = 0;
      const label = Text('Card');
      await tester.pumpWidget(
        _app(
          Center(
            child: Pressable(
              onTap: () => taps++,
              child: const SizedBox(width: 200, height: 80, child: label),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Card')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_scaleOf(tester, find.text('Card')), closeTo(.975, .003));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester, find.text('Card')), closeTo(1, .001));
      expect(taps, 1);
    });

    testWidgets('quick tap still plays a visible press pulse', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: Pressable(
              onTap: () => taps++,
              child: const SizedBox(width: 200, height: 80, child: Text('Q')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Q'));
      var minScale = 1.0;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final s = _scaleOf(tester, find.text('Q'));
        if (s < minScale) minScale = s;
      }
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(minScale, lessThan(.985));
      expect(_scaleOf(tester, find.text('Q')), closeTo(1, .001));
    });

    testWidgets('a horizontal drag in a ListView cancels the press', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 120,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < 6; i++)
                  Pressable(
                    onTap: () => taps++,
                    child: SizedBox(width: 160, child: Text('Item $i')),
                  ),
              ],
            ),
          ),
        ),
      );
      final item = find.text('Item 1');
      final gesture = await tester.startGesture(tester.getCenter(item));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_scaleOf(tester, item), lessThan(.99));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(_scaleOf(tester, item), closeTo(1, .001));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(tester.getTopLeft(item).dx, lessThan(160));
    });

    testWidgets('without onTap it never steals the tap from an ancestor', (
      tester,
    ) async {
      var outer = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: GestureDetector(
              onTap: () => outer++,
              child: const Pressable(
                child: SizedBox(width: 200, height: 80, child: Text('Row')),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Row')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_scaleOf(tester, find.text('Row')), lessThan(.99));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(outer, 1);
      expect(_scaleOf(tester, find.text('Row')), closeTo(1, .001));
    });

    testWidgets('quiet mode drops scale but still taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: Pressable(
              onTap: () => taps++,
              child: const SizedBox(width: 200, height: 80, child: Text('Q')),
            ),
          ),
          quiet: true,
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Q')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.ancestor(
          of: find.text('Q'),
          matching: find.byWidgetPredicate(
            (w) => w is Transform && w.transform.storage[0] != 1,
          ),
        ),
        findsNothing,
      );
      await gesture.up();
      await tester.pump();
      expect(taps, 1);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('StaggeredEntrance', () {
    setUp(StaggeredEntrance.resetForTesting);

    Widget list(Object identity, int count) => ListView(
      children: [
        for (var i = 0; i < count; i++)
          StaggeredEntrance(
            index: i,
            identity: identity,
            child: SizedBox(height: 20, child: Text('Row $i')),
          ),
      ],
    );

    testWidgets('staggers by index and caps the delay at 8 slots', (
      tester,
    ) async {
      await tester.pumpWidget(_app(list('pills', 12)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacityOf(tester, find.text('Row 0')), greaterThan(0));
      expect(_opacityOf(tester, find.text('Row 5')), 0);
      // The capped slot starts at 8 * 40 ms; by then index 11 equals index 8.
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _opacityOf(tester, find.text('Row 11')),
        _opacityOf(tester, find.text('Row 8')),
      );
      await tester.pump(StaggeredEntrance.window);
      for (final i in [0, 7, 8, 11]) {
        expect(_opacityOf(tester, find.text('Row $i')), 1);
      }
    });

    testWidgets('plays once per identity and never replays on remount', (
      tester,
    ) async {
      await tester.pumpWidget(_app(list('pills', 3)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pumpWidget(_app(list('pills', 3)));
      expect(_opacityOf(tester, find.text('Row 2')), 1);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(_app(list('profiles', 3)));
      await tester.pump(const Duration(milliseconds: 10));
      expect(_opacityOf(tester, find.text('Row 2')), 0);
      await tester.pumpAndSettle();

      // Switching identity again mid-entrance restarts cleanly.
      await tester.pumpWidget(_app(list('history', 3)));
      await tester.pump(const Duration(milliseconds: 10));
      expect(_opacityOf(tester, find.text('Row 2')), 0);
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, find.text('Row 2')), 1);
    });

    testWidgets('quiet shows the final frame at once', (tester) async {
      await tester.pumpWidget(_app(list('quiet', 4), quiet: true));
      expect(_opacityOf(tester, find.text('Row 3')), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('accessible navigation alone still plays the entrance', (
      tester,
    ) async {
      await tester.pumpWidget(_app(list('a11y', 4), accessible: true));
      await tester.pump(const Duration(milliseconds: 10));
      expect(_opacityOf(tester, find.text('Row 3')), lessThan(1));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, find.text('Row 3')), 1);
    });
  });

  group('AmbientMotion', () {
    late bool seen;
    Widget probe() => Builder(
      builder: (c) {
        seen = AmbientMotion.of(c);
        return const SizedBox();
      },
    );

    testWidgets('defaults to off without an ancestor', (tester) async {
      await tester.pumpWidget(_app(probe()));
      expect(seen, isFalse);
    });

    testWidgets('on when enabled, off when quiet, muted or paused', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(AmbientMotion(enabled: true, child: probe())),
      );
      expect(seen, isTrue);

      await tester.pumpWidget(
        _app(AmbientMotion(enabled: true, child: probe()), quiet: true),
      );
      expect(seen, isFalse);

      await tester.pumpWidget(
        _app(
          AmbientMotion(
            enabled: true,
            child: TickerMode(enabled: false, child: probe()),
          ),
        ),
      );
      expect(seen, isFalse);

      await tester.pumpWidget(
        _app(AmbientMotion(enabled: true, child: probe())),
      );
      expect(seen, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(seen, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(seen, isTrue);

      await tester.pumpWidget(
        _app(AmbientMotion(enabled: false, child: probe())),
      );
      expect(seen, isFalse);
    });
  });
}
