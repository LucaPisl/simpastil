import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/installation_key_repository.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/features/auth/presentation/server_picker_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../../helpers/fake_auth_repository.dart';

// Health check stubs
Future<bool> _alwaysOk(String _) async => true;
Future<bool> _alwaysFail(String _) async => false;

Future<Widget> buildScreen({
  required SharedPreferences prefs,
  Future<bool> Function(String) healthCheck = _alwaysOk,
  FakeAuthRepository? fakeAuth,
  String? restoredStatus,
}) async => (await _ScreenFixture.create(
  prefs: prefs,
  healthCheck: healthCheck,
  fakeAuth: fakeAuth,
  restoredStatus: restoredStatus,
)).widget;

/// Restore an installation-bound key with protected verification metadata.
Future<void> _pumpCredentialsPhase(
  WidgetTester tester, {
  FakeAuthRepository? fakeAuth,
  String status = 'owned',
}) async {
  SharedPreferences.setMockInitialValues({
    'server_url': 'https://test.example.com',
  });
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    await buildScreen(prefs: prefs, fakeAuth: fakeAuth, restoredStatus: status),
  );
  await tester.pumpAndSettle();
}

Future<void> _fillCredentials(WidgetTester tester) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.first, 'user@example.com');
  await tester.enterText(fields.at(1), 'a-long-password');
}

class _MemorySlots implements CredentialSlotStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _ScreenFixture {
  _ScreenFixture._(
    this.container,
    this.db,
    this.access,
    this.keys,
    this.clients,
  );
  final ProviderContainer container;
  final AppDatabase db;
  final WorkspaceAccessRepository access;
  final InstallationKeyRepository keys;
  final List<ApiClient> clients;

  static Future<_ScreenFixture> create({
    required SharedPreferences prefs,
    Future<bool> Function(String) healthCheck = _alwaysOk,
    FakeAuthRepository? fakeAuth,
    String? restoredStatus,
    bool configured = false,
    bool versionOneKey = false,
    Future<Object> Function(RequestOptions)? verify,
    Future<void> Function()? afterVerification,
  }) async {
    final db = AppDatabase.forTesting();
    final access = WorkspaceAccessRepository(
      db,
      effectsGate: SerialProjectionEffectsGate(),
    );
    final store = _MemorySlots();
    final keys = InstallationKeyRepository(access: access, store: store);
    final credentials = ProtectedCredentialsRepository(
      access: access,
      store: store,
    );
    if (configured || restoredStatus != null || versionOneKey) {
      final endpoint = prefs.getString('server_url')!;
      await access.configureEndpoint(endpoint);
      if (restoredStatus != null || versionOneKey) {
        await keys.saveFor(
          (await access.captureInstallation(endpoint))!,
          'fictional-restored-key',
          verifiedStatus: restoredStatus,
        );
      }
    }
    final generations = SessionGenerationRepository(prefs, access: access);
    final clients = <ApiClient>[];
    final repository = fakeAuth ?? FakeAuthRepository();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        workspaceAccessRepositoryProvider.overrideWithValue(access),
        sharedPreferencesProvider.overrideWithValue(prefs),
        installationKeyRepositoryProvider.overrideWithValue(keys),
        protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
        authTransitionRepositoryFactoryProvider.overrideWithValue(
          (_) => repository,
        ),
        serverHealthCheckProvider.overrideWithValue(healthCheck),
        sessionGenerationRepositoryProvider.overrideWithValue(generations),
        sessionRuntimeCoordinatorProvider.overrideWithValue(
          SessionRuntimeCoordinator(
            generations: generations,
            access: access,
            startSync: (_, _) {},
            stopSync: () {},
          ),
        ),
        apiClientProvider.overrideWith((ref) {
          final tokens = createScopedTokenService(ref);
          final endpoint = ref.watch(serverConfigProvider);
          final client = ApiClient(
            baseUrl: endpoint == null ? '' : '$endpoint/api/v1',
            tokenService: tokens,
            onAuthFailure: () {},
          );
          client.dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) async {
                final data =
                    await (verify?.call(options) ??
                        Future<Object>.value({'status': 'owned'}));
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: data,
                  ),
                  true,
                );
              },
              onResponse: (response, handler) async {
                await afterVerification?.call();
                handler.next(response);
              },
            ),
          );
          clients.add(client);
          return client;
        }),
      ],
    );
    final fixture = _ScreenFixture._(container, db, access, keys, clients);
    addTearDown(() async {
      container.dispose();
      for (final client in clients) {
        client.dio.close(force: true);
      }
      await db.close();
    });
    return fixture;
  }

  Widget get widget => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ServerPickerScreen(),
    ),
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  group('ServerPickerScreen — protected installation', () {
    testWidgets('verification saves protected status with the captured key', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://test.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        configured: true,
      );
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'fictional-key-a');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
      await tester.pumpAndSettle();

      final scope = (await fixture.access.captureInstallation(
        'https://test.example.com',
      ))!;
      expect(await fixture.keys.readFor(scope), 'fictional-key-a');
      expect(await fixture.keys.readVerifiedStatusFor(scope), 'owned');
      expect(find.widgetWithText(FilledButton, 'LOG IN'), findsOneWidget);
      expect(prefs.getString('api_key_status'), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'unbound URL, key and status cannot restore the account phase',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'api_key': 'fictional-legacy-key',
        });
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
          'api_key_status': 'owned',
        });
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(await buildScreen(prefs: prefs));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
        expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'bound key without protected verification status requires verification',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
          'api_key_status': 'owned',
        });
        final prefs = await SharedPreferences.getInstance();
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          versionOneKey: true,
        );
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
        expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'late A verification cannot advance or overwrite installation B',
      (tester) async {
        const a = 'https://test.example.com/InstallA';
        const b = 'https://test.example.com/InstallB';
        SharedPreferences.setMockInitialValues({'server_url': a});
        final prefs = await SharedPreferences.getInstance();
        final responseReady = Completer<void>();
        final release = Completer<void>();
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          configured: true,
          afterVerification: () async {
            responseReady.complete();
            await release.future;
          },
        );
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'fictional-key-a');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
        for (var frame = 0; frame < 20 && !responseReady.isCompleted; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(responseReady.isCompleted, isTrue);
        await fixture.container.read(serverConfigProvider.notifier).setUrl(b);
        final bScope = await fixture.keys.saveFor(
          (await fixture.access.captureInstallation(b))!,
          'fictional-key-b',
          verifiedStatus: 'unclaimed',
        );
        await tester.pump();
        release.complete();
        await tester.pumpAndSettle();

        expect(await fixture.access.installationIsCurrent(bScope), isTrue);
        expect(await fixture.keys.readFor(bScope), 'fictional-key-b');
        expect(await fixture.keys.readVerifiedStatusFor(bScope), 'unclaimed');
        expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsNothing);
        expect(find.text('Could not reach server.'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final leaveScreen in [false, true]) {
      testWidgets(
        leaveScreen
            ? 'verification completion after disposal does not use the old UI'
            : 'Change keeps the server phase when verification finishes late',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'server_url': 'https://test.example.com',
          });
          final prefs = await SharedPreferences.getInstance();
          final responseReady = Completer<void>();
          final release = Completer<void>();
          final fixture = await _ScreenFixture.create(
            prefs: prefs,
            configured: true,
            afterVerification: () async {
              responseReady.complete();
              await release.future;
            },
          );
          await tester.pumpWidget(fixture.widget);
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'fictional-key-a');
          await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
          for (
            var frame = 0;
            frame < 20 && !responseReady.isCompleted;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          expect(responseReady.isCompleted, isTrue);
          if (leaveScreen) {
            await tester.pumpWidget(const SizedBox.shrink());
          } else {
            await tester.tap(find.text('Change'));
            await tester.pump();
          }
          release.complete();
          await tester.pumpAndSettle();

          expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsNothing);
          if (!leaveScreen) {
            expect(
              find.widgetWithText(FilledButton, 'Connect'),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final entry in {
      'revoked': 'This API key has been revoked. Contact your admin.',
      'future-status': 'Unexpected server response.',
    }.entries) {
      testWidgets('retains the ${entry.key} verification error message', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          configured: true,
          verify: (_) async => {'status': entry.key},
        );
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'fictional-key-a');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
        expect(
          (await fixture.access.workspaces.deviceState()).installationKeyId,
          isNull,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
  group('ServerPickerScreen — Phase 1', () {
    testWidgets('shows Connect button disabled when URL field is empty', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));

      final connectBtn = find.widgetWithText(FilledButton, 'Connect');
      expect(connectBtn, findsOneWidget);
      expect(tester.widget<FilledButton>(connectBtn).onPressed, isNull);
    });

    testWidgets('Connect button enabled when valid https:// URL entered', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));

      await tester.enterText(
        find.byType(TextFormField),
        'https://mypills.example.com',
      );
      await tester.pump();

      final connectBtn = find.widgetWithText(FilledButton, 'Connect');
      expect(tester.widget<FilledButton>(connectBtn).onPressed, isNotNull);
    });

    testWidgets('shows HTTPS error for http:// URL', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));

      await tester.enterText(
        find.byType(TextFormField),
        'http://plain.example.com',
      );
      await tester.pump();

      expect(find.text('Server address must use HTTPS.'), findsOneWidget);
      final connectBtn = find.widgetWithText(FilledButton, 'Connect');
      expect(tester.widget<FilledButton>(connectBtn).onPressed, isNull);
    });

    testWidgets('pre-fills URL when serverConfigProvider has a stored value', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://stored.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));
      await tester.pump();

      final field = find.byType(TextFormField).first;
      expect(
        tester.widget<TextFormField>(field).controller?.text,
        'https://stored.example.com',
      );
    });

    testWidgets(
      'Phase 1 is shown even when a URL is stored — no fast-path to Phase 2',
      (tester) async {
        // Spec: "There is no fast-path to Phase 2 based on a stored URL alone"
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://stored.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(await buildScreen(prefs: prefs));
        await tester.pump();

        // Phase 1 UI elements present
        expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
        // Phase 2 UI elements absent
        expect(find.text('Sign in'), findsNothing);
      },
    );

    testWidgets('shows inline error on health check failure', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        await buildScreen(prefs: prefs, healthCheck: _alwaysFail),
      );

      await tester.enterText(
        find.byType(TextFormField),
        'https://unreachable.example.com',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not reach server — check the address and try again.'),
        findsOneWidget,
      );
    });

    testWidgets('transitions to API key phase after health check success', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));

      await tester.enterText(
        find.byType(TextFormField),
        'https://mypills.example.com',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      // Phase 2 (API key) is visible
      expect(find.text('Enter your API key'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Verify key'), findsOneWidget);
      // Credentials not yet visible
      expect(find.text('Sign in'), findsNothing);
      expect(find.text('Create account'), findsNothing);
    });

    testWidgets('Change link returns to Phase 1', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));

      await tester.enterText(
        find.byType(TextFormField),
        'https://mypills.example.com',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      // Now in Phase 2 (API key) — tap Change to go back to Phase 1
      await tester.tap(find.text('Change'));
      await tester.pump();

      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    });
  });

  group('ServerPickerScreen — Phase 3 autofill', () {
    testWidgets('credentials form is wrapped in AutofillGroup', (tester) async {
      await _pumpCredentialsPhase(tester); // allow _restorePhase() to complete

      expect(find.byType(AutofillGroup), findsOneWidget);
    });

    testWidgets('sign-in email carries username and email autofill hints', (
      tester,
    ) async {
      await _pumpCredentialsPhase(tester);

      // TextFormField passes autofillHints to its internal TextField.
      // The email field is the first TextField in Phase 3.
      final emailField = tester
          .widgetList<TextField>(find.byType(TextField))
          .first;
      expect(
        emailField.autofillHints,
        orderedEquals([AutofillHints.username, AutofillHints.email]),
      );
    });

    testWidgets('password field carries AutofillHints.password for login', (
      tester,
    ) async {
      await _pumpCredentialsPhase(tester);

      // The password field is the second TextField in Phase 3.
      final passwordField = tester
          .widgetList<TextField>(find.byType(TextField))
          .elementAt(1);
      expect(passwordField.autofillHints, contains(AutofillHints.password));
    });
  });

  group('ServerPickerScreen — Phase 3 mode toggle', () {
    testWidgets(
      'defaults to Sign in for an owned key, with both modes offered',
      (tester) async {
        await _pumpCredentialsPhase(tester);

        expect(find.byType(SegmentedButton<bool>), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'LOG IN'), findsOneWidget);
        expect(
          find.text('Create account'),
          findsOneWidget,
        ); // the other segment
        expect(find.text('Forgot password?'), findsOneWidget);
      },
    );

    testWidgets('switching to Create account swaps the form', (tester) async {
      await _pumpCredentialsPhase(tester);

      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'CREATE ACCOUNT'),
        findsOneWidget,
      );
      expect(find.text('Forgot password?'), findsNothing);
      final emailField = tester
          .widgetList<TextField>(find.byType(TextField))
          .first;
      expect(
        emailField.autofillHints,
        orderedEquals([AutofillHints.newUsername, AutofillHints.email]),
      );
      final passwordField = tester
          .widgetList<TextField>(find.byType(TextField))
          .elementAt(1);
      expect(passwordField.autofillHints, contains(AutofillHints.newPassword));
    });

    testWidgets('switching back restores the sign-in form', (tester) async {
      await _pumpCredentialsPhase(tester);

      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'LOG IN'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
      final emailField = tester
          .widgetList<TextField>(find.byType(TextField))
          .first;
      expect(
        emailField.autofillHints,
        orderedEquals([AutofillHints.username, AutofillHints.email]),
      );
    });

    testWidgets('step indicator names the current phase', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));
      expect(find.text('STEP 1 OF 3 — SERVER'), findsOneWidget);
    });

    testWidgets('credentials phase shows step 3 and a back-to-key affordance', (
      tester,
    ) async {
      await _pumpCredentialsPhase(tester);
      expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);

      final backBtn = find.text('Use a different API key');
      await tester.ensureVisible(backBtn);
      await tester.tap(backBtn);
      await tester.pumpAndSettle();

      expect(find.text('Enter your API key'), findsOneWidget);
      expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
    });

    testWidgets('register conflict shows the linked-key message', (
      tester,
    ) async {
      final fakeAuth = FakeAuthRepository()
        ..registerFuture = Future.value(const Err<void>(ConflictError()));
      await _pumpCredentialsPhase(tester, fakeAuth: fakeAuth);

      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      await _fillCredentials(tester);
      final createBtn = find.widgetWithText(FilledButton, 'CREATE ACCOUNT');
      await tester.ensureVisible(createBtn);
      await tester.tap(createBtn);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('already linked to an account'),
        findsOneWidget,
      );
    });

    testWidgets('sign-in 403 shows the different-account message', (
      tester,
    ) async {
      final fakeAuth = FakeAuthRepository()
        ..loginFuture = Future.value(const Err<LoginResult>(ServerError(403)));
      await _pumpCredentialsPhase(tester, fakeAuth: fakeAuth);

      await _fillCredentials(tester);
      final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
      await tester.ensureVisible(loginBtn);
      await tester.tap(loginBtn);
      await tester.pumpAndSettle();

      expect(
        find.text('This API key belongs to a different account.'),
        findsOneWidget,
      );
    });

    testWidgets('restored unclaimed key defaults to Create account', (
      tester,
    ) async {
      await _pumpCredentialsPhase(tester, status: 'unclaimed');

      expect(
        find.widgetWithText(FilledButton, 'CREATE ACCOUNT'),
        findsOneWidget,
      );
    });

    testWidgets('switching modes clears a previous error message', (
      tester,
    ) async {
      final fakeAuth = FakeAuthRepository()
        ..loginFuture = Future.value(const Err<LoginResult>(ServerError(403)));
      await _pumpCredentialsPhase(tester, fakeAuth: fakeAuth);

      await _fillCredentials(tester);
      final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
      await tester.ensureVisible(loginBtn);
      await tester.tap(loginBtn);
      await tester.pumpAndSettle();
      expect(
        find.text('This API key belongs to a different account.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(
        find.text('This API key belongs to a different account.'),
        findsNothing,
      );
    });
  });
}
