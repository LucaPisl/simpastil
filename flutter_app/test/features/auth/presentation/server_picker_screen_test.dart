import 'dart:io';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/auth_event_provider.dart';
import 'package:simpastil/core/auth/installation_key_repository.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/network/server_pin_controller.dart';
import 'package:simpastil/core/network/server_pin_providers.dart';
import 'package:simpastil/core/network/server_pin_store.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/features/auth/presentation/server_picker_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../../helpers/fake_auth_repository.dart';

const _fingerprintA =
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01';
const _fingerprintB =
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:'
    'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:91';

/// A handshake probe that never touches the network.
ServerCertificateProber _probe({
  String fingerprint = _fingerprintA,
  bool chainValid = true,
  bool fails = false,
}) =>
    (authority) async => fails
    ? throw const HandshakeException('unreachable')
    : ServerCertificateProbe(fingerprint: fingerprint, chainValid: chainValid);

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
    this.credentials,
    this.clients,
  );
  final ProviderContainer container;
  final AppDatabase db;
  final WorkspaceAccessRepository access;
  final InstallationKeyRepository keys;
  final ProtectedCredentialsRepository credentials;
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
    ServerCertificateProber? probe,
    ServerPinStore? pins,
    bool staleFirstScope = false,
    bool staleForever = false,
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
    // An unlistened provider pauses and keeps its last row. This hands the
    // first connection that row, even after the installation has moved on.
    final frozenRow = (staleFirstScope || staleForever)
        ? await db.select(db.workspaceDeviceStates).getSingleOrNull()
        : null;
    var deviceStateBuilds = 0;
    final repository = fakeAuth ?? FakeAuthRepository();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (staleFirstScope || staleForever)
          connectionDeviceStateProvider.overrideWith((ref) {
            if (staleForever || deviceStateBuilds++ == 0) {
              return Stream.value(frozenRow);
            }
            return (db.select(
              db.workspaceDeviceStates,
            )..where((row) => row.id.equals('device'))).watchSingleOrNull();
          }),
        workspaceAccessRepositoryProvider.overrideWithValue(access),
        sharedPreferencesProvider.overrideWithValue(prefs),
        installationKeyRepositoryProvider.overrideWithValue(keys),
        protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
        authTransitionRepositoryFactoryProvider.overrideWithValue(
          (_) => repository,
        ),
        serverHealthCheckProvider.overrideWithValue(healthCheck),
        serverCertificateProbeProvider.overrideWithValue(probe ?? _probe()),
        serverPinStoreProvider.overrideWithValue(
          pins ?? SecureServerPinStore(_MemorySlots()),
        ),
        sessionGenerationRepositoryProvider.overrideWithValue(generations),
        sessionRemoteRevocationProvider.overrideWithValue((_, _) async {}),
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
    final fixture = _ScreenFixture._(
      container,
      db,
      access,
      keys,
      credentials,
      clients,
    );
    addTearDown(() async {
      container.dispose();
      for (final client in clients) {
        client.dio.close(force: true);
      }
      await db.close();
    });
    return fixture;
  }

  Locale? locale;

  Widget get widget => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ServerPickerScreen(),
    ),
  );
}

/// A restored key opens the account step; the key step is one tap back.
Future<void> _toKeyStep(WidgetTester tester) async {
  final back = find.text('Use a different API key');
  await tester.ensureVisible(back);
  await tester.tap(back);
  await tester.pumpAndSettle();
  expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
}

/// Pumps until pending futures and route animations finish. A plain
/// `pumpAndSettle` never returns while the Connect button shows its spinner.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('ServerPickerScreen — server key', () {
    Future<_ScreenFixture> pump(
      WidgetTester tester, {
      ServerCertificateProber? probe,
      ServerPinStore? pins,
      Future<bool> Function(String) healthCheck = _alwaysOk,
    }) async {
      tester.view.physicalSize = const Size(900, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        healthCheck: healthCheck,
        probe: probe,
        pins: pins,
      );
      await tester.pumpWidget(fixture.widget);
      await tester.enterText(
        find.byType(TextFormField),
        'https://home.example.test:8443',
      );
      await tester.pump();
      return fixture;
    }

    final authority = ServerAuthority('home.example.test', 8443);

    testWidgets('a CA-valid unpinned server connects without any question', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pump(tester, pins: pins);
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);

      expect(find.text('Trust this server\'s certificate?'), findsNothing);
      expect(find.text('Enter your API key'), findsOneWidget);
      expect(await pins.read(authority), isNull);
    });

    testWidgets('an unverifiable server shows its fingerprint; Trust pins it', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pump(tester, pins: pins, probe: _probe(chainValid: false));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);

      expect(find.text('Trust this server\'s certificate?'), findsOneWidget);
      expect(find.textContaining('home.example.test'), findsWidgets);
      expect(
        find.textContaining(_fingerprintA.split(':').take(8).join(':')),
        findsOneWidget,
      );
      // Nothing is stored and nothing moves on until the person decides.
      expect(await pins.read(authority), isNull);
      expect(find.text('Enter your API key'), findsNothing);

      await tester.tap(find.text('Trust this key'));
      await _settle(tester);

      expect((await pins.read(authority))?.fingerprint, _fingerprintA);
      expect(find.text('Enter your API key'), findsOneWidget);
    });

    testWidgets('Cancel stores nothing and stays on the address step', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pump(tester, pins: pins, probe: _probe(chainValid: false));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);
      await tester.tap(find.text('Cancel'));
      await _settle(tester);

      expect(await pins.read(authority), isNull);
      expect(find.text('Enter your API key'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    });

    testWidgets('a pinned server presenting the same key just connects', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pins.save(authority, _fingerprintA);
      await pump(tester, pins: pins, probe: _probe(chainValid: false));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);

      expect(find.text('Trust this server\'s certificate?'), findsNothing);
      expect(find.text('Enter your API key'), findsOneWidget);
    });

    testWidgets(
      'a pinned server presenting another key stops at the key-changed screen',
      (tester) async {
        final pins = SecureServerPinStore(_MemorySlots());
        await pins.save(authority, _fingerprintA);
        await pump(
          tester,
          pins: pins,
          probe: _probe(fingerprint: _fingerprintB),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        await _settle(tester);

        expect(find.text('Server key changed'), findsWidgets);
        expect(find.text('Enter your API key'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('server-key-keep')));
        await _settle(tester);

        expect(find.text('Enter your API key'), findsNothing);
        expect((await pins.read(authority))?.fingerprint, _fingerprintA);
      },
    );

    testWidgets('trusting the new key needs a second confirmation', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pins.save(authority, _fingerprintA);
      await pump(
        tester,
        pins: pins,
        probe: _probe(fingerprint: _fingerprintB),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('server-key-trust')));
      await _settle(tester);
      expect(find.text('Trust the new key?'), findsOneWidget);
      expect((await pins.read(authority))?.fingerprint, _fingerprintA);

      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect((await pins.read(authority))?.fingerprint, _fingerprintA);

      await tester.tap(find.byKey(const ValueKey('server-key-trust')));
      await _settle(tester);
      await tester.tap(find.text('Trust new key'));
      await _settle(tester);

      expect((await pins.read(authority))?.fingerprint, _fingerprintB);
      expect(find.text('Enter your API key'), findsOneWidget);
    });

    testWidgets('normal checking is offered only for a CA-valid certificate', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pins.save(authority, _fingerprintA);
      await pump(
        tester,
        pins: pins,
        probe: _probe(fingerprint: _fingerprintB, chainValid: false),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('server-key-normal')), findsNothing);
    });

    testWidgets(
      'switching to normal checking removes the pin after a confirm',
      (tester) async {
        final pins = SecureServerPinStore(_MemorySlots());
        await pins.save(authority, _fingerprintA);
        await pump(
          tester,
          pins: pins,
          probe: _probe(fingerprint: _fingerprintB),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        await _settle(tester);

        await tester.ensureVisible(
          find.byKey(const ValueKey('server-key-normal')),
        );
        await tester.tap(find.byKey(const ValueKey('server-key-normal')));
        await _settle(tester);
        expect(find.text('Stop pinning this server?'), findsOneWidget);
        expect((await pins.read(authority))?.fingerprint, _fingerprintA);

        await tester.tap(find.text('Use normal checking'));
        await _settle(tester);

        expect(await pins.read(authority), isNull);
        expect(find.text('Enter your API key'), findsOneWidget);
      },
    );

    testWidgets('an unreachable server reports it and stores nothing', (
      tester,
    ) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await pump(tester, pins: pins, probe: _probe(fails: true));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);

      expect(find.textContaining('reach'), findsWidgets);
      expect(await pins.read(authority), isNull);
    });

    testWidgets('an unreadable pin blocks connecting instead of dropping it', (
      tester,
    ) async {
      final slots = _MemorySlots();
      slots.values[SecureServerPinStore.keyFor(authority)] = 'not json';
      await pump(tester, pins: SecureServerPinStore(slots));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settle(tester);

      expect(find.textContaining('can\'t be read'), findsOneWidget);
      expect(find.text('Enter your API key'), findsNothing);
    });
  });

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

    testWidgets('Verify key works again after logging out', (tester) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://test.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        configured: true,
        restoredStatus: 'owned',
      );
      // A signed-in session, as Settings > Server connection > Log out sees it.
      final slot = await fixture.credentials.stage(
        CredentialBundle(
          ownerId: 'a',
          endpoint: 'https://test.example.com',
          accessToken: 'fictional-access-a',
          refreshToken: 'fictional-refresh-a',
          expiresAtMillis: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      );
      await fixture.credentials.activate(
        credentialId: slot,
        expectedTransition: await fixture.access.revokeNetwork(),
        sessionGeneration: 1,
      );
      // The app has been running with an API client built for this session.
      fixture.container.read(apiClientProvider);
      await fixture.container.read(authNotifierProvider.notifier).logout();

      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'fictional-key-b');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
      await tester.pumpAndSettle();
      expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
    });

    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets(
        'a stale connection is rebuilt and the key verified on $name',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({
            'server_url': 'https://test.example.com',
          });
          final prefs = await SharedPreferences.getInstance();
          final fixture = await _ScreenFixture.create(
            prefs: prefs,
            configured: true,
            restoredStatus: 'owned',
            staleFirstScope: true,
          );
          // The app built its connection for this installation and kept it.
          final held = fixture.container.listen(apiClientProvider, (_, _) {});
          addTearDown(held.close);
          await fixture.container.read(connectionDeviceStateProvider.future);
          await tester.pumpWidget(fixture.widget);
          await tester.pumpAndSettle();
          await _toKeyStep(tester);

          // The installation moved on (for example another sign-out) while the
          // paused connection still carries the old scope.
          await fixture.access.revokeNetwork();

          await tester.enterText(find.byType(TextField), 'fictional-key-b');
          await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
          await tester.pumpAndSettle();
          // One tap is enough: the connection is rebuilt and the check retried.
          expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
          expect(find.textContaining('Verify the key again'), findsNothing);
        },
      );

      testWidgets('a connection that stays stale reports it once, no loop on '
          '$name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          configured: true,
          restoredStatus: 'owned',
          staleForever: true,
        );
        final held = fixture.container.listen(apiClientProvider, (_, _) {});
        addTearDown(held.close);
        await fixture.container.read(connectionDeviceStateProvider.future);
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        await _toKeyStep(tester);
        await fixture.access.revokeNetwork();

        await tester.enterText(find.byType(TextField), 'fictional-key-b');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Could not set up a secure connection to this server. Check the '
            'address and try again.',
          ),
          findsOneWidget,
        );
        expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
        // The button is usable again.
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Verify key'),
              )
              .onPressed,
          isNotNull,
        );
      });
    }

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
    testWidgets('names the address once, in sentence case, with a way back', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));
      await tester.pumpAndSettle();

      expect(find.text('Server address'), findsOneWidget);
      expect(find.text('SERVER ADDRESS'), findsNothing);
      expect(find.byKey(const ValueKey('connect-back')), findsOneWidget);
    });

    testWidgets('keeps the form a readable width on a tablet', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await buildScreen(prefs: prefs));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(TextFormField)).width, lessThan(600));
    });

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

  group('ServerPickerScreen — signed out note', () {
    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets('a session the server ended leaves a note on $name', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          restoredStatus: 'owned',
          fakeAuth: FakeAuthRepository()
            ..loginFuture = Future.value(
              const Err<LoginResult>(ServerError(500)),
            ),
        );
        fixture.container.read(signedOutNoticeProvider.notifier).state = true;
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();

        expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
        expect(
          find.text('You were signed out. Sign in again to continue.'),
          findsOneWidget,
        );

        // The note is for the person who has not yet tried again.
        await _fillCredentials(tester);
        final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
        await tester.ensureVisible(loginBtn);
        await tester.tap(loginBtn);
        await tester.pumpAndSettle();
        expect(
          find.text('You were signed out. Sign in again to continue.'),
          findsNothing,
        );
      });
    }

    testWidgets('a normal visit to sign-in shows no note', (tester) async {
      await _pumpCredentialsPhase(tester);
      expect(
        find.byKey(const ValueKey('auth-signed-out-notice')),
        findsNothing,
      );
    });
  });

  group('ServerPickerScreen — certificate that does not validate', () {
    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets('the key step offers a review and then continues on $name', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final pins = SecureServerPinStore(_MemorySlots());
        var refused = true;
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          configured: true,
          restoredStatus: 'owned',
          pins: pins,
          probe: _probe(chainValid: false),
          verify: (options) async {
            if (refused) {
              throw DioException.connectionError(
                requestOptions: options,
                reason: 'tls',
                error: const HandshakeException(
                  'Handshake error: CERTIFICATE_VERIFY_FAILED: '
                  'self signed certificate',
                ),
              );
            }
            return {'status': 'owned'};
          },
        );
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        await _toKeyStep(tester);

        await tester.enterText(find.byType(TextField), 'fictional-key-b');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            "This server's certificate can't be verified, so Simpastil "
            "didn't connect.",
          ),
          findsOneWidget,
        );
        expect(find.text('Review server key'), findsOneWidget);
        // Nothing was trusted by showing the problem.
        expect(
          await pins.read(ServerAuthority('test.example.com', 443)),
          isNull,
        );

        await tester.tap(find.text('Review server key'));
        await tester.pumpAndSettle();
        expect(find.text("Trust this server's certificate?"), findsOneWidget);
        expect(
          await pins.read(ServerAuthority('test.example.com', 443)),
          isNull,
        );

        refused = false;
        await tester.tap(find.text('Trust this key'));
        await tester.pumpAndSettle();
        expect(
          (await pins.read(
            ServerAuthority('test.example.com', 443),
          ))?.fingerprint,
          _fingerprintA,
        );
        expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
      });
    }

    for (final (name, size, locale, message, action) in [
      (
        'phone',
        const Size(400, 900),
        const Locale('en'),
        "The server's key changed, so nothing was sent.",
        'Review server key',
      ),
      (
        'tablet',
        const Size(1000, 1300),
        const Locale('en'),
        "The server's key changed, so nothing was sent.",
        'Review server key',
      ),
      (
        'phone in Romanian',
        const Size(400, 900),
        const Locale('ro'),
        'Cheia serverului s-a schimbat, așa că nu s-a trimis nimic.',
        'Verifică cheia serverului',
      ),
    ]) {
      testWidgets('a changed server key on the key step offers the review and '
          'continues on $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final pins = SecureServerPinStore(_MemorySlots());
        await pins.save(
          ServerAuthority('test.example.com', 443),
          _fingerprintA,
        );
        var changed = true;
        final fixture =
            await _ScreenFixture.create(
                prefs: prefs,
                configured: true,
                restoredStatus: 'owned',
                pins: pins,
                probe: _probe(fingerprint: _fingerprintB, chainValid: false),
                verify: (options) async {
                  if (changed) {
                    throw DioException.connectionError(
                      requestOptions: options,
                      reason: 'pin',
                      error: CertificatePinMismatch(
                        host: 'test.example.com',
                        port: 443,
                        pinned: _fingerprintA,
                        presented: _fingerprintB,
                      ),
                    );
                  }
                  return {'status': 'owned'};
                },
              )
              ..locale = locale;
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        final back = find.text(
          locale.languageCode == 'ro'
              ? 'Folosește o altă cheie API'
              : 'Use a different API key',
        );
        await tester.ensureVisible(back);
        await tester.tap(back);
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'fictional-key-b');
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();

        // The reason is the key, not "could not reach server".
        expect(find.text(message), findsOneWidget);
        expect(find.text('Could not reach server.'), findsNothing);
        final review = find.byKey(const ValueKey('auth-review-server-key'));
        expect(
          find.descendant(of: review, matching: find.text(action)),
          findsOne,
        );

        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('server-key-trust')), findsOneWidget);
        // Showing the review trusts nothing.
        expect(
          (await pins.read(
            ServerAuthority('test.example.com', 443),
          ))?.fingerprint,
          _fingerprintA,
        );

        changed = false;
        await tester.tap(find.byKey(const ValueKey('server-key-trust')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            locale.languageCode == 'ro'
                ? 'Acceptă cheia nouă'
                : 'Trust new key',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          (await pins.read(
            ServerAuthority('test.example.com', 443),
          ))?.fingerprint,
          _fingerprintB,
        );
        expect(review, findsNothing);
        // The typed key was checked again and the account step opened.
        expect(find.byType(ServerPickerScreen), findsOneWidget);
        expect(find.text(message), findsNothing);
      });
    }

    testWidgets('cancelling the review trusts nothing and keeps the error', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://test.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final pins = SecureServerPinStore(_MemorySlots());
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        configured: true,
        restoredStatus: 'owned',
        pins: pins,
        probe: _probe(chainValid: false),
        verify: (options) async => throw DioException.connectionError(
          requestOptions: options,
          reason: 'tls',
          error: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
      );
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      await _toKeyStep(tester);
      await tester.enterText(find.byType(TextField), 'fictional-key-b');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review server key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await pins.read(ServerAuthority('test.example.com', 443)), isNull);
      expect(find.text('STEP 2 OF 3 — API KEY'), findsOneWidget);
      expect(find.text('Review server key'), findsOneWidget);
    });

    testWidgets(
      'an unreachable server keeps the plain error without a review',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          configured: true,
          restoredStatus: 'owned',
          verify: (options) async => throw DioException.connectionError(
            requestOptions: options,
            reason: 'down',
            error: const SocketException('down'),
          ),
        );
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        await _toKeyStep(tester);
        await tester.enterText(find.byType(TextField), 'fictional-key-b');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
        await tester.pumpAndSettle();

        expect(find.text('Could not reach server.'), findsOneWidget);
        expect(find.text('Review server key'), findsNothing);
      },
    );

    Future<_ScreenFixture> signInRefused(
      WidgetTester tester, {
      required SecureServerPinStore pins,
      required bool certificate,
    }) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://test.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        configured: true,
        restoredStatus: 'owned',
        pins: pins,
        probe: _probe(chainValid: false),
        fakeAuth: FakeAuthRepository()
          ..loginFuture = Future.value(
            Err<LoginResult>(
              NetworkError('tls', certificateRejected: certificate),
            ),
          ),
      );
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
      await _fillCredentials(tester);
      final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
      await tester.ensureVisible(loginBtn);
      await tester.tap(loginBtn);
      await tester.pumpAndSettle();
      return fixture;
    }

    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets('sign-in offers a review and then signs in again on $name', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final pins = SecureServerPinStore(_MemorySlots());
        await signInRefused(tester, pins: pins, certificate: true);

        expect(
          find.text(
            "This server's certificate can't be verified, so Simpastil "
            "didn't connect.",
          ),
          findsOneWidget,
        );
        final review = find.byKey(
          const ValueKey('auth-login-review-server-key'),
        );
        expect(review, findsOneWidget);
        // Nothing was trusted by showing the problem.
        expect(
          await pins.read(ServerAuthority('test.example.com', 443)),
          isNull,
        );

        await tester.ensureVisible(review);
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.text("Trust this server's certificate?"), findsOneWidget);
        await tester.tap(find.text('Trust this key'));
        await tester.pumpAndSettle();

        expect(
          (await pins.read(
            ServerAuthority('test.example.com', 443),
          ))?.fingerprint,
          _fingerprintA,
        );
        // The error is cleared so signing in can be tried again; there is no
        // account yet, so nothing else happens.
        expect(review, findsNothing);
        expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'LOG IN'), findsOneWidget);
      });
    }

    testWidgets('cancelling the sign-in review trusts nothing', (tester) async {
      final pins = SecureServerPinStore(_MemorySlots());
      await signInRefused(tester, pins: pins, certificate: true);
      final review = find.byKey(const ValueKey('auth-login-review-server-key'));
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await pins.read(ServerAuthority('test.example.com', 443)), isNull);
      expect(review, findsOneWidget);
    });

    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets(
        'a changed server key at sign-in offers the review on $name',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({
            'server_url': 'https://test.example.com',
          });
          final prefs = await SharedPreferences.getInstance();
          final pins = SecureServerPinStore(_MemorySlots());
          await pins.save(
            ServerAuthority('test.example.com', 443),
            _fingerprintA,
          );
          final fixture = await _ScreenFixture.create(
            prefs: prefs,
            configured: true,
            restoredStatus: 'owned',
            pins: pins,
            probe: _probe(fingerprint: _fingerprintB, chainValid: false),
            fakeAuth: FakeAuthRepository()
              ..loginFuture = Future.value(
                const Err<LoginResult>(
                  NetworkError('key', serverKeyChanged: true),
                ),
              ),
          );
          await tester.pumpWidget(fixture.widget);
          await tester.pumpAndSettle();
          await _fillCredentials(tester);
          final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
          await tester.ensureVisible(loginBtn);
          await tester.tap(loginBtn);
          await tester.pumpAndSettle();

          // The reason is the key, not "something went wrong".
          expect(
            find.text("The server's key changed, so nothing was sent."),
            findsOneWidget,
          );
          expect(find.text('Something went wrong'), findsNothing);
          final review = find.byKey(
            const ValueKey('auth-login-review-server-key'),
          );
          await tester.ensureVisible(review);
          await tester.tap(review);
          await tester.pumpAndSettle();
          expect(find.text('Trust the new key'), findsOneWidget);

          await tester.tap(find.byKey(const ValueKey('server-key-trust')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Trust new key'));
          await tester.pumpAndSettle();

          expect(
            (await pins.read(
              ServerAuthority('test.example.com', 443),
            ))?.fingerprint,
            _fingerprintB,
          );
          expect(review, findsNothing);
          expect(find.text('STEP 3 OF 3 — ACCOUNT'), findsOneWidget);
        },
      );
    }

    for (final (name, size) in const [
      ('phone', Size(400, 900)),
      ('tablet', Size(1000, 1300)),
    ]) {
      testWidgets('trusting the new key elsewhere clears the sign-in error on '
          '$name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://test.example.com',
        });
        final prefs = await SharedPreferences.getInstance();
        final authority = ServerAuthority('test.example.com', 443);
        final pins = SecureServerPinStore(_MemorySlots());
        await pins.save(authority, _fingerprintA);
        await pins.recordMismatch(authority, _fingerprintB);
        final fixture = await _ScreenFixture.create(
          prefs: prefs,
          configured: true,
          restoredStatus: 'owned',
          pins: pins,
          probe: _probe(fingerprint: _fingerprintB, chainValid: false),
          fakeAuth: FakeAuthRepository()
            ..loginFuture = Future.value(
              const Err<LoginResult>(
                NetworkError('key', serverKeyChanged: true),
              ),
            ),
        );
        await tester.pumpWidget(fixture.widget);
        await tester.pumpAndSettle();
        await _fillCredentials(tester);
        final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
        await tester.ensureVisible(loginBtn);
        await tester.tap(loginBtn);
        await tester.pumpAndSettle();
        final review = find.byKey(
          const ValueKey('auth-login-review-server-key'),
        );
        expect(review, findsOneWidget);

        // Another screen (forgot password, Sync) trusts the new key.
        await fixture.container
            .read(serverPinControllerProvider.notifier)
            .trust(authority, _fingerprintB);
        await tester.pumpAndSettle();

        expect(review, findsNothing);
        expect(
          find.text("The server's key changed, so nothing was sent."),
          findsNothing,
        );
      });
    }

    testWidgets('trusting the new key elsewhere clears the key step error', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://test.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final authority = ServerAuthority('test.example.com', 443);
      final pins = SecureServerPinStore(_MemorySlots());
      await pins.save(authority, _fingerprintA);
      await pins.recordMismatch(authority, _fingerprintB);
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        configured: true,
        restoredStatus: 'owned',
        pins: pins,
        verify: (options) async => throw DioException.connectionError(
          requestOptions: options,
          reason: 'pin',
          error: CertificatePinMismatch(
            host: 'test.example.com',
            port: 443,
            pinned: _fingerprintA,
            presented: _fingerprintB,
          ),
        ),
      );
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      await _toKeyStep(tester);
      await tester.enterText(find.byType(TextField), 'fictional-key-b');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify key'));
      await tester.pumpAndSettle();
      final review = find.byKey(const ValueKey('auth-review-server-key'));
      expect(review, findsOneWidget);

      await fixture.container
          .read(serverPinControllerProvider.notifier)
          .trust(authority, _fingerprintB);
      await tester.pumpAndSettle();

      expect(review, findsNothing);
      expect(
        find.text("The server's key changed, so nothing was sent."),
        findsNothing,
      );
    });

    testWidgets('an unrelated pin refresh keeps the sign-in error', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://test.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final authority = ServerAuthority('test.example.com', 443);
      final pins = SecureServerPinStore(_MemorySlots());
      await pins.save(authority, _fingerprintA);
      await pins.recordMismatch(authority, _fingerprintB);
      final fixture = await _ScreenFixture.create(
        prefs: prefs,
        configured: true,
        restoredStatus: 'owned',
        pins: pins,
        fakeAuth: FakeAuthRepository()
          ..loginFuture = Future.value(
            const Err<LoginResult>(NetworkError('key', serverKeyChanged: true)),
          ),
      );
      await tester.pumpWidget(fixture.widget);
      await tester.pumpAndSettle();
      await _fillCredentials(tester);
      final loginBtn = find.widgetWithText(FilledButton, 'LOG IN');
      await tester.ensureVisible(loginBtn);
      await tester.tap(loginBtn);
      await tester.pumpAndSettle();

      // The mismatch is still on record: a refresh changes nothing.
      fixture.container.read(serverPinControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('auth-login-review-server-key')),
        findsOneWidget,
      );
    });

    testWidgets('a plain network failure at sign-in has no review', (
      tester,
    ) async {
      await signInRefused(
        tester,
        pins: SecureServerPinStore(_MemorySlots()),
        certificate: false,
      );
      expect(find.text('No connection. Check your network.'), findsWidgets);
      expect(
        find.byKey(const ValueKey('auth-login-review-server-key')),
        findsNothing,
      );
    });
  });
}
