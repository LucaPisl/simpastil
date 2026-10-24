import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/expiry.dart';
import 'package:simpastil/features/dashboard/today_layout/low_stock_notice.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

StockRow _row(
  String id, {
  StockLevel level = StockLevel.ok,
  ExpiryState expiry = ExpiryState.none,
}) => StockRow(
  pillId: id,
  name: 'Med $id',
  personId: 'p',
  personName: 'Pat',
  color: null,
  asNeeded: false,
  left: '3',
  unit: null,
  fraction: .2,
  level: level,
  runsLowInDays: 2,
  forecast: null,
  expiry: expiry,
);

Widget _app(
  List<StockRow> rows, {
  bool dark = false,
  double scale = 1,
  String locale = 'en',
}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: dark ? AppTheme.dark() : AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: LowStockSection(rows: rows, onAddStock: (_) {}, onLater: (_) {}),
      ),
    ),
  ),
);

void main() {
  final rows = [
    _row('a', level: StockLevel.low),
    _row('b', expiry: const ExpiryState(ExpiryPhase.soon, 19)),
  ];

  testWidgets('expiry-only rows sit under their own heading', (tester) async {
    await tester.pumpWidget(_app(rows));
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('Expires soon'), findsOneWidget);
    final low = tester.getTopLeft(find.text('Low stock')).dy;
    final soon = tester.getTopLeft(find.text('Expires soon')).dy;
    final lowRow = tester.getTopLeft(find.text('Med a')).dy;
    final soonRow = tester.getTopLeft(find.text('Med b')).dy;
    expect(low < lowRow && lowRow < soon && soon < soonRow, isTrue);
  });

  testWidgets('only expiring rows show no Low stock heading', (tester) async {
    await tester.pumpWidget(_app([rows.last]));
    expect(find.text('Low stock'), findsNothing);
    expect(find.text('Expires soon'), findsOneWidget);
  });

  testWidgets('the expiry row is not read with Expires twice', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(rows));
    expect(find.bySemanticsLabel('Med b. Expires in 19 days'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Expires\.')), findsNothing);
    expect(
      find.bySemanticsLabel('Low stock. Med a. Refill soon · 3 left'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('Romanian headings render', (tester) async {
    await tester.pumpWidget(_app(rows, locale: 'ro'));
    expect(find.text('Stoc redus'), findsOneWidget);
    expect(find.text('Expiră curând'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('guidelines (dark: $dark, scale: $scale)', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_app(rows, dark: dark, scale: scale));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  }

  testWidgets('a low and expiring medication is under both headings', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([
        _row(
          'a',
          level: StockLevel.low,
          expiry: const ExpiryState(ExpiryPhase.soon, 9),
        ),
      ]),
    );
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('Expires soon'), findsOneWidget);
    expect(find.text('Med a'), findsNWidgets(2));
  });

  for (final lang in ['en', 'ro']) {
    testWidgets('an expired one changes the heading, $lang', (tester) async {
      await tester.pumpWidget(
        _app([
          _row('a', expiry: const ExpiryState(ExpiryPhase.expired, -3)),
          _row('b', expiry: const ExpiryState(ExpiryPhase.soon, 4)),
        ], locale: lang),
      );
      expect(
        find.text(
          lang == 'en'
              ? 'Expired or expiring soon'
              : 'Expirate sau care expiră curând',
        ),
        findsOneWidget,
      );
    });
  }
}
