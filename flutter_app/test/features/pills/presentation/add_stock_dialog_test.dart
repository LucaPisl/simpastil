import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/features/pills/presentation/add_stock_dialog.dart';
import 'package:simpastil/features/pills/presentation/medication_form_kit.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

ExactStock? _result;
bool _closed = false;

Widget _host({
  required Locale locale,
  required bool dark,
  required double scale,
  required bool parts,
  String? unit,
  bool needsRecount = false,
  ExactStock? current,
}) => MaterialApp(
  locale: locale,
  theme: AppTheme.light(),
  darkTheme: AppTheme.dark(),
  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: c!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          _result = await showAddStockDialog(
            context,
            medicationName: 'Fakeolol',
            current: current ?? ExactStock.fromInt(12),
            parts: parts,
            unit: unit,
            needsRecount: needsRecount,
          );
          _closed = true;
        },
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    _result = null;
    _closed = false;
  });

  _unitAndRefusal();
  _wrapAndNow();

  testWidgets('a part is added through the part button', (tester) async {
    await tester.pumpWidget(
      _host(
        locale: const Locale('en'),
        dark: false,
        scale: 1,
        parts: true,
        unit: 'tablet',
        current: ExactStock.parseWire('2.5'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Now: 2½ tablets'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('add-stock-amount')), '3');
    await tester.tap(find.byKey(const ValueKey('stock-part-button')));
    await tester.pumpAndSettle();
    expect(find.text('Part of a tablet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stock-part-2')));
    await tester.pumpAndSettle();
    expect(find.text('New total: 6'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
    await tester.pumpAndSettle();
    expect(_closed, isTrue);
    expect(_result?.toWire(), '3.5');
  });

  testWidgets('a whole count refuses a part', (tester) async {
    await tester.pumpWidget(
      _host(locale: const Locale('en'), dark: false, scale: 1, parts: false),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-part-button')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('add-stock-amount')),
      '1.5',
    );
    await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
    await tester.pumpAndSettle();
    expect(_closed, isFalse);
    expect(find.text('Enter how many to add, more than zero.'), findsOne);
  });

  for (final ro in [false, true]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('guidelines ro=$ro dark=$dark x$scale', (tester) async {
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            _host(
              locale: Locale(ro ? 'ro' : 'en'),
              dark: dark,
              scale: scale,
              parts: true,
              unit: 'capsule',
              needsRecount: true,
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('add-stock-amount')),
            '4',
          );
          await tester.pump();
          expect(
            find.text(ro ? 'Acum: 12 capsule' : 'Now: 12 capsules'),
            findsOneWidget,
          );
          expect(
            find.text(ro ? 'Total nou: 16' : 'New total: 16'),
            findsOneWidget,
          );
          expect(find.text(ro ? 'Adaugă' : 'Add'), findsOneWidget);
          expect(
            find.text(
              ro
                  ? 'Acest stoc este încă marcat pentru renumărare. Adăugarea '
                        'nu o rezolvă; o rezolvă o renumărare.'
                  : 'This count is still marked for a recount. Adding stock '
                        'does not settle it; a recount does.',
            ),
            findsOneWidget,
          );
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await tester.tap(find.byKey(const ValueKey('stock-part-button')));
          await tester.pumpAndSettle();
          expect(
            find.text(ro ? 'O parte dintr-o capsulă' : 'Part of a capsule'),
            findsOneWidget,
          );
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          handle.dispose();
        });
      }
    }
  }
}

void _unitAndRefusal() {
  Future<void> open(WidgetTester tester, String lang, String unit) async {
    await tester.pumpWidget(
      _host(
        locale: Locale(lang),
        dark: false,
        scale: 1,
        parts: false,
        unit: unit,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String value) async {
    await tester.enterText(
      find.byKey(const ValueKey('add-stock-amount')),
      value,
    );
    await tester.pump();
  }

  String? suffix(WidgetTester tester) => tester
      .widget<StockWholeField>(find.byKey(const ValueKey('add-stock-amount')))
      .decoration
      .suffixText;

  for (final c in [
    ('en', '1', 'tablet'),
    ('en', '3', 'tablets'),
    ('ro', '1', 'comprimat'),
    ('ro', '3', 'comprimate'),
    ('ro', '20', 'de comprimate'),
  ]) {
    testWidgets('the unit agrees with ${c.$2} typed, ${c.$1}', (tester) async {
      await open(tester, c.$1, 'tablet');
      await type(tester, c.$2);
      expect(suffix(tester), c.$3);
    });
  }

  for (final value in ['0', '-2', '−2']) {
    for (final lang in ['en', 'ro']) {
      testWidgets('"$value" is refused with an inline error, $lang', (
        tester,
      ) async {
        await open(tester, lang, 'tablet');
        await type(tester, value);
        final l = lookupAppLocalizations(Locale(lang));
        expect(find.text(l.rvm_addStockNeeded), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('add-stock-confirm')));
        await tester.pumpAndSettle();
        expect(_closed, isFalse);
      });
    }
  }
}

void _wrapAndNow() {
  for (final lang in ['en', 'ro']) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('the error wraps instead of ellipsizing, $lang x$scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            locale: Locale(lang),
            dark: false,
            scale: scale,
            parts: false,
            unit: 'tablet',
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('add-stock-amount')),
          '0',
        );
        await tester.pump();
        final l = lookupAppLocalizations(Locale(lang));
        final error = find.text(l.rvm_addStockNeeded);
        expect(error, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(error);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final c in [
    ('en', '0', 'tablets'),
    ('en', '-2', 'tablets'),
    ('en', '', 'tablets'),
    ('ro', '0', 'comprimate'),
    ('ro', '-2', 'comprimate'),
    ('ro', '', 'comprimate'),
  ]) {
    testWidgets('the unit is plural for "${c.$2}", ${c.$1}', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: Locale(c.$1),
          dark: false,
          scale: 1,
          parts: false,
          unit: 'tablet',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('add-stock-amount')),
        c.$2,
      );
      await tester.pump();
      final field = tester.widget<StockWholeField>(
        find.byKey(const ValueKey('add-stock-amount')),
      );
      expect(field.decoration.suffixText, c.$3);
    });
  }

  for (final c in [
    ('en', '9', 'Now: 9 tablets'),
    ('en', '1', 'Now: 1 tablet'),
    ('en', '17.5', 'Now: 17½ tablets'),
    ('ro', '9', 'Acum: 9 comprimate'),
    ('ro', '1', 'Acum: 1 comprimat'),
    ('ro', '20', 'Acum: 20 de comprimate'),
  ]) {
    testWidgets('"Now" carries the unit: ${c.$3}', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: Locale(c.$1),
          dark: false,
          scale: 1,
          parts: true,
          unit: 'tablet',
          current: ExactStock.parseWire(c.$2),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(c.$3), findsOneWidget);
    });
  }
}
