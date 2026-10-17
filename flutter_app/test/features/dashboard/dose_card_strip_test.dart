import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/dose_card_strip.dart';

void main() {
  for (final rtl in [false, true]) {
    testWidgets('native card travel, endpoints and action guard rtl=$rtl', (
      tester,
    ) async {
      String selected = 'a';
      var actions = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 400,
                      child: DoseCardStrip(
                        ids: const ['a', 'b', 'c'],
                        labels: const ['A', 'B', 'C'],
                        selectedId: selected,
                        onSelected: (id) => setState(() => selected = id),
                        cardBuilder: (index, active) => SizedBox(
                          height: 220,
                          child: FilledButton(
                            key: ValueKey('take-$index'),
                            onPressed: active ? () => actions++ : null,
                            child: Text('Dose $index'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('focus-card-a'));
      final last = find.byKey(const ValueKey('focus-card-c'));
      final anchor = rtl
          ? tester.getRect(first).right
          : tester.getRect(first).left;
      final direction = rtl ? 1.0 : -1.0;
      final gesture = await tester.startGesture(tester.getCenter(first));
      await gesture.moveBy(Offset(direction * 20, 0));
      await tester.pump();
      final origin = tester.getTopLeft(first).dx;
      await gesture.moveBy(Offset(direction * 180, 0));
      await tester.pump();
      expect(tester.getTopLeft(first).dx - origin, closeTo(direction * 180, 1));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('take-0')))
            .onPressed,
        isNull,
      );
      await gesture.moveBy(Offset(direction * 60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(actions, 0);
      rebuild(() => selected = 'c');
      await tester.pumpAndSettle();
      expect(
        rtl ? tester.getRect(last).right : tester.getRect(last).left,
        closeTo(anchor, .5),
      );
      rebuild(() => selected = 'a');
      await tester.pumpAndSettle();
      expect(
        rtl ? tester.getRect(first).right : tester.getRect(first).left,
        closeTo(anchor, .5),
      );
      expect(actions, 0);
      // Cancel a button animation at its old anchor before its first tick.
      rebuild(() => selected = 'b');
      await tester.pump();
      final hold = await tester.startGesture(tester.getCenter(first));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('take-1')))
            .onPressed,
        isNull,
        reason:
            'an offscreen action must stay disabled while animation is held',
      );
      await hold.up();
      await tester.pumpAndSettle();
      expect(selected, 'a');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('take-0')))
            .onPressed,
        isNotNull,
      );
    });
  }

  testWidgets(
    'identity survives reorder, insertion, resize and reduced motion',
    (tester) async {
      var ids = ['a', 'b', 'c'];
      var selected = 'b';
      var width = 400.0;
      final callbacks = <String>[];
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: DoseCardStrip(
                        ids: ids,
                        labels: ids,
                        selectedId: selected,
                        onSelected: (id) {
                          callbacks.add(id);
                          setState(() => selected = id);
                        },
                        cardBuilder: (index, active) =>
                            SizedBox(height: 200, child: Text(ids[index])),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('focus-card-b'));
      final anchor = tester.getTopLeft(card).dx;
      rebuild(() {
        ids = ['c', 'x', 'a', 'b'];
        width = 340;
      });
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(tester.getTopLeft(card).dx, closeTo(anchor, .5));
      expect(callbacks, isEmpty);
      rebuild(() {
        ids = ['b', 'x'];
        width = 500;
      });
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(card).dx, closeTo(anchor, .5));
      expect(callbacks, isEmpty);
      rebuild(() => selected = 'x');
      await tester.pump();
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('focus-card-x'))).dx,
        closeTo(anchor, .5),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'vertical drag over cards scrolls the page without changing selection',
    (tester) async {
      var selected = 'a';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                DoseCardStrip(
                  ids: const ['a', 'b'],
                  labels: const ['A', 'B'],
                  selectedId: selected,
                  onSelected: (id) => selected = id,
                  cardBuilder: (index, active) => const SizedBox(
                    height: 250,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('focus-card-a'));
      await tester.drag(card, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(card).dy, lessThan(-150));
      expect(selected, 'a');
    },
  );
}
