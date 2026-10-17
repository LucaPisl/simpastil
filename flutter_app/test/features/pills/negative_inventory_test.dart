import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  testWidgets('negative stock remains visible as an accessible warning', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: StockChip(stock: -2, threshold: 1)),
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Warning: negative stock')),
      findsOneWidget,
    );
    expect(find.text('-2 left'), findsOneWidget);
    semantics.dispose();
  });
}
