import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/features/pills/presentation/medication_plate.dart';

import '../../../shared/scene/scene_test_support.dart';

const _tint = Color(0xFF7C9885);

Widget _app() => MaterialApp(
  theme: themeFor(Brightness.light),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: ListView(
                  children: const [
                    MedicationPlate(
                      id: 'm1',
                      name: 'Medication',
                      tint: _tint,
                      shape: MedicationShape.round,
                      children: [Text('Placebotin')],
                    ),
                  ],
                ),
              ),
            ),
          ),
          child: const SizedBox(
            width: 160,
            height: 168,
            child: Stack(
              children: [
                Positioned.fill(
                  child: MedicationCardSurface(
                    id: 'm1',
                    tint: _tint,
                    child: Text('card words'),
                  ),
                ),
                Center(
                  key: Key('card'),
                  child: MedicationMarkHero(
                    id: 'm1',
                    name: 'Medication',
                    color: _tint,
                    shape: MedicationShape.round,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

Size _markSize(WidgetTester tester) =>
    tester.getSize(find.byType(MedicationMark).last);

void main() {
  testWidgets('the card surface and mark fly into the plate and back', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    expect(_markSize(tester), const Size.square(58));
    await tester.tap(find.byKey(const Key('card')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // Mid-flight the mark is turning on its way up.
    final turning = find.descendant(
      of: find.byType(Overlay),
      matching: find.byWidgetPredicate(
        (w) => w is Transform && w.transform.getRotation()[1].abs() > .05,
      ),
    );
    expect(turning, findsWidgets);
    await tester.pumpAndSettle();
    expect(find.text('Placebotin'), findsOneWidget);
    expect(_markSize(tester), const Size.square(104));
    Navigator.of(tester.element(find.text('Placebotin'))).pop();
    await tester.pumpAndSettle();
    expect(_markSize(tester), const Size.square(58));
  });

  testWidgets('the plate mark follows a drag on a leash and springs home', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(Brightness.light),
        home: Scaffold(
          body: ListView(
            children: const [
              MedicationPlate(
                id: 'm1',
                name: 'Medication',
                tint: _tint,
                shape: MedicationShape.capsule,
                children: [Text('Dummydrin')],
              ),
              SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    final home = tester.getCenter(find.byType(MedicationMark));
    final gesture = await tester.startGesture(home);
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    final held = tester.getCenter(find.byType(MedicationMark));
    // The mark moved with the finger, not the list, and the leash held it.
    expect(home.dy - held.dy, inInclusiveRange(20, 40));
    expect(tester.getTopLeft(find.text('Dummydrin')).dy, greaterThan(100));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getCenter(find.byType(MedicationMark)), isNot(held));
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(find.byType(MedicationMark)) - home).distance,
      lessThan(.5),
    );
  });

  testWidgets('a tap squashes the mark and it settles back', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(Brightness.dark),
        home: const Scaffold(
          body: MedicationPlate(
            id: 'm1',
            name: 'Medication',
            tint: _tint,
            shape: MedicationShape.drop,
            children: [],
          ),
        ),
      ),
    );
    final rest = tester.getRect(find.byType(MedicationMark));
    await tester.tap(find.byType(MedicationMark));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.getRect(find.byType(MedicationMark)), isNot(rest));
    await tester.pumpAndSettle();
    final settled = tester.getRect(find.byType(MedicationMark));
    expect((settled.center - rest.center).distance, lessThan(.5));
    expect((settled.width - rest.width).abs(), lessThan(.5));
  });
}
