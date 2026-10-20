import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/network/server_pin_providers.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/features/auth/presentation/forgot_password_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import '../../../helpers/tls_test_server.dart';

Future<void> _pump(
  WidgetTester tester, {
  required EmailResetAvailability availability,
  Locale locale = const Locale('en'),
  Size size = const Size(400, 800),
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ForgotPasswordScreen()),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        emailResetAvailabilityProvider.overrideWith((ref) => availability),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _pinned =
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01';
const _presented =
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:'
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:91';

class _NoTokens extends TokenService {
  @override
  Future<String?> getApiKey() async => null;
  @override
  Future<bool> hasSession() async => false;
}

/// A client whose every request is stopped by a changed server key.
ApiClient _blockedClient() {
  final client = ApiClient(
    baseUrl: 'https://home.example.test:8443/api/v1',
    tokenService: _NoTokens(),
    onAuthFailure: () {},
  );
  client.dio.interceptors.insert(
    0,
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: const CertificatePinMismatch(
            host: 'home.example.test',
            port: 8443,
            pinned: _pinned,
            presented: _presented,
          ),
        ),
      ),
    ),
  );
  addTearDown(() => client.dio.close(force: true));
  return client;
}

void main() {
  for (final (name, size) in [
    ('phone', const Size(400, 800)),
    ('tablet', const Size(1100, 800)),
  ]) {
    testWidgets('a changed server key is shown on the screen on $name', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://home.example.test:8443',
      });
      final prefs = await SharedPreferences.getInstance();
      final pins = SecureServerPinStore(MemorySlots());
      await pins.save(ServerAuthority('home.example.test', 8443), _pinned);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const ForgotPasswordScreen()),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            serverPinStoreProvider.overrideWithValue(pins),
            serverCertificateProbeProvider.overrideWithValue(
              (_) async => const ServerCertificateProbe(
                fingerprint: _presented,
                chainValid: false,
              ),
            ),
            apiClientProvider.overrideWith((ref) => _blockedClient()),
            emailResetAvailabilityProvider.overrideWith(
              (ref) => EmailResetAvailability.available,
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), 'me@example.com');
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pumpAndSettle();

      // No success is claimed, and the reason stays on the screen.
      expect(find.text('Check your email'), findsNothing);
      final notice = find.byKey(const ValueKey('reset-key-blocked'));
      expect(notice, findsOneWidget);
      expect(
        find.descendant(
          of: notice,
          matching: find.textContaining('Server key changed'),
        ),
        findsOneWidget,
      );
      expect(find.text('Review server key'), findsOneWidget);

      // The action opens the key review.
      await tester.tap(find.text('Review server key'));
      await tester.pumpAndSettle();
      expect(find.text('Keep blocked'), findsOneWidget);
    });
  }

  group('parseEmailReset', () {
    test('reads the two defined values', () {
      expect(parseEmailReset('available'), EmailResetAvailability.available);
      expect(
        parseEmailReset('unavailable'),
        EmailResetAvailability.unavailable,
      );
    });

    test('anything else is unknown, never an error', () {
      for (final value in <Object?>[
        null,
        '',
        'Available',
        'maybe',
        true,
        1,
        const <String>[],
      ]) {
        expect(parseEmailReset(value), EmailResetAvailability.unknown);
      }
    });
  });

  for (final (name, size) in [
    ('phone', const Size(400, 800)),
    ('tablet', const Size(1100, 800)),
  ]) {
    for (final (code, locale) in [
      ('en', const Locale('en')),
      ('ro', const Locale('ro')),
    ]) {
      group('ForgotPasswordScreen — $name, $code', () {
        testWidgets('available shows the plain form without a hint', (
          tester,
        ) async {
          await _pump(
            tester,
            availability: EmailResetAvailability.available,
            locale: locale,
            size: size,
          );
          final l = await AppLocalizations.delegate.load(locale);
          expect(find.byType(TextFormField), findsOneWidget);
          expect(find.text(l.auth_sendResetLink), findsOneWidget);
          expect(
            find.byKey(const ValueKey('reset-unknown-hint')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('reset-unavailable')), findsNothing);
        });

        testWidgets('unavailable replaces the form with the admin route', (
          tester,
        ) async {
          await _pump(
            tester,
            availability: EmailResetAvailability.unavailable,
            locale: locale,
            size: size,
          );
          final l = await AppLocalizations.delegate.load(locale);
          expect(
            find.byKey(const ValueKey('reset-unavailable')),
            findsOneWidget,
          );
          expect(find.text(l.auth_resetUnavailableTitle), findsOneWidget);
          expect(find.text(l.auth_resetUnavailableBody), findsOneWidget);
          expect(find.byType(TextFormField), findsNothing);
          expect(find.text(l.auth_sendResetLink), findsNothing);
          expect(find.text(l.auth_backToLogin), findsOneWidget);
        });

        testWidgets('unknown keeps the form and adds a hedged hint', (
          tester,
        ) async {
          await _pump(
            tester,
            availability: EmailResetAvailability.unknown,
            locale: locale,
            size: size,
          );
          final l = await AppLocalizations.delegate.load(locale);
          expect(find.byType(TextFormField), findsOneWidget);
          expect(find.text(l.auth_sendResetLink), findsOneWidget);
          expect(find.text(l.auth_resetUnknownHint), findsOneWidget);
        });
      });
    }
  }

  testWidgets('every state also builds in dark mode', (tester) async {
    for (final state in EmailResetAvailability.values) {
      await _pump(tester, availability: state, dark: true);
      expect(tester.takeException(), isNull);
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    }
  });
}
