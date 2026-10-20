import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/features/auth/presentation/device_name_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../../helpers/fake_auth_repository.dart';

void main() {
  testWidgets('renders text field pre-filled with device name', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => const DeviceNameScreen(prefill: 'Pixel 9'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets(
    'keeps failed rename on screen and leaves the cached name alone',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'simpastil_device_name': 'Previous device',
      });
      final repository = FakeAuthRepository()
        ..setDeviceNameFuture = Future.value(
          const Err(NetworkError('offline')),
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, _) =>
                      const DeviceNameScreen(prefill: 'New device'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.byType(DeviceNameScreen), findsOneWidget);
      expect(repository.deviceNameAttempts, ['New device']);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'simpastil_device_name',
        ),
        'Previous device',
      );
    },
  );

  group('re-sign-in on a device that already has a name', () {
    Future<FakeAuthRepository> pump(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      Future<Result<void>>? result,
      Size size = const Size(400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(prefs);
      final repository = FakeAuthRepository();
      if (result != null) repository.setDeviceNameFuture = result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, _) => DeviceNameScreen(
                    deviceModel: () async => 'sdk_gphone64_x86_64',
                  ),
                ),
                GoRoute(
                  path: '/home',
                  builder: (_, _) => const Scaffold(body: Text('HOME')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets('prefills the saved name, not the model, on $name', (
        tester,
      ) async {
        await pump(
          tester,
          size: size,
          prefs: {'simpastil_device_name': 'Kitchen tablet'},
        );
        expect(find.text('Kitchen tablet'), findsOneWidget);
        expect(find.text('sdk_gphone64_x86_64'), findsNothing);
      });

      testWidgets('skipping sends the saved name for the new session on '
          '$name', (tester) async {
        final repository = await pump(
          tester,
          size: size,
          prefs: {'simpastil_device_name': 'Kitchen tablet'},
        );
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();
        expect(repository.deviceNameAttempts, ['Kitchen tablet']);
        expect(find.text('HOME'), findsOneWidget);
      });
    }

    testWidgets('suggests the model for a device that was never named', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('sdk_gphone64_x86_64'), findsOneWidget);
    });

    testWidgets('skipping with no saved name sends nothing', (tester) async {
      final repository = await pump(tester);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(repository.deviceNameAttempts, isEmpty);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('a failing request on skip never holds the person here', (
      tester,
    ) async {
      final repository = await pump(
        tester,
        prefs: {'simpastil_device_name': 'Kitchen tablet'},
        result: Future.value(const Err(NetworkError('offline'))),
      );
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(repository.deviceNameAttempts, ['Kitchen tablet']);
      expect(find.text('HOME'), findsOneWidget);
    });
  });
}
