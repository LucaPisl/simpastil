import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/auth/auth_event_provider.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/shared/app/simpastil_app.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/shared/router/app_router.dart';

const _sessionA = NetworkCapability(
  ownerId: 'account-a',
  endpoint: 'https://care.example',
  epoch: 1,
  generation: 1,
);
const _sessionB = NetworkCapability(
  ownerId: 'account-b',
  endpoint: 'https://care.example',
  epoch: 3,
  generation: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'biometric_lock_enabled': false,
      'dynamic_color_enabled': false,
    });
  });

  for (final entry in {
    'en': 'Session expired. Please log in again.',
    'ro': 'Sesiunea a expirat. Te rugăm să te conectezi din nou.',
  }.entries) {
    testWidgets('accepted expiry shows localized feedback in ${entry.key}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'biometric_lock_enabled': false,
        'dynamic_color_enabled': false,
        'app_locale': entry.key,
      });
      final fixture = _Fixture(await SharedPreferences.getInstance());
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();

      fixture.expire(_sessionA);
      await tester.pump();
      expect(fixture.auth.clearCalls, 1);
      expect(fixture.auth.capturedFailure, _sessionA);
      expect(find.text('Care route'), findsOneWidget);
      fixture.auth.finish(accepted: true);
      await tester.pumpAndSettle();

      expect(find.text('Login route'), findsOneWidget);
      expect(find.text(entry.value), findsOneWidget);
      expect(fixture.container.read(authEventProvider), AuthEvent.none);
      // The sign-in step keeps a note after the snackbar is gone.
      expect(fixture.container.read(signedOutNoticeProvider), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in {
    'en': 'Dose Reminders',
    'ro': 'Memento-uri medicamente',
  }.entries) {
    testWidgets(
      'startup receives saved ${entry.key} labels once after render',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'biometric_lock_enabled': false,
          'dynamic_color_enabled': false,
          'app_locale': entry.key,
        });
        final fixture = _Fixture(await SharedPreferences.getInstance());
        addTearDown(fixture.dispose);
        final labels = <String>[];
        Widget app() => UncontrolledProviderScope(
          container: fixture.container,
          child: SimpastilApp(
            onLocalizationsReady: (localizations) {
              expect(find.text('Care route'), findsOneWidget);
              expect(localizations.localeName, entry.key);
              labels.add(localizations.core_notifChannelName);
            },
          ),
        );

        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();

        expect(labels, [entry.value]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('rejected old expiry preserves the newer session and snackbar', (
    tester,
  ) async {
    final fixture = _Fixture(await SharedPreferences.getInstance());
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();
    fixture.expire(_sessionA);
    await tester.pump();
    expect(fixture.auth.clearCalls, 1);
    fixture.auth.authenticate(_sessionB);
    fixture.showCurrentFeedback();
    await tester.pumpAndSettle();
    fixture.auth.finish(accepted: false);
    await tester.pumpAndSettle();

    expect(find.text('Care route'), findsOneWidget);
    expect(find.text('Login route'), findsNothing);
    expect(find.text('New session feedback'), findsOneWidget);
    expect(fixture.container.read(signedOutNoticeProvider), isFalse);
    expect(
      fixture.container.read(authNotifierProvider),
      isA<AuthAuthenticated>().having(
        (state) => state.capability,
        'capability',
        _sessionB,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'new authentication after accepted clear suppresses old feedback',
    (tester) async {
      final fixture = _Fixture(await SharedPreferences.getInstance());
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      fixture.expire(_sessionA);
      await tester.pump();
      expect(fixture.auth.clearCalls, 1);
      // The protected clear succeeds, then a new login publishes before the
      // awaiting presentation callback resumes.
      fixture.auth.finish(accepted: true);
      fixture.auth.authenticate(_sessionB);
      fixture.showCurrentFeedback();
      await tester.pumpAndSettle();

      expect(find.text('Care route'), findsOneWidget);
      expect(find.text('Login route'), findsNothing);
      expect(find.text('New session feedback'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed session clearing preserves the screen and feedback', (
    tester,
  ) async {
    final fixture = _Fixture(await SharedPreferences.getInstance());
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();
    fixture.showCurrentFeedback();
    fixture.expire(_sessionA);
    await tester.pump();
    fixture.auth.fail();
    await tester.pumpAndSettle();

    expect(find.text('Care route'), findsOneWidget);
    expect(find.text('New session feedback'), findsOneWidget);
    expect(find.text('Session expired. Please log in again.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expiry completion after app disposal has no UI effects', (
    tester,
  ) async {
    final fixture = _Fixture(await SharedPreferences.getInstance());
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();
    fixture.expire(_sessionA);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.auth.finish(accepted: true);
    await tester.pumpAndSettle();

    expect(fixture.router.routeInformationProvider.value.uri.path, '/');
    expect(tester.takeException(), isNull);
  });
}

class _ControlledAuthNotifier extends AuthNotifier {
  final _result = Completer<bool>();
  int clearCalls = 0;
  NetworkCapability? capturedFailure;

  @override
  AuthState build() =>
      const AuthAuthenticated('account-a', capability: _sessionA);

  @override
  Future<bool> clearSession() {
    clearCalls++;
    capturedFailure = ref.read(authFailureCapabilityProvider);
    ref.read(authFailureCapabilityProvider.notifier).state = null;
    return _result.future;
  }

  void authenticate(NetworkCapability capability) {
    state = AuthAuthenticated(capability.ownerId, capability: capability);
  }

  void finish({required bool accepted}) {
    if (accepted) state = const AuthUnauthenticated();
    _result.complete(accepted);
  }

  void fail() => _result.completeError(StateError('Protected clear failed'));
}

class _Fixture {
  _Fixture(SharedPreferences preferences) {
    container = ProviderContainer(
      overrides: [
        routerProvider.overrideWithValue(router),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authNotifierProvider.overrideWith(() => auth),
      ],
    );
  }

  final auth = _ControlledAuthNotifier();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: Text('Care route')),
      ),
      GoRoute(
        path: AppPaths.login,
        builder: (context, state) => const Scaffold(body: Text('Login route')),
      ),
    ],
  );
  late final ProviderContainer container;

  Widget get widget => UncontrolledProviderScope(
    container: container,
    child: SimpastilApp(scaffoldMessengerKey: messenger),
  );

  void expire(NetworkCapability capability) {
    container.read(authFailureCapabilityProvider.notifier).state = capability;
    container.read(authEventProvider.notifier).state = AuthEvent.sessionExpired;
  }

  void showCurrentFeedback() {
    messenger.currentState!.showSnackBar(
      const SnackBar(
        content: Text('New session feedback'),
        duration: Duration(minutes: 1),
      ),
    );
  }

  void dispose() {
    router.dispose();
    container.dispose();
  }
}
