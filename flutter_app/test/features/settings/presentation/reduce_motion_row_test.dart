import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/motion/app_motion.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

class _Storage implements AppearancePreferenceStorage {
  _Storage(AppearancePreferences initial)
    : document = jsonEncode(initial.toJson());
  String? document;
  bool fail = false;
  @override
  Future<String?> readDocument() async => document;
  @override
  Future<Map<String, Object?>> readLegacy() async => {};
  @override
  Future<bool> writeDocument(String value) async {
    if (fail) return false;
    document = value;
    return true;
  }
}

void main() {
  final row = find.byKey(const ValueKey('reduce-motion'));
  final toggle = find.descendant(of: row, matching: find.byType(Switch));

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    AppearancePreferences? initial,
    bool phoneReduces = false,
    bool accessibleNavigation = false,
    bool dense = false,
    double width = 380,
    _Storage? storage,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appearanceRepositoryProvider.overrideWithValue(
          AppearancePreferencesRepository(
            storage ?? _Storage(initial ?? AppearancePreferences()),
          ),
        ),
        appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: phoneReduces,
              accessibleNavigation: accessibleNavigation,
            ),
            child: ReducedMotionScope(
              reduce: container.read(reduceMotionProvider),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: ReduceMotionRow(dense: dense),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Switch switchWidget(WidgetTester tester) => tester.widget<Switch>(toggle);

  testWidgets('starts off, enabled, with the plain hint', (tester) async {
    await mount(tester);
    expect(find.text('Reduce motion'), findsOneWidget);
    expect(
      find.text(
        'Things appear in place instead of moving. Words and vibrations stay the same.',
      ),
      findsOneWidget,
    );
    expect(switchWidget(tester).value, isFalse);
    expect(switchWidget(tester).onChanged, isNotNull);
  });

  testWidgets('tapping the row turns it on and saves it', (tester) async {
    final storage = _Storage(AppearancePreferences(mode: AppearanceMode.dark));
    final container = await mount(tester, storage: storage);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(switchWidget(tester).value, isTrue);
    expect(container.read(reduceMotionProvider), isTrue);
    final saved = jsonDecode(storage.document!) as Map<String, Object?>;
    expect(saved['reduceMotion'], true);
    expect(saved['mode'], 'dark');
    expect(
      (await AppearancePreferencesRepository(storage).load()).reduceMotion,
      isTrue,
    );
  });

  testWidgets('tapping the switch itself turns it off again', (tester) async {
    final storage = _Storage(AppearancePreferences(reduceMotion: true));
    final container = await mount(tester, storage: storage);
    expect(switchWidget(tester).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(switchWidget(tester).value, isFalse);
    expect(container.read(reduceMotionProvider), isFalse);
    expect(
      (jsonDecode(storage.document!) as Map<String, Object?>)['reduceMotion'],
      false,
    );
  });

  testWidgets('a choice that cannot be saved stays off and says so', (
    tester,
  ) async {
    final storage = _Storage(AppearancePreferences())..fail = true;
    final container = await mount(tester, storage: storage);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(container.read(reduceMotionProvider), isFalse);
    expect(switchWidget(tester).value, isFalse);
    expect(
      (jsonDecode(storage.document!) as Map<String, Object?>)['reduceMotion'],
      false,
    );
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a phone that reduces motion shows it on, locked, and why', (
    tester,
  ) async {
    final storage = _Storage(AppearancePreferences());
    final container = await mount(tester, phoneReduces: true, storage: storage);
    expect(switchWidget(tester).value, isTrue);
    expect(switchWidget(tester).onChanged, isNull);
    expect(
      find.text("On because of your phone's accessibility settings."),
      findsOneWidget,
    );
    expect(
      find.text(
        'Things appear in place instead of moving. Words and vibrations stay the same.',
      ),
      findsNothing,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(container.read(reduceMotionProvider), isFalse);
    expect(
      (jsonDecode(storage.document!) as Map<String, Object?>)['reduceMotion'],
      false,
    );
    expect(switchWidget(tester).value, isTrue);
  });

  testWidgets('an accessibility service alone leaves the switch free', (
    tester,
  ) async {
    // Bitwarden, automation apps and screen readers all turn on Android's
    // accessible navigation; only "Remove animations" may lock the switch.
    final storage = _Storage(AppearancePreferences());
    final container = await mount(
      tester,
      accessibleNavigation: true,
      storage: storage,
    );
    expect(switchWidget(tester).value, isFalse);
    expect(switchWidget(tester).onChanged, isNotNull);
    expect(
      find.text("On because of your phone's accessibility settings."),
      findsNothing,
    );
    expect(
      find.text(
        'Things appear in place instead of moving. Words and vibrations stay the same.',
      ),
      findsOneWidget,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(switchWidget(tester).value, isTrue);
    expect(container.read(reduceMotionProvider), isTrue);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(switchWidget(tester).value, isFalse);
    expect(
      (jsonDecode(storage.document!) as Map<String, Object?>)['reduceMotion'],
      false,
    );
  });

  testWidgets('the app choice does not look like the phone asking', (
    tester,
  ) async {
    await mount(tester, initial: AppearancePreferences(reduceMotion: true));
    expect(switchWidget(tester).value, isTrue);
    expect(switchWidget(tester).onChanged, isNotNull);
    expect(
      find.text("On because of your phone's accessibility settings."),
      findsNothing,
    );
  });

  testWidgets('says it is a switch with its name and state', (tester) async {
    final handle = tester.ensureSemantics();
    await mount(tester);
    expect(
      tester.getSemantics(row),
      matchesSemantics(
        label:
            'Reduce motion\n'
            'Things appear in place instead of moving. Words and vibrations stay the same.',
        hasToggledState: true,
        isToggled: false,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(row),
      matchesSemantics(
        label:
            'Reduce motion\n'
            'Things appear in place instead of moving. Words and vibrations stay the same.',
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a locked switch is still announced as on', (tester) async {
    final handle = tester.ensureSemantics();
    await mount(tester, phoneReduces: true);
    final node = tester.getSemantics(row);
    // ignore: deprecated_member_use
    final data = node.getSemanticsData();
    expect(data.label, startsWith('Reduce motion'));
    expect(data.flagsCollection.isToggled.name, 'isTrue');
    expect(data.flagsCollection.isEnabled.name, isNot('isTrue'));
    handle.dispose();
  });

  testWidgets('the list version keeps a compact switch that still toggles', (
    tester,
  ) async {
    final container = await mount(tester, dense: true, width: 256);
    // The 256dp Settings list gives the label more room with a smaller switch.
    final slot = tester.getSize(
      find.ancestor(of: toggle, matching: find.byType(FittedBox)),
    );
    expect(slot.width, lessThanOrEqualTo(42));
    expect(slot.height, lessThanOrEqualTo(32));
    expect(tester.takeException(), isNull);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(container.read(reduceMotionProvider), isTrue);
    expect(switchWidget(tester).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(container.read(reduceMotionProvider), isFalse);
  });
}
