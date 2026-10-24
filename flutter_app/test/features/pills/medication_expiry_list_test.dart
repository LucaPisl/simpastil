import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/expiry.dart';
import 'package:simpastil/core/medication/medication_activity.dart';
import 'package:simpastil/features/pills/presentation/medication_compact_list.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

Widget _host(
  Widget child, {
  String language = 'en',
  bool dark = false,
  double scale = 1,
}) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.light(),
  darkTheme: AppTheme.dark(),
  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: c!,
  ),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

Widget _page(ExpiryState state, MedicationListSummary summary) => Column(
  children: [
    MedicationExpiryNote(summary: summary),
    MedicationCompactRow(
      id: 'a',
      name: 'Fakeolol',
      tint: Colors.teal,
      shape: MedicationShape.round,
      subtitle: 'Every day',
      stock: 10,
      stockText: '10',
      threshold: null,
      expiry: state,
    ),
  ],
);

MedicationListSummary _summary(List<String> names) => MedicationListSummary(
  status: StockStatus.fine,
  attention: const [],
  scheduled: 1,
  asNeeded: 0,
  expiring: names,
);

void main() {
  test('the summary carries the expiring names apart from the stock', () {
    final s = summarizeMedications(const [], expiring: ['A', 'B']);
    expect(s.expiring, ['A', 'B']);
    expect(s.status, StockStatus.untracked);
    expect(summarizeMedications(const []).expiring, isEmpty);
  });

  testWidgets('a row and the header name the expiry in words', (tester) async {
    await tester.pumpWidget(
      _host(
        _page(const ExpiryState(ExpiryPhase.soon, 12), _summary(['Fakeolol'])),
      ),
    );
    expect(find.text('Expires in 12 days'), findsOneWidget);
    expect(
      find.text('Expired or expiring within 30 days: Fakeolol'),
      findsOneWidget,
    );
    await tester.pumpWidget(
      _host(_page(const ExpiryState(ExpiryPhase.expired, -3), _summary([]))),
    );
    expect(find.text('Expired'), findsOneWidget);
    expect(find.byKey(const ValueKey('medication-expiry-note')), findsNothing);
    await tester.pumpWidget(
      _host(_page(const ExpiryState(ExpiryPhase.ok, 90), _summary([]))),
    );
    expect(find.byKey(const ValueKey('medication-expiry-a')), findsNothing);
  });

  testWidgets('Romanian wording', (tester) async {
    await tester.pumpWidget(
      _host(
        _page(const ExpiryState(ExpiryPhase.soon, 1), _summary(['Fakeolol'])),
        language: 'ro',
      ),
    );
    expect(
      find.text('Expirate sau care expiră în 30 de zile: Fakeolol'),
      findsOneWidget,
    );
    expect(find.textContaining('Expiră'), findsOneWidget);
  });

  testWidgets('a list row says the dosage text is not reviewed', (
    tester,
  ) async {
    Widget row(bool review) => MedicationCompactRow(
      id: 'third',
      name: 'Thirdmed',
      tint: Colors.teal,
      shape: MedicationShape.round,
      subtitle: 'Every day',
      stock: 10,
      threshold: null,
      dosageNeedsReview: review,
    );
    await tester.pumpWidget(_host(row(true)));
    expect(find.text('Original dosage text · Not reviewed'), findsOneWidget);
    await tester.pumpWidget(_host(row(false)));
    expect(find.textContaining('Not reviewed'), findsNothing);
    await tester.pumpWidget(_host(row(true), language: 'ro'));
    expect(find.text('Textul inițial al dozei · Neverificat'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('guidelines dark=$dark x$scale', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _host(
            _page(
              const ExpiryState(ExpiryPhase.expired, -2),
              _summary(['Fakeolol']),
            ),
            dark: dark,
            scale: scale,
          ),
        );
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  }
}
