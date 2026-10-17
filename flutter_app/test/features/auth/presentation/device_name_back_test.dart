import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/presentation/device_name_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/router/back_policy.dart';

class _Auth extends AuthNotifier {
  var loggedOut = 0;
  @override
  AuthState build() => const AuthAuthenticated('fictional-account');
  @override
  Future<void> logout() async => loggedOut++;
}

void main() {
  testWidgets('Back on the device name page goes Today and keeps the sign-in', (
    tester,
  ) async {
    final auth = _Auth();
    final container = ProviderContainer(
      overrides: [authNotifierProvider.overrideWith(() => auth)],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: AppPaths.deviceName,
      routes: [
        GoRoute(path: AppPaths.home, builder: (_, _) => const Text('TODAY')),
        GoRoute(path: AppPaths.login, builder: (_, _) => const Text('SIGN IN')),
        GoRoute(
          path: AppPaths.deviceName,
          builder: (_, _) =>
              const HomeFallbackPop(child: DeviceNameScreen(prefill: 'Phone')),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(router.canPop(), isFalse);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('SIGN IN'), findsNothing);
    expect(auth.loggedOut, 0);
    expect(container.read(authNotifierProvider), isA<AuthAuthenticated>());
  });
}
