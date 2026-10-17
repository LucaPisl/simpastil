import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/pills/presentation/stock_capsule.dart';
import 'package:simpastil/l10n/app_localizations.dart';

Widget _host(Widget child, {bool quiet = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: quiet),
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('prints the number and speaks it', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const StockCapsule(stock: 12, threshold: 5)));
    await tester.pumpAndSettle();
    expect(find.text('12 left'), findsOneWidget);
    expect(find.bySemanticsLabel('12 left'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('quiet mode shows the final frame at once', (tester) async {
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 3, threshold: 5), quiet: true),
    );
    expect(find.text('3 left'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  double level(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(StockCapsule),
        matching: find.byType(CustomPaint),
      ),
    );
    // ignore: avoid_dynamic_calls
    return (paint.painter! as dynamic).level as double;
  }

  testWidgets('a change eases once to the new level, never past it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 10, threshold: 5, capacity: 40)),
    );
    await tester.pumpAndSettle();
    expect(level(tester), closeTo(.25, 1e-6));

    await tester.pumpWidget(
      _host(const StockCapsule(stock: 30, threshold: 5, capacity: 40)),
    );
    var previous = level(tester);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      final now = level(tester);
      expect(now, greaterThanOrEqualTo(previous - 1e-9));
      expect(now, lessThanOrEqualTo(.75 + 1e-9));
      previous = now;
    }
    // Once and done: nothing keeps animating after the ease.
    expect(tester.hasRunningAnimations, isFalse);
    expect(level(tester), closeTo(.75, 1e-6));
    // The number never waits for the ease.
    expect(find.text('30 left'), findsOneWidget);
  });

  testWidgets('quiet mode jumps to a changed level with no animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 10, capacity: 40), quiet: true),
    );
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 20, capacity: 40), quiet: true),
    );
    expect(level(tester), closeTo(.5, 1e-6));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('empty and negative stock still print their number', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const StockCapsule(stock: -2)));
    await tester.pumpAndSettle();
    expect(find.text('-2 left'), findsOneWidget);
  });

  testWidgets('number is emphasised and words stay in one string', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 12, threshold: 5, color: Colors.teal)),
    );
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text('12 left'));
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans[1].text, '12');
    expect(spans[1].style!.fontWeight, FontWeight.w800);
    expect(tester.takeException(), isNull);
  });

  test('form reads into a shape; tint is own colour or stable fallback', () {
    expect(medicationShapeOf('Tablet'), MedicationShape.tablet);
    expect(medicationShapeOf('comprimat filmat'), MedicationShape.tablet);
    expect(medicationShapeOf('Syrup'), MedicationShape.drop);
    expect(medicationShapeOf('Capsule'), MedicationShape.capsule);
    expect(medicationShapeOf(null), MedicationShape.capsule);
    expect(medicationTint(id: 'a', color: '#E57373'), const Color(0xFFE57373));
    expect(
      medicationTint(id: 'abc', color: null),
      medicationTint(id: 'abc', color: null),
    );
    expect(
      {
        for (final id in ['a', 'b', 'c', 'd', 'e'])
          medicationTint(id: id, color: null),
      }.length,
      greaterThan(2),
    );
  });
}
