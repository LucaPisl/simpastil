import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/stock_state_label.dart';

Widget _host(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('low and out differ by shape, not only by colour', () {
    expect(
      stockStateIcon(StockState.low),
      isNot(stockStateIcon(StockState.out)),
    );
  });

  testWidgets('says the state in words with an icon, in English', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Locale('en'),
        const Column(
          children: [
            StockStateLabel(state: StockState.low, left: '6'),
            StockStateLabel(state: StockState.out, left: '0'),
          ],
        ),
      ),
    );
    expect(find.text('Low · 6 left'), findsOneWidget);
    expect(find.text('Out'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
  });

  testWidgets('says the state in words with an icon, in Romanian', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Locale('ro'),
        const Column(
          children: [
            StockStateLabel(state: StockState.low, left: '6'),
            StockStateLabel(state: StockState.out, left: '0'),
          ],
        ),
      ),
    );
    expect(find.text('Redus · rămase: 6'), findsOneWidget);
    expect(find.text('Epuizat'), findsOneWidget);
  });
}
