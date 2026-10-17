import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/care_state.dart';

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Loading…'),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a fast load never paints its placeholder', (tester) async {
    await tester.pumpWidget(
      _app(const CareState(title: 'Loading…', loading: true)),
    );
    // Built at once (semantics and finders see it), painted only after grace.
    expect(find.text('Loading…'), findsOneWidget);
    expect(_opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_opacity(tester), 1);
  });

  testWidgets('settled states show at once', (tester) async {
    await tester.pumpWidget(_app(const CareState(title: 'Nothing today')));
    expect(find.text('Nothing today'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Nothing today'),
        matching: find.byWidgetPredicate(
          (w) => w is FadeTransition && w.opacity.value < 1,
        ),
      ),
      findsNothing,
    );
  });
}
