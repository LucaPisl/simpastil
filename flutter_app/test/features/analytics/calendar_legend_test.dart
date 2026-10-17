import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/analytics/month_panel.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  testWidgets('the calendar legend names a recorded miss', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CalendarLegend()),
      ),
    );
    for (final label in ['Taken', 'Skipped', 'Not recorded', 'Missed']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('As needed'), findsOneWidget);
  });
}
