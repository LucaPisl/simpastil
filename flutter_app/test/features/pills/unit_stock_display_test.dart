import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/inventory/stock_reading.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';
import 'package:simpastil/features/pills/presentation/medication_blister.dart';
import 'package:simpastil/features/pills/presentation/medication_compact_list.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/features/pills/presentation/stock_capsule.dart';
import 'package:simpastil/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

StockReading _reading(String wire, {String? unit, String? perUse}) =>
    StockReading(
      value: ExactStock.parseWire(wire).toDouble(),
      unit: unit,
      fromBalance: false,
      exact: ExactStock.parseWire(wire),
      perUse: perUse == null ? null : ExactStock.parseWire(perUse),
    );

void main() {
  group('StockReading.leftText', () {
    test('unit stock reads the exact amount, not the doses left', () {
      final reading = _reading('27.5', unit: 'tablets', perUse: '0.5');
      expect(reading.whole, 55);
      expect(reading.leftText('en'), '27½');
    });

    test('a plain count reads exactly as before', () {
      expect(_reading('12').leftText('en'), '12');
      expect(_reading('-3').leftText('en'), '-3');
    });

    test('Romanian uses the decimal comma for non-glyph fractions', () {
      final reading = _reading('0.125', unit: 'tablets');
      expect(reading.leftText('ro'), '0,125');
      expect(reading.leftText('en'), '0.125');
    });
  });

  testWidgets('the capsule prints the exact stock and speaks it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(const StockCapsule(stock: 55, stockText: '27½', threshold: 5)),
    );
    await tester.pumpAndSettle();
    expect(find.text('27½ left'), findsOneWidget);
    expect(find.bySemanticsLabel('27½ left'), findsOneWidget);
    expect(find.textContaining('55'), findsNothing);
    handle.dispose();
  });

  testWidgets('the list card shows the exact stock', (tester) async {
    await tester.pumpWidget(
      _host(
        MedicationCompactRow(
          id: 'half',
          name: 'Halfmed',
          tint: Colors.teal,
          shape: MedicationShape.round,
          subtitle: 'Every day',
          stock: 55,
          stockText: '27½',
          threshold: 5,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('27½ left'), findsOneWidget);
    expect(find.text('55 left'), findsNothing);
  });

  testWidgets('a plain count card is unchanged', (tester) async {
    await tester.pumpWidget(
      _host(
        MedicationCompactRow(
          id: 'plain',
          name: 'Plainmed',
          tint: Colors.teal,
          shape: MedicationShape.round,
          subtitle: 'Every day',
          stock: 12,
          threshold: 5,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('12 left'), findsOneWidget);
  });

  testWidgets('the stock chip shows the exact stock', (tester) async {
    await tester.pumpWidget(
      _host(const StockChip(stock: 55, stockText: '27½', threshold: 5)),
    );
    expect(find.text('27½ left'), findsOneWidget);
  });

  testWidgets('the blister cell speaks the exact stock', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 320,
          child: MedicationBlister(
            onTap: (_) {},
            cells: const [
              BlisterCell(
                id: 'half',
                name: 'Halfmed',
                color: Colors.teal,
                stock: 55,
                stockText: '27½',
                threshold: 5,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.bySemanticsLabel('Halfmed, 27½ left'), findsWidgets);
    handle.dispose();
  });

  group('the Today stock row', () {
    StockInput input({String? text}) => StockInput(
      pillId: 'p',
      name: 'Halfmed',
      personId: 'me',
      personName: 'Me',
      color: null,
      asNeeded: false,
      currentStock: 55,
      currentStockText: text,
      threshold: null,
      forecast: null,
      asNeededStock: null,
    );

    test('reads the exact stock of a unit count', () {
      expect(stockRowFor(input(text: '27½'))!.left, '27½');
    });

    test('keeps the whole-dose count of a plain count', () {
      expect(stockRowFor(input())!.left, '55');
    });
  });

  group('the typed stock under the pill editor field', () {
    Future<void> typed(WidgetTester tester, String text) async {
      final controller = TextEditingController(text: text);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          StockStepper(
            controller: controller,
            label: 'Stock',
            tint: Colors.teal,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('"7 1/2" reads 7½ left', (tester) async {
      await typed(tester, '7 1/2');
      expect(find.text('7½ left'), findsOneWidget);
      expect(find.text('7 left'), findsNothing);
    });

    testWidgets('7.5 reads 7½ left', (tester) async {
      await typed(tester, '7.5');
      expect(find.text('7½ left'), findsOneWidget);
    });

    testWidgets('a whole number reads as before', (tester) async {
      await typed(tester, '7');
      expect(find.text('7 left'), findsOneWidget);
    });
  });
}
