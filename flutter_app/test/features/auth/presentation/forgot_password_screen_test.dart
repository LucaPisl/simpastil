import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/features/auth/presentation/forgot_password_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

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

void main() {
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
