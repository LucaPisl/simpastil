import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/pills/presentation/stock_capsule.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

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
    expect(find.text('Low · 3 left'), findsOneWidget);
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

  testWidgets('low stock adds a warning icon and "Low · N left"', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const StockCapsule(stock: 6, threshold: 8)));
    await tester.pumpAndSettle();
    expect(find.text('Low · 6 left'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('Low · 6 left'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('out of stock says "Out" beside its own icon', (tester) async {
    await tester.pumpWidget(_host(const StockCapsule(stock: 0, threshold: 8)));
    await tester.pumpAndSettle();
    expect(find.text('Out'), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('enough stock stays a plain count with no icon', (tester) async {
    await tester.pumpWidget(_host(const StockCapsule(stock: 20, threshold: 8)));
    await tester.pumpAndSettle();
    expect(find.text('20 left'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byIcon(Icons.block_rounded), findsNothing);
  });

  testWidgets('the capsule marks the refill level with a tick', (tester) async {
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 20, threshold: 8, capacity: 40)),
    );
    await tester.pumpAndSettle();
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(StockCapsule),
        matching: find.byType(CustomPaint),
      ),
    );
    // ignore: avoid_dynamic_calls
    expect((paint.painter! as dynamic).mark as double?, closeTo(.2, 1e-6));
  });

  testWidgets('the Romanian words are used too', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ro'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(
            children: [
              StockCapsule(stock: 6, threshold: 8),
              StockCapsule(stock: 0, threshold: 8),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Redus · rămase: 6'), findsOneWidget);
    expect(find.text('Epuizat'), findsOneWidget);
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
    expect(medicationShapeOf('Tablet'), MedicationShape.round);
    expect(medicationShapeOf('comprimat filmat'), MedicationShape.round);
    expect(medicationShapeOf('Syrup'), MedicationShape.drop);
    expect(medicationShapeOf('Capsule'), MedicationShape.capsule);
    expect(medicationShapeOf(null), MedicationShape.capsule);
    expect(medicationTint(id: 'a', color: '#E57373'), const Color(0xFFFD2B35));
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

  testWidgets(
    'a count wraps to at most two lines, at full size, in a narrow large-text card',
    (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(1.3),
            disableAnimations: true,
          ),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 150,
                  child: StockCapsule(
                    stock: 12,
                    stockText: '12\u00BD',
                    threshold: 5,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final box = tester.getSize(find.byType(RichText).last);
      // Never scaled down: it wraps to a second line instead, no more.
      expect(
        find.descendant(
          of: find.byType(StockCapsule),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
      expect(box.height, lessThan(72));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a long Romanian low label wraps at full size, in tan not red', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          disableAnimations: true,
          textScaler: TextScaler.linear(1.3),
        ),
        child: MaterialApp(
          locale: const Locale('ro'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 190,
                child: StockCapsule(stock: 3, threshold: 5),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Nothing scales the words down, and they stay inside the box.
    expect(
      find.descendant(
        of: find.byType(StockCapsule),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
    expect(find.textContaining('Redus'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(StockCapsule)).width,
      lessThanOrEqualTo(190),
    );
    // Low is the tan attention tone, not the red kept for out of stock.
    final theme = Theme.of(tester.element(find.byType(StockCapsule)));
    final icon = tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded));
    expect(icon.color, statusToneColor(theme, StatusTone.attention));
    expect(icon.color, isNot(theme.colorScheme.error));
  });
}
