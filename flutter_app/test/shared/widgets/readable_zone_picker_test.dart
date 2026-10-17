import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/readable_zone_picker.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<void> showLabel(
    WidgetTester tester,
    String identifier, {
    Locale locale = const Locale('en'),
  }) => tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Text(readableZone(context, identifier)),
        ),
      ),
    ),
  );

  Future<void> openPicker(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    required void Function(String?) onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onSelected(await chooseReadableZone(context));
              },
              child: const Text('Choose place'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose place'));
    await tester.pumpAndSettle();
  }

  for (final entry in const {
    'en': 'Bucharest, Romania',
    'ro': 'București, România',
  }.entries) {
    testWidgets('Bucharest displays its localized country in ${entry.key}', (
      tester,
    ) async {
      await showLabel(tester, 'Europe/Bucharest', locale: Locale(entry.key));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.textContaining('Europe/Bucharest'), findsNothing);
    });
  }

  testWidgets(
    'known place displays readable words without identifier separators',
    (tester) async {
      await showLabel(tester, 'America/New_York');
      await tester.pumpAndSettle();
      expect(find.text('New York · America'), findsOneWidget);
      expect(find.textContaining('/'), findsNothing);
      expect(find.textContaining('_'), findsNothing);
    },
  );

  for (final entry in const {
    'en': 'Time zone needs review',
    'ro': 'Fusul orar trebuie verificat',
  }.entries) {
    testWidgets(
      'unknown place uses a neutral localized label in ${entry.key}',
      (tester) async {
        await showLabel(
          tester,
          'Nowhere/PRIVATE_CITY',
          locale: Locale(entry.key),
        );
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
        expect(find.textContaining('Nowhere'), findsNothing);
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(find.textContaining('CITY'), findsNothing);
      },
    );
  }

  for (final query in ['Bucuresti', 'Romania']) {
    testWidgets('Romanian search finds Bucharest without accents: $query', (
      tester,
    ) async {
      await openPicker(tester, locale: const Locale('ro'), onSelected: (_) {});
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(ListTile, 'București, România'),
        findsOneWidget,
      );
      expect(find.textContaining('Europe/Bucharest'), findsNothing);
    });
  }

  testWidgets('choosing a readable place returns its canonical identifier', (
    tester,
  ) async {
    String? selected;
    var returned = false;
    await openPicker(
      tester,
      onSelected: (value) {
        selected = value;
        returned = true;
      },
    );
    await tester.enterText(find.byType(TextField), 'Bucharest');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Bucharest, Romania'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(selected, 'Europe/Bucharest');
  });

  testWidgets('canceling the place picker returns no selection', (
    tester,
  ) async {
    String? selected = 'unchanged';
    var returned = false;
    await openPicker(
      tester,
      onSelected: (value) {
        selected = value;
        returned = true;
      },
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(selected, isNull);
  });
}
