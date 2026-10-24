import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/settings/presentation/account_follow_widgets.dart';
import 'package:simpastil/l10n/app_localizations.dart';

Widget _host({required bool supported, required double scale}) => ProviderScope(
  overrides: [
    accountSettingsSupportedProvider.overrideWith((ref) async => supported),
    accountSettingsNoteProvider.overrideWith((ref) async => const []),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const Scaffold(
      body: Column(
        children: [
          AccountFollowsLine(),
          DeviceOnlyLabel('appLock'),
          DeviceOnlyLabel('language'),
          DeviceOnlyLabel('todayLayout'),
          DeviceOnlyLabel('wallpaperColors'),
          DeviceOnlyLabel('lockScreenDetails'),
          DeviceOnlyLabel('focusAsNeededShortcut'),
        ],
      ),
    ),
  ),
);

void main() {
  colorsCaptionTests();
  testWidgets('against a server that keeps settings, labels and line show', (
    tester,
  ) async {
    await tester.pumpWidget(_host(supported: true, scale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('Everything else follows your account.'), findsOneWidget);
    expect(find.text('Only on this device'), findsNWidgets(5));
    for (final id in [
      'appLock',
      'todayLayout',
      'wallpaperColors',
      'lockScreenDetails',
      'focusAsNeededShortcut',
    ]) {
      expect(find.byKey(ValueKey('device-only-$id')), findsOneWidget);
    }
    // An account setting is never labelled device-only.
    expect(find.byKey(const ValueKey('device-only-language')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('against an older server nothing is promised', (tester) async {
    await tester.pumpWidget(_host(supported: false, scale: 1.0));
    await tester.pumpAndSettle();
    expect(find.text('Everything else follows your account.'), findsNothing);
    expect(find.text('Only on this device'), findsNothing);
  });
}

void colorsCaptionTests() {
  for (final supported in [true, false]) {
    for (final dark in [false, true]) {
      testWidgets('the Colors caption, supported=$supported dark=$dark', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountSettingsSupportedProvider.overrideWith(
                (ref) async => supported,
              ),
            ],
            child: MaterialApp(
              locale: const Locale('en'),
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: AccountFollowsLabel()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('follows-account-colors')),
          supported ? findsOneWidget : findsNothing,
        );
        if (supported) {
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        }
        handle.dispose();
      });
    }
  }
}
