import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/storage/as_needed_shortcut_preference.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/features/settings/presentation/appearance_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

class _Storage implements AppearancePreferenceStorage {
  @override
  Future<String?> readDocument() async => null;
  @override
  Future<Map<String, Object?>> readLegacy() async => {};
  @override
  Future<bool> writeDocument(String value) async => true;
}

Future<(ProviderContainer, SharedPreferences)> _mount(
  WidgetTester tester, {
  Map<String, Object> stored = const {},
  Locale locale = const Locale('en'),
}) async {
  SharedPreferences.setMockInitialValues(stored);
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appearanceRepositoryProvider.overrideWithValue(
        AppearancePreferencesRepository(_Storage()),
      ),
      appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: const AppearanceScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container, preferences);
}

final _toggle = find.byKey(const ValueKey('appearance-as-needed-shortcut'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the shortcut toggle is on by default and persists when turned '
      'off and on', (tester) async {
    final (container, preferences) = await _mount(tester);
    await tester.ensureVisible(_toggle);
    await tester.pumpAndSettle();
    expect(find.text('As needed shortcut'), findsOneWidget);
    expect(
      find.text('Show a button that jumps to your as-needed medications'),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(_toggle).value, isTrue);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_toggle).value, isFalse);
    expect(container.read(asNeededShortcutProvider), isFalse);
    expect(preferences.getBool(kAsNeededShortcutPreferenceKey), isFalse);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(container.read(asNeededShortcutProvider), isTrue);
    expect(preferences.getBool(kAsNeededShortcutPreferenceKey), isTrue);
  });

  testWidgets('a stored off value is read back', (tester) async {
    await _mount(tester, stored: {kAsNeededShortcutPreferenceKey: false});
    await tester.ensureVisible(_toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_toggle).value, isFalse);
  });

  testWidgets('the toggle is only offered on the Focus deck layout', (
    tester,
  ) async {
    await _mount(tester, stored: {kLayoutFamilyPreferenceKey: 'timeline'});
    expect(_toggle, findsNothing);
    expect(find.text('As needed shortcut'), findsNothing);
  });

  testWidgets('the toggle reads in Romanian', (tester) async {
    await _mount(tester, locale: const Locale('ro'));
    await tester.ensureVisible(_toggle);
    await tester.pumpAndSettle();
    expect(find.text('Scurtătură pentru La nevoie'), findsOneWidget);
  });
}
