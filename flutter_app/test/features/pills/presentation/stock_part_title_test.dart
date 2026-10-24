import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

Widget _app(
  Locale locale,
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  locale: locale,
  theme: AppTheme.light(),
  darkTheme: AppTheme.dark(),
  themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: c!,
  ),
  home: Scaffold(body: Center(child: child)),
);

String _title(AppLocalizations l, String? unit) => stockPartTitle(l, unit);

void main() {
  test('every unit the app counts in names itself in the title', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(_title(en, 'tablet'), 'Part of a tablet');
    expect(_title(en, 'Tablets'), 'Part of a tablet');
    expect(_title(en, 'capsules'), 'Part of a capsule');
    expect(_title(en, 'comprimate'), 'Part of a tablet');
    expect(_title(en, 'pastile'), 'Part of a pill');
    expect(_title(en, null), 'Part of one');
    expect(_title(en, 'ml'), 'Part of one');
  });

  test('Romanian titles agree in gender with the unit', () {
    final ro = lookupAppLocalizations(const Locale('ro'));
    expect(_title(ro, 'tablet'), 'O parte dintr-un comprimat');
    expect(_title(ro, 'capsule'), 'O parte dintr-o capsulă');
    expect(_title(ro, 'comprimat'), 'O parte dintr-un comprimat');
    expect(_title(ro, 'pastilă'), 'O parte dintr-o pastilă');
    expect(_title(ro, null), 'O parte dintr-una');
  });

  test('a stored count shows its whole number, the part is on the button', () {
    expect(StockWholeField.shownFor('7 1/2', wholeOnly: true), '7');
    expect(StockWholeField.shownFor('7.5', wholeOnly: true), '7');
    expect(StockWholeField.shownFor('1/4', wholeOnly: true), '0');
    expect(StockWholeField.shownFor('', wholeOnly: true), '');
    // A part that is not a quarter is never hidden.
    expect(StockWholeField.shownFor('0.125', wholeOnly: true), '0.125');
    expect(StockWholeField.shownFor('7.5', wholeOnly: false), '7.5');
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('part pop-up in Romanian, dark=$dark scale=$scale', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final controller = TextEditingController(text: '7');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _app(
            const Locale('ro'),
            StockPartButton(controller: controller, unit: 'tablets'),
            brightness: dark ? Brightness.dark : Brightness.light,
            scale: scale,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('stock-part-button')));
        await tester.pumpAndSettle();
        expect(find.text('O parte dintr-un comprimat'), findsOneWidget);
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  }
}
