import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/features/settings/presentation/theme_mode_switch.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/motion/theme_reveal.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

class _Storage implements AppearancePreferenceStorage {
  _Storage(AppearanceMode mode)
    : document = jsonEncode(AppearancePreferences(mode: mode).toJson());
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
  final picture = find.byKey(const ValueKey('theme-reveal'));

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    AppearanceMode mode = AppearanceMode.light,
    bool reveal = true,
    double scale = 1,
    _Storage? storage,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appearanceRepositoryProvider.overrideWithValue(
          AppearancePreferencesRepository(storage ?? _Storage(mode)),
        ),
        appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    final app = Consumer(
      builder: (context, ref, _) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ref.watch(flutterThemeModeProvider),
        themeAnimationStyle: AnimationStyle.noAnimation,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: 380, child: ThemeModeRow()),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: reveal ? ThemeReveal(child: app) : app,
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder segment(AppearanceMode mode) =>
      find.byKey(ValueKey('theme-mode-${mode.name}'));

  AppearanceMode applied(ProviderContainer container) =>
      container.read(appearanceNotifierProvider).requireValue.mode;

  Brightness shown(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(ThemeModeRow))).brightness;

  /// Taps and gives the engine real time to capture the frame.
  Future<void> tapAndCapture(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  testWidgets('says which of the three is in use', (tester) async {
    await mount(tester, mode: AppearanceMode.dark);
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(segment(AppearanceMode.dark)),
      matchesSemantics(
        label: 'Dark',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    expect(
      tester.getSemantics(segment(AppearanceMode.light)),
      matchesSemantics(
        label: 'Light',
        isButton: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('dark spreads out from the moon, and the thumb follows', (
    tester,
  ) async {
    final container = await mount(tester);
    final thumb = find.byKey(const ValueKey('theme-mode-thumb'));
    expect(
      tester.getCenter(thumb).dx,
      tester.getCenter(segment(AppearanceMode.light)).dx,
    );

    await tapAndCapture(tester, segment(AppearanceMode.dark));
    expect(applied(container), AppearanceMode.dark);
    expect(picture, findsOneWidget);
    final painter =
        tester.widget<CustomPaint>(picture).painter! as ThemeRevealPainter;
    expect(painter.origin, tester.getCenter(segment(AppearanceMode.dark)));

    await tester.pumpAndSettle();
    expect(picture, findsNothing);
    expect(shown(tester), Brightness.dark);
    expect(
      tester.getCenter(thumb).dx,
      moreOrLessEquals(tester.getCenter(segment(AppearanceMode.dark)).dx),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a choice that looks the same changes without a reveal', (
    tester,
  ) async {
    // The test platform is light, so Auto looks like Light.
    final container = await mount(tester);
    await tapAndCapture(tester, segment(AppearanceMode.system));
    expect(applied(container), AppearanceMode.system);
    expect(picture, findsNothing);
    await tester.pumpAndSettle();
    expect(shown(tester), Brightness.light);
  });

  testWidgets('without a reveal above it the choice still applies', (
    tester,
  ) async {
    final container = await mount(tester, reveal: false);
    await tester.tap(segment(AppearanceMode.dark));
    await tester.pumpAndSettle();
    expect(applied(container), AppearanceMode.dark);
    expect(shown(tester), Brightness.dark);
  });

  testWidgets('a choice that cannot be saved says so', (tester) async {
    final storage = _Storage(AppearanceMode.light)..fail = true;
    final container = await mount(tester, reveal: false, storage: storage);
    await tester.tap(segment(AppearanceMode.dark));
    await tester.pumpAndSettle();
    expect(applied(container), AppearanceMode.light);
    expect(
      find.text(
        'Appearance not saved. Your previous appearance is still applied. Try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('large text puts the switch under its name', (tester) async {
    await mount(tester, scale: 2);
    expect(
      tester.getTopLeft(segment(AppearanceMode.light)).dy,
      greaterThan(tester.getBottomLeft(find.text('Theme')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
