import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/layouts/window_size.dart';

void main() {
  group('WindowClass', () {
    test('splits at 600 and 840 dp', () {
      expect(WindowClass.forWidth(0), WindowClass.compact);
      expect(WindowClass.forWidth(320), WindowClass.compact);
      expect(WindowClass.forWidth(412), WindowClass.compact);
      expect(WindowClass.forWidth(599.9), WindowClass.compact);
      expect(WindowClass.forWidth(600), WindowClass.medium);
      expect(WindowClass.forWidth(753), WindowClass.medium);
      expect(WindowClass.forWidth(839.9), WindowClass.medium);
      expect(WindowClass.forWidth(840), WindowClass.expanded);
      expect(WindowClass.forWidth(1205), WindowClass.expanded);
      expect(WindowClass.forWidth(2560), WindowClass.expanded);
    });

    test('only phones keep the bottom bar', () {
      expect(WindowClass.compact.showsRail, isFalse);
      expect(WindowClass.medium.showsRail, isTrue);
      expect(WindowClass.expanded.showsRail, isTrue);
      expect(WindowClass.compact.railWidth, 0);
      expect(WindowClass.medium.railWidth, WindowClass.expanded.railWidth);
      expect(WindowClass.medium.railWidth, greaterThan(0));
    });

    test('only expanded windows get two panes', () {
      expect(WindowClass.compact.isExpanded, isFalse);
      expect(WindowClass.medium.isExpanded, isFalse);
      expect(WindowClass.expanded.isExpanded, isTrue);
    });

    test('one content width per class, phones fill their width', () {
      expect(WindowClass.compact.contentWidth, double.infinity);
      expect(WindowClass.medium.contentWidth, 640);
      expect(WindowClass.expanded.contentWidth, 720);
    });

    testWidgets('of() follows the window width, not the widget width', (
      tester,
    ) async {
      WindowClass? seen;
      Future<void> mount(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              // A narrow box in a wide window is still an expanded window.
              child: SizedBox(
                width: 200,
                child: Builder(
                  builder: (context) {
                    seen = WindowClass.of(context);
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
      }

      await mount(const Size(1205, 753));
      expect(seen, WindowClass.expanded);
      await mount(const Size(753, 1205));
      expect(seen, WindowClass.medium);
      await mount(const Size(390, 844));
      expect(seen, WindowClass.compact);
    });
  });

  group('contentGutter', () {
    test('centres a column and never goes negative', () {
      expect(contentGutter(1000, 640), 180);
      expect(contentGutter(640, 640), 0);
      expect(contentGutter(500, 640), 0);
    });

    test('is zero for an unbounded column or pane', () {
      expect(contentGutter(1000, double.infinity), 0);
      expect(contentGutter(double.infinity, 640), 0);
    });
  });

  group('ContentListView', () {
    Future<void> mount(
      WidgetTester tester,
      Size size, {
      double? maxWidth,
      EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 16),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentListView(
              maxWidth: maxWidth,
              padding: padding,
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(
                    key: ValueKey('row-$i'),
                    height: 60,
                    child: const ColoredBox(color: Colors.blue),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('a phone fills its width inside the page padding', (
      tester,
    ) async {
      await mount(tester, const Size(390, 844));
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.left, 16);
      expect(row.right, 390 - 16);
    });

    testWidgets('a medium window keeps a centred 640 dp column', (
      tester,
    ) async {
      await mount(tester, const Size(753, 1205), padding: EdgeInsets.zero);
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.width, 640);
      expect(row.center.dx, 753 / 2);
    });

    testWidgets('an expanded window keeps a centred 720 dp column', (
      tester,
    ) async {
      await mount(tester, const Size(1205, 753), padding: EdgeInsets.zero);
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.width, 720);
      expect(row.center.dx, 1205 / 2);
    });

    testWidgets('the page padding sits inside the column', (tester) async {
      await mount(tester, const Size(1205, 753));
      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.width, 720 - 32);
    });

    testWidgets('the scroll view spans the pane, so the margins scroll', (
      tester,
    ) async {
      await mount(tester, const Size(1205, 753));
      final list = tester.getRect(find.byType(ListView));
      expect(list.width, 1205);
      // Dragging in the empty left margin scrolls the page.
      await tester.dragFrom(const Offset(40, 400), const Offset(0, -400));
      await tester.pump();
      expect(find.byKey(const ValueKey('row-0')), findsNothing);
      expect(find.byKey(const ValueKey('row-8')), findsOneWidget);
    });

    testWidgets('an explicit maxWidth overrides the class token', (
      tester,
    ) async {
      await mount(
        tester,
        const Size(1205, 753),
        maxWidth: 400,
        padding: EdgeInsets.zero,
      );
      expect(tester.getRect(find.byKey(const ValueKey('row-0'))).width, 400);
    });
  });

  group('ContentScrollView', () {
    testWidgets('centres its child and scrolls from the margins', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1205, 753);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ContentScrollView(
              child: SizedBox(
                key: ValueKey('child'),
                width: double.infinity,
                height: 2000,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      );
      final child = tester.getRect(find.byKey(const ValueKey('child')));
      expect(child.width, 720);
      expect(child.center.dx, 1205 / 2);
      expect(tester.getRect(find.byType(SingleChildScrollView)).width, 1205);
    });
  });

  group('ContentFrame', () {
    testWidgets('lines a bar up with the content column', (tester) async {
      tester.view.physicalSize = const Size(1205, 753);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: SizedBox.expand()),
                ContentFrame(
                  child: SizedBox(
                    key: ValueKey('bar'),
                    width: double.infinity,
                    height: 56,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final bar = tester.getRect(find.byKey(const ValueKey('bar')));
      expect(bar.width, 720);
      expect(bar.center.dx, 1205 / 2);
      expect(bar.height, 56);
    });

    testWidgets('does not narrow a phone', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: SizedBox.expand()),
                ContentFrame(
                  child: SizedBox(
                    key: ValueKey('bar'),
                    width: double.infinity,
                    height: 56,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.getRect(find.byKey(const ValueKey('bar'))).width, 390);
    });
  });

  group('TwoPane', () {
    Future<void> mount(WidgetTester tester, {double? endWidth}) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 900,
                height: 400,
                child: TwoPane(
                  endWidth: endWidth,
                  start: const SizedBox(key: ValueKey('start')),
                  end: const SizedBox(key: ValueKey('end')),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shares the width equally around the gap', (tester) async {
      await mount(tester);
      final start = tester.getRect(find.byKey(const ValueKey('start')));
      final end = tester.getRect(find.byKey(const ValueKey('end')));
      expect(start.width, end.width);
      expect(end.left - start.right, TwoPane.defaultGap);
      expect(start.height, 400);
      expect(end.height, 400);
    });

    testWidgets('a fixed end pane leaves the rest to the start pane', (
      tester,
    ) async {
      await mount(tester, endWidth: 320);
      final start = tester.getRect(find.byKey(const ValueKey('start')));
      final end = tester.getRect(find.byKey(const ValueKey('end')));
      expect(end.width, 320);
      expect(start.width, 900 - 320 - TwoPane.defaultGap);
    });
  });
}
