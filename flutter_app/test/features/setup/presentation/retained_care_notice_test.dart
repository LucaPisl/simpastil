import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/presentation/origin_review_screen.dart';
import 'package:simpastil/features/setup/presentation/care_launch.dart';
import 'package:simpastil/features/setup/presentation/setup_organiser.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import '../../../helpers/protected_workspace_fixture.dart';

class _Auth extends AuthNotifier {
  _Auth(this.initial, {this.confirmResult = const Ok(null)});
  final AuthState initial;
  final Result<void> confirmResult;
  final confirmed = <String>[];
  var loggedOut = 0;

  @override
  AuthState build() => initial;

  @override
  Future<Result<void>> confirmOriginalServer(String reviewedEndpoint) async {
    confirmed.add(reviewedEndpoint);
    return confirmResult;
  }

  @override
  Future<void> logout() async => loggedOut++;
}

Widget _app(ProviderContainer container, Widget home, {String locale = 'en'}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => home),
            GoRoute(
              path: AppPaths.login,
              builder: (_, _) => const Text('LOGIN'),
            ),
            GoRoute(
              path: AppPaths.originReview,
              builder: (_, _) => const Text('REVIEW'),
            ),
            GoRoute(
              path: AppPaths.deviceName,
              builder: (_, _) => const Text('DEVICE'),
            ),
            GoRoute(path: AppPaths.home, builder: (_, _) => const Text('HOME')),
            GoRoute(path: '/settings', builder: (_, _) => const Text('SET')),
          ],
        ),
      ),
    );

void main() {
  group('launch notice for care retained from the previous version', () {
    Future<(ProviderContainer, ProtectedWorkspaceFixture)> setUpLaunch(
      WidgetTester tester, {
      AuthState auth = const AuthUnauthenticated(),
      bool retained = true,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = await ProtectedWorkspaceFixture.create();
      if (retained) {
        final now = DateTime.now().toUtc();
        await fixture.db
            .into(fixture.db.users)
            .insert(
              UsersCompanion.insert(
                id: 'fictional-account',
                email: '',
                createdAt: now,
                updatedAt: now,
              ),
            );
        await fixture.db
            .into(fixture.db.careWorkspaces)
            .insert(
              CareWorkspacesCompanion.insert(
                id: 'retained-ws',
                ownerUserId: 'fictional-account',
                kind: 'connected',
                bindingState: 'unresolved',
                createdAt: now,
              ),
            );
      }
      final container = await fixture.createContainer(
        extraOverrides: [authNotifierProvider.overrideWith(() => _Auth(auth))],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      return (container, fixture);
    }

    testWidgets('replaces onboarding and points at sign-in (English)', (
      tester,
    ) async {
      final (container, _) = await setUpLaunch(tester);
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('retained-care-notice')),
        findsOneWidget,
      );
      expect(
        find.text('Care from your previous version is waiting'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('setup-begin')), findsNothing);
      // Kept care is pictured shut in its organiser, not as a new day.
      expect(
        tester.widget<SetupOrganiser>(find.byType(SetupOrganiser)).filled,
        SetupOrganiser.count,
      );
      expect(find.text('Sign in to your original server'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('retained-care-continue')));
      await tester.pumpAndSettle();
      expect(find.text('LOGIN'), findsOneWidget);
    });

    testWidgets('is available in Romanian', (tester) async {
      final (container, _) = await setUpLaunch(tester);
      await tester.pumpWidget(
        _app(container, const CareLaunch(), locale: 'ro'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Datele din versiunea anterioară te așteaptă'),
        findsOneWidget,
      );
      expect(find.text('Autentifică-te pe serverul inițial'), findsOneWidget);
    });

    testWidgets('after sign-in it leads to the origin review', (tester) async {
      final (container, _) = await setUpLaunch(
        tester,
        auth: const AuthAuthenticated(
          'fictional-account',
          workspaceId: 'retained-ws',
          requiresOriginReview: true,
        ),
      );
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();
      expect(find.text('Review your original server'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retained-care-continue')));
      await tester.pumpAndSettle();
      expect(find.text('REVIEW'), findsOneWidget);
    });

    testWidgets('fresh care on this device remains a choice', (tester) async {
      final (container, _) = await setUpLaunch(tester);
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retained-care-local')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('retained-care-notice')), findsNothing);
      expect(find.byKey(const ValueKey('setup-begin')), findsOneWidget);
    });

    testWidgets('a signed-in account with nobody added is not sent back to '
        'the local-only welcome', (tester) async {
      final (container, _) = await setUpLaunch(
        tester,
        retained: false,
        auth: const AuthAuthenticated(
          'fictional-account',
          workspaceId: 'connected-ws',
        ),
      );
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();
      expect(find.text('You’re connected'), findsOneWidget);
      expect(find.text('Add the first person'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-begin')), findsOneWidget);
      expect(find.text('Connect to a server'), findsNothing);
      expect(find.text('No account or server needed'), findsNothing);
      expect(find.text('Start on this device'), findsNothing);
    });

    testWidgets('Back from the first step returns to the connected welcome, '
        'and a later sign-in does not loop to a stale start page', (
      tester,
    ) async {
      final (container, _) = await setUpLaunch(
        tester,
        retained: false,
        auth: const AuthAuthenticated(
          'fictional-account',
          workspaceId: 'connected-ws',
        ),
      );
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-begin')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('person-name')), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('You’re connected'), findsOneWidget);
      expect(find.text('Connect to a server'), findsNothing);

      // The parked draft survives a restart of the screen (sign-in again).
      container.invalidate(unfinishedSetupDraftProvider);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();
      expect(find.text('You’re connected'), findsOneWidget);
      expect(find.byKey(const ValueKey('person-name')), findsNothing);
    });

    testWidgets('a store with no retained care still starts onboarding', (
      tester,
    ) async {
      final (container, _) = await setUpLaunch(tester, retained: false);
      await tester.pumpWidget(_app(container, const CareLaunch()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('retained-care-notice')), findsNothing);
      expect(find.byKey(const ValueKey('setup-begin')), findsOneWidget);
    });
  });

  group('original server review screen', () {
    const capability = NetworkCapability(
      ownerId: 'fictional-account',
      endpoint: 'https://fictional.test/care',
      epoch: 3,
      generation: 1,
    );
    ProviderContainer container0(_Auth auth) => ProviderContainer(
      overrides: [authNotifierProvider.overrideWith(() => auth)],
    );

    testWidgets('shows the address and confirms exactly that address', (
      tester,
    ) async {
      final auth = _Auth(
        const AuthAuthenticated(
          'fictional-account',
          capability: capability,
          workspaceId: 'retained-ws',
          requiresOriginReview: true,
        ),
      );
      final container = container0(auth);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container, const OriginReviewScreen()));
      await tester.pumpAndSettle();

      expect(find.text('https://fictional.test/care'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('origin-review-confirm')));
      await tester.pumpAndSettle();

      expect(auth.confirmed, ['https://fictional.test/care']);
      expect(find.text('DEVICE'), findsOneWidget);
    });

    testWidgets('a failed review stays on the screen and can be retried', (
      tester,
    ) async {
      final auth = _Auth(
        const AuthAuthenticated(
          'fictional-account',
          capability: capability,
          workspaceId: 'retained-ws',
          requiresOriginReview: true,
        ),
        confirmResult: const Err(UnknownError('x')),
      );
      final container = container0(auth);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container, const OriginReviewScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('origin-review-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text('The review could not be completed. Try again.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('origin-review-confirm')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('declining signs out and confirms nothing', (tester) async {
      final auth = _Auth(
        const AuthAuthenticated(
          'fictional-account',
          capability: capability,
          workspaceId: 'retained-ws',
          requiresOriginReview: true,
        ),
      );
      final container = container0(auth);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container, const OriginReviewScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('origin-review-reject')));
      await tester.pumpAndSettle();
      expect(auth.confirmed, isEmpty);
      expect(auth.loggedOut, 1);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('leaves at once when there is nothing to review', (
      tester,
    ) async {
      final auth = _Auth(const AuthUnauthenticated());
      final container = container0(auth);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container, const OriginReviewScreen()));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });
  });
}
