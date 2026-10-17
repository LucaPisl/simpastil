import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/pill_colors.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  test('form text reads into a shape, unknown stays a capsule', () {
    expect(medicationShapeOf('Tablet'), MedicationShape.tablet);
    expect(medicationShapeOf('comprimate'), MedicationShape.tablet);
    expect(medicationShapeOf('Syrup'), MedicationShape.drop);
    expect(medicationShapeOf(''), MedicationShape.capsule);
    expect(medicationShapeOf(null), MedicationShape.capsule);
  });

  test('tint is the own colour, or stable from the id', () {
    expect(
      medicationTint(id: 'a', color: kPillColors[2].hex),
      colorFromHex(kPillColors[2].hex),
    );
    expect(
      medicationTint(id: 'pill-1', color: null),
      medicationTint(id: 'pill-1', color: null),
    );
  });

  test('preview line skips empty parts', () {
    expect(previewLine(['20 mg', ' ', 'Tablet']), '20 mg · Tablet');
    expect(previewLine(['', '']), '');
  });

  testWidgets('preview follows the name and falls back to a placeholder', (
    tester,
  ) async {
    final name = TextEditingController();
    addTearDown(name.dispose);
    await tester.pumpWidget(
      _host(
        MedicationPreview(
          listenable: name,
          name: () => name.text,
          form: () => 'Tablet',
          detail: () => '',
          tint: Colors.teal,
        ),
      ),
    );
    expect(find.text('Your medication'), findsOneWidget);
    name.text = 'Fictional calm';
    await tester.pump();
    expect(find.text('Fictional calm'), findsOneWidget);
    expect(find.text('Your medication'), findsNothing);
  });

  testWidgets('tint picker reports a choice and marks it selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    String? chosen;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => TintPicker(
            selected: chosen,
            onSelected: (hex) => setState(() => chosen = hex),
          ),
        ),
      ),
    );
    final hex = kPillColors[3].hex;
    await tester.tap(find.byKey(ValueKey('tint-$hex')));
    await tester.pumpAndSettle();
    expect(chosen, hex);
    expect(
      tester.getSemantics(find.byKey(ValueKey('tint-$hex'))),
      isSemantics(isButton: true, isSelected: true, hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('stock stepper steps and never offers going below zero', (
    tester,
  ) async {
    final stock = TextEditingController(text: '1');
    addTearDown(stock.dispose);
    await tester.pumpWidget(
      _host(StockStepper(controller: stock, label: 'Stock', tint: Colors.teal)),
    );
    // The label stays whole above the row, and the field still carries it.
    expect(find.text('Stock'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Stock')), findsWidgets);
    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    expect(stock.text, '2');
    await tester.tap(find.byTooltip('One fewer'));
    await tester.pump();
    await tester.tap(find.byTooltip('One fewer'));
    await tester.pump();
    expect(stock.text, '0');
    await tester.tap(find.byTooltip('One fewer'));
    await tester.pump();
    expect(stock.text, '0');
    await tester.pumpAndSettle();
  });
}
