import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/startup/optional_capability.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/app/simpastil_app.dart';
import 'package:simpastil/shared/app/today_rollover.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/shared/router/app_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'biometric_lock_enabled': false,
      'dynamic_color_enabled': false,
    });
  });

  testWidgets('reduced motion applies the saved theme on its first frame', (
    tester,
  ) async {
    final router = _careRouter();
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        routerProvider.overrideWithValue(router),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
        portablePreferenceGateProvider.overrideWithValue(
          SerialProjectionEffectsGate(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: SimpastilApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const chosen = Color(0xff123456);
    final save = container
        .read(appearanceNotifierProvider.notifier)
        .apply(
          AppearancePreferences(
            lightColors: {AppearanceColorRole.primary: chosen.toARGB32()},
          ),
        );
    await tester.pump();
    await save;
    await tester.pump();
    expect(
      Theme.of(tester.element(find.text('Care route'))).colorScheme.primary,
      chosen,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('keeps the calendar day current above every screen', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('A screen')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routerProvider.overrideWithValue(router),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
        child: const SimpastilApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The routed screen sits below it, so every screen sees the new day.
    expect(
      find.ancestor(
        of: find.text('A screen'),
        matching: find.byType(TodayRollover),
      ),
      findsOneWidget,
    );
  });

  testWidgets('applies saved language, dark mode and combined text scaling', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'biometric_lock_enabled': false,
      'dynamic_color_enabled': false,
      'app_locale': 'ro',
      'app_theme_mode': 'dark',
      'app_font_size': 'extraLarge',
    });
    tester.platformDispatcher.textScaleFactorTestValue = 1.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Text(
              AppLocalizations.of(context).nav_home,
              key: const Key('localized-route'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routerProvider.overrideWithValue(router),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
        child: const SimpastilApp(),
      ),
    );
    await tester.pumpAndSettle();

    final routeContext = tester.element(
      find.byKey(const Key('localized-route')),
    );
    expect(find.text('Acasă'), findsOneWidget);
    expect(Localizations.localeOf(routeContext), const Locale('ro'));
    expect(Theme.of(routeContext).brightness, Brightness.dark);
    expect(
      MediaQuery.textScalerOf(routeContext).scale(10),
      closeTo(15.6, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keeps routed content available during capability failure and retry',
    (tester) async {
      final router = _careRouter();
      addTearDown(router.dispose);
      final container = ProviderContainer(
        overrides: [
          routerProvider.overrideWithValue(router),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
      );
      addTearDown(container.dispose);
      var attempts = 0;
      await container
          .read(optionalCapabilityProvider.notifier)
          .initialize(
            id: 'notifications',
            label: 'Notifications',
            operation: () async {
              attempts++;
              if (attempts == 1) throw StateError('Plugin unavailable');
            },
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SimpastilApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Care route'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsNothing);
      expect(find.text('Care route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('delivers runtime feedback through the supplied messenger key', (
    tester,
  ) async {
    final router = _careRouter();
    addTearDown(router.dispose);
    final messengerKey = GlobalKey<ScaffoldMessengerState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routerProvider.overrideWithValue(router),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
        child: SimpastilApp(scaffoldMessengerKey: messengerKey),
      ),
    );
    await tester.pumpAndSettle();

    expect(messengerKey.currentState, isNotNull);
    messengerKey.currentState!.showSnackBar(
      const SnackBar(content: Text('Session feedback')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Session feedback'), findsOneWidget);
    expect(find.text('Care route'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

GoRouter _careRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const Scaffold(body: Text('Care route')),
    ),
  ],
);
