import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

Future<TextEditingController> _open(
  WidgetTester tester, {
  required ThemeData theme,
  String language = 'en',
  double textScale = 1.0,
}) async {
  final controller = TextEditingController(text: '7 1/2');
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(360, 740),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Center(child: StockPartButton(controller: controller)),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('stock-part-button')));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  for (final (name, theme) in [
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
  ]) {
    testWidgets('the pop-up meets the contrast and target guidelines, $name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _open(tester, theme: theme, textScale: 1.3);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }

  testWidgets('the pop-up reads in Romanian and marks the current part', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester, theme: AppTheme.light(), language: 'ro');
    expect(find.text('O parte dintr-una'), findsOneWidget);
    expect(find.text('Trei sferturi'), findsOneWidget);
    final half = tester.getSemantics(
      find.byKey(const ValueKey('stock-part-2')),
    );
    expect(half.label, 'O jumătate');
    expect(half.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });
}
