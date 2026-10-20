import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/features/settings/presentation/appearance_preview.dart';
import 'package:simpastil/features/settings/presentation/appearance_screen.dart';
import 'package:simpastil/features/settings/presentation/theme_mode_switch.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/motion/theme_reveal.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import '../../../helpers/held_provider_read.dart';

class _Storage implements AppearancePreferenceStorage {
  String? document;
  bool fail = false;
  int writes = 0;
  @override
  Future<String?> readDocument() async => document;
  @override
  Future<Map<String, Object?>> readLegacy() async => {};
  @override
  Future<bool> writeDocument(String value) async {
    writes++;
    if (fail) return false;
    document = value;
    return true;
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  AppearancePreferenceStorage storage, {
  Locale locale = const Locale('en'),
  double scale = 1,
  bool reducedMotion = false,
  bool reveal = false,
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      appearanceRepositoryProvider.overrideWithValue(
        AppearancePreferencesRepository(storage),
      ),
      appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          final preferences =
              ref.watch(appearanceNotifierProvider).value ??
              AppearancePreferences();
          final app = MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.appearance(preferences, Brightness.light),
            darkTheme: AppTheme.appearance(preferences, Brightness.dark),
            themeMode: ref.watch(flutterThemeModeProvider),
            themeAnimationStyle: reducedMotion
                ? AnimationStyle.noAnimation
                : null,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: reducedMotion,
                textScaler: TextScaler.linear(
                  scale * preferences.fontSize.multiplier,
                ),
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const AppearanceScreen(),
                    ),
                  ),
                  child: const Text('Open appearance'),
                ),
              ),
            ),
          );
          return reveal ? ThemeReveal(child: app) : app;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open appearance'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _editColor(WidgetTester tester, String hex) async {
  await tester.enterText(
    find.byKey(const ValueKey('appearance-color-hex')),
    hex,
  );
  await _tap(tester, find.byKey(const ValueKey('appearance-use-color')));
}

void main() {
  testWidgets('on a tablet the options keep one centred column and the side '
      'margins scroll', (tester) async {
    await _mount(tester, _Storage());
    for (final example in [
      (size: const Size(1205, 753), column: 720.0),
      (size: const Size(753, 1205), column: 640.0),
    ]) {
      tester.view.physicalSize = example.size;
      await tester.pumpAndSettle();
      final scroll = find.byKey(const ValueKey('appearance-scroll'));
      // The scroll view spans the window; the content keeps the column.
      expect(tester.getSize(scroll).width, example.size.width);
      final preview = tester.getRect(find.byType(AppearancePreview));
      expect(preview.width, lessThanOrEqualTo(example.column));
      expect(preview.center.dx, closeTo(example.size.width / 2, 0.5));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'palette preview and common colors are visible before advanced options',
    (tester) async {
      final storage = _Storage();
      await _mount(tester, storage);
      final footerTop = tester
          .getRect(find.byKey(const ValueKey('appearance-apply')))
          .top;
      expect(
        tester.getRect(find.byType(AppearancePreview)).bottom,
        lessThan(footerTop),
      );
      for (final role in ['primary', 'background', 'text']) {
        expect(
          find.byKey(ValueKey('appearance-role-$role')).hitTestable(),
          findsOneWidget,
        );
      }
      expect(storage.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final initialMode in [AppearanceMode.light, AppearanceMode.dark]) {
    for (final reduced in [false, true]) {
      testWidgets(
        'brightness Apply keeps safe editor readable from its first frame ${initialMode.name} reduced=$reduced',
        (tester) async {
          final storage = _Storage()
            ..document = jsonEncode(
              AppearancePreferences(mode: initialMode).toJson(),
            );
          final container = await _mount(
            tester,
            storage,
            reducedMotion: reduced,
          );
          final initialBrightness = initialMode == AppearanceMode.light
              ? Brightness.light
              : Brightness.dark;
          final nextMode = initialMode == AppearanceMode.light
              ? AppearanceMode.dark
              : AppearanceMode.light;
          final scope = find.byKey(const ValueKey('appearance-scope'));
          Color visibleText() => tester
              .widget<RichText>(
                find.descendant(of: scope, matching: find.byType(RichText)),
              )
              .text
              .style!
              .color!;
          final beforeText = visibleText();
          final beforeSurface = Theme.of(
            tester.element(scope),
          ).colorScheme.surface;
          // No settling here: the frames right after the tap are the point.
          final choice = find.byKey(ValueKey('theme-mode-${nextMode.name}'));
          await tester.ensureVisible(choice);
          await tester.pumpAndSettle();
          await tester.tap(choice);
          await tester.pump();
          await tester.pump();
          expect(
            container.read(appearanceNotifierProvider).requireValue.mode,
            nextMode,
          );
          for (final advance in [
            Duration.zero,
            const Duration(milliseconds: 32),
            const Duration(milliseconds: 100),
            const Duration(milliseconds: 150),
          ]) {
            await tester.pump(advance);
            final safe = Theme.of(tester.element(scope));
            expect(safe.brightness, initialBrightness);
            expect(safe.colorScheme.surface, beforeSurface);
            expect(visibleText(), beforeText);
            expect(
              AppTheme.contrast(visibleText(), safe.colorScheme.surface),
              greaterThanOrEqualTo(4.5),
            );
          }
          // Once the app's theme has stood still the editor follows it: it
          // must not stay light in a dark app (or dark in a light one) for as
          // long as the screen is open, as the wide Settings' pane is.
          final nextBrightness = nextMode == AppearanceMode.dark
              ? Brightness.dark
              : Brightness.light;
          await tester.pump(const Duration(milliseconds: 600));
          final followed = Theme.of(tester.element(scope));
          expect(followed.brightness, nextBrightness);
          expect(followed.colorScheme.surface, isNot(beforeSurface));
          expect(
            AppTheme.contrast(visibleText(), followed.colorScheme.surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            Theme.of(
              tester.element(find.byKey(const ValueKey('appearance-apply'))),
            ).brightness,
            nextBrightness,
          );
          await _tap(tester, find.byKey(const ValueKey('appearance-cancel')));
          await _tap(tester, find.text('Open appearance'));
          expect(Theme.of(tester.element(scope)).brightness, nextBrightness);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'preview and Cancel do not save; fictional care is not actionable',
    (tester) async {
      final storage = _Storage();
      final container = await _mount(tester, storage);
      await _tap(tester, find.text('Display options'));
      await _tap(tester, find.byKey(const ValueKey('appearance-dynamic')));
      expect(
        container.read(appearanceNotifierProvider).requireValue.dynamicColor,
        false,
      );
      expect(storage.writes, 0);
      expect(
        find.descendant(
          of: find.byType(AppearancePreview),
          matching: find.byWidgetPredicate(
            (w) => w is ButtonStyleButton || w is IconButton,
          ),
        ),
        findsNothing,
      );
      await _tap(tester, find.byKey(const ValueKey('appearance-cancel')));
      expect(find.text('Open appearance'), findsOneWidget);
      expect(storage.document, isNull);
      expect(storage.writes, 0);
    },
  );

  group('Apply reveal', () {
    final picture = find.byKey(const ValueKey('theme-reveal'));
    final apply = find.byKey(const ValueKey('appearance-apply'));

    /// Taps Apply and gives the engine real time to capture the frame.
    Future<void> tapApply(WidgetTester tester) async {
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }

    testWidgets('a new look spreads out from Apply, then the picture goes', (
      tester,
    ) async {
      final storage = _Storage();
      final container = await _mount(tester, storage, reveal: true);
      await _tap(tester, find.text('Display options'));
      await _tap(tester, find.byKey(const ValueKey('appearance-dynamic')));
      await tapApply(tester);

      expect(picture, findsOneWidget);
      final painter =
          tester.widget<CustomPaint>(picture).painter! as ThemeRevealPainter;
      // From Apply (the save may nudge the layout by a few pixels).
      expect((painter.origin - tester.getCenter(apply)).distance, lessThan(8));

      await tester.pumpAndSettle();
      expect(picture, findsNothing);
      expect(
        container.read(appearanceNotifierProvider).requireValue.dynamicColor,
        true,
      );
      expect(find.textContaining('Appearance saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('applying the look already in use saves without a reveal', (
      tester,
    ) async {
      final storage = _Storage();
      await _mount(tester, storage, reveal: true);
      await tapApply(tester);
      expect(picture, findsNothing);
      await tester.pumpAndSettle();
      expect(find.textContaining('Appearance saved'), findsOneWidget);
    });
  });

  testWidgets(
    'failed Apply retains the applied view and reviewed draft; retry saves it',
    (tester) async {
      final storage = _Storage()..fail = true;
      final container = await _mount(tester, storage);
      await _tap(tester, find.text('Display options'));
      await _tap(tester, find.byKey(const ValueKey('appearance-dynamic')));
      await _tap(tester, find.byKey(const ValueKey('appearance-apply')));
      expect(
        container.read(appearanceNotifierProvider).requireValue.dynamicColor,
        false,
      );
      expect(
        find.text(
          'Appearance not saved. Your previous appearance is still applied. Try again.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('appearance-dynamic')),
            )
            .value,
        true,
      );
      storage.fail = false;
      await _tap(tester, find.byKey(const ValueKey('appearance-apply')));
      expect(
        container.read(appearanceNotifierProvider).requireValue.dynamicColor,
        true,
      );
      expect(find.textContaining('Appearance saved'), findsOneWidget);
      expect(
        (await AppearancePreferencesRepository(storage).load()).dynamicColor,
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'palette switch is labelled as editing and the real theme row is linked',
    (tester) async {
      final storage = _Storage();
      final container = await _mount(tester, storage);
      expect(find.text('Editing palette for:'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('appearance-palette-note')),
        findsOneWidget,
      );
      // The real theme choice is one touch at the top, not a collapsed draft.
      expect(find.byType(ThemeModeSwitch), findsOneWidget);
      expect(
        find.byType(DropdownButtonFormField<AppearanceMode>),
        findsNothing,
      );
      // Switching the palette never changes the app theme mode.
      final before = container.read(appearanceNotifierProvider).requireValue;
      await _tap(tester, find.byKey(const ValueKey('appearance-preview-dark')));
      await _tap(
        tester,
        find.byKey(const ValueKey('appearance-preview-light')),
      );
      expect(
        container.read(appearanceNotifierProvider).requireValue.mode,
        before.mode,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('choosing Light applies at once, survives Apply and a restart', (
    tester,
  ) async {
    final storage = _Storage()
      ..document = jsonEncode(
        AppearancePreferences(mode: AppearanceMode.dark).toJson(),
      );
    final container = await _mount(tester, storage);
    expect(
      container.read(appearanceNotifierProvider).requireValue.mode,
      AppearanceMode.dark,
    );
    await _tap(tester, find.byKey(const ValueKey('theme-mode-light')));
    expect(
      container.read(appearanceNotifierProvider).requireValue.mode,
      AppearanceMode.light,
    );
    expect(jsonDecode(storage.document!)['mode'], 'light');
    // The editor follows the choice: it now edits the light palette.
    expect(
      tester
          .widget<AppearancePreview>(find.byType(AppearancePreview))
          .theme
          .brightness,
      Brightness.light,
    );
    // Another edit and Apply must not put the old theme choice back.
    await _tap(tester, find.text('Display options'));
    await _tap(tester, find.byKey(const ValueKey('appearance-contrast')));
    await _tap(tester, find.byKey(const ValueKey('appearance-apply')));
    final applied = container.read(appearanceNotifierProvider).requireValue;
    expect(applied.mode, AppearanceMode.light);
    expect(applied.highContrast, isTrue);

    // A new session reading the same storage still has Light.
    final restarted = ProviderContainer(
      overrides: [
        appearanceRepositoryProvider.overrideWithValue(
          AppearancePreferencesRepository(storage),
        ),
      ],
    );
    addTearDown(restarted.dispose);
    expect(
      (await restarted.readHeld(appearanceNotifierProvider)).mode,
      AppearanceMode.light,
    );
    expect(restarted.read(flutterThemeModeProvider), ThemeMode.light);
  });

  testWidgets(
    'exact light and dark role edits preview independently before one Apply',
    (tester) async {
      final storage = _Storage();
      final container = await _mount(tester, storage);
      await _tap(
        tester,
        find.byKey(const ValueKey('appearance-role-background')),
      );
      await _editColor(tester, '#E4F2EF');
      expect(
        tester
            .widget<AppearancePreview>(find.byType(AppearancePreview))
            .theme
            .scaffoldBackgroundColor,
        const Color(0xffe4f2ef),
      );
      await _tap(tester, find.byKey(const ValueKey('appearance-preview-dark')));
      await _tap(
        tester,
        find.byKey(const ValueKey('appearance-role-background')),
      );
      await _editColor(tester, '#102C24');
      expect(
        tester
            .widget<AppearancePreview>(find.byType(AppearancePreview))
            .theme
            .scaffoldBackgroundColor,
        const Color(0xff102c24),
      );
      expect(
        container.read(appearanceNotifierProvider).requireValue.lightColors,
        isEmpty,
      );
      expect(storage.writes, 0);
      await _tap(tester, find.byKey(const ValueKey('appearance-apply')));
      final applied = container.read(appearanceNotifierProvider).requireValue;
      expect(applied.lightColors[AppearanceColorRole.background], 0xffe4f2ef);
      expect(applied.darkColors[AppearanceColorRole.background], 0xff102c24);
      expect(storage.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all semantic roles and noninteractive form states remain reachable',
    (tester) async {
      final storage = _Storage();
      final container = await _mount(tester, storage);
      await _tap(tester, find.text('All color controls'));
      for (final section in [
        'Surfaces and text',
        'Actions and accents',
        'Care states and people',
      ]) {
        await _tap(tester, find.text(section));
      }
      for (final role in AppearanceColorRole.values) {
        expect(
          find.byKey(ValueKey('appearance-role-${role.name}')),
          findsOneWidget,
        );
      }
      await _tap(
        tester,
        find.byKey(const ValueKey('appearance-role-inactivePerson')),
      );
      await _editColor(tester, '#445544');
      await _tap(tester, find.byKey(const ValueKey('appearance-preview-dark')));
      expect(
        container.read(appearanceNotifierProvider).requireValue.mode,
        AppearanceMode.system,
      );
      expect(storage.writes, 0);
      await _tap(tester, find.text('Preview forms and states'));
      expect(find.byType(AppearanceFormsPreview), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppearanceFormsPreview),
          matching: find.byWidgetPredicate(
            (w) =>
                w is ButtonStyleButton || w is IconButton || w is EditableText,
          ),
        ),
        findsNothing,
      );
      await _tap(tester, find.byKey(const ValueKey('appearance-apply')));
      final saved = container.read(appearanceNotifierProvider).requireValue;
      expect(saved.mode, AppearanceMode.system);
      expect(saved.lightColors[AppearanceColorRole.inactivePerson], 0xff445544);
      expect(saved.darkColors, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'difficult colors keep recovery controls independently readable; reset touches only appearance',
    (tester) async {
      final difficult = AppearancePreferences(
        lightColors: {
          for (final r in AppearanceColorRole.values) r: 0xffffffff,
        },
      );
      SharedPreferences.setMockInitialValues({
        SharedAppearancePreferenceStorage.key: jsonEncode(difficult.toJson()),
        'fictional_person': 'retained-person',
        'fictional_setup': 'saved-medication',
        'server_url': 'https://retained.example',
        'app_locale': 'ro',
      });
      final prefs = await SharedPreferences.getInstance();
      final container = await _mount(
        tester,
        SharedAppearancePreferenceStorage(
          prefs,
          gate: SerialProjectionEffectsGate(),
        ),
      );
      final cancelContext = tester.element(
        find.byKey(const ValueKey('appearance-cancel')),
      );
      final safe = Theme.of(cancelContext);
      expect(
        AppTheme.contrast(safe.colorScheme.onSurface, safe.colorScheme.surface),
        greaterThanOrEqualTo(7),
      );
      expect(
        AppTheme.contrast(safe.colorScheme.onPrimary, safe.colorScheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      await _tap(tester, find.byKey(const ValueKey('appearance-reset')));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        container.read(appearanceNotifierProvider).requireValue.lightColors,
        isEmpty,
      );
      expect(prefs.getString('fictional_person'), 'retained-person');
      expect(prefs.getString('fictional_setup'), 'saved-medication');
      expect(prefs.getString('server_url'), 'https://retained.example');
      expect(prefs.getString('app_locale'), 'ro');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unreadable saved appearance stays untouched until explicit reset',
    (tester) async {
      final storage = _Storage()..document = '{broken appearance';
      final container = await _mount(tester, storage);
      expect(storage.document, '{broken appearance');
      expect(storage.writes, 0);
      expect(container.read(appearanceNotifierProvider).hasError, true);
      await _tap(
        tester,
        find.widgetWithText(OutlinedButton, 'Restore appearance defaults'),
      );
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        container.read(appearanceNotifierProvider).requireValue.mode,
        AppearanceMode.system,
      );
      expect(storage.writes, 1);
      expect(find.byType(AppearancePreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Romanian 200 percent controls remain reachable and custom preview does not overflow',
    (tester) async {
      final storage = _Storage();
      await _mount(tester, storage, locale: const Locale('ro'), scale: 2);
      await _tap(tester, find.byKey(const ValueKey('appearance-preview-dark')));
      await _tap(tester, find.byKey(const ValueKey('appearance-reset')));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextButton),
        ),
      );
      await _tap(tester, find.byKey(const ValueKey('appearance-cancel')));
      expect(find.text('Open appearance'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
