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
}
