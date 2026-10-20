import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/connection_scope_keeper.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';

class _Secrets implements CredentialSlotStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _endpoint = 'https://fictional.test/care';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late ProtectedCredentialsRepository credentials;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'server_url': _endpoint});
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    await access.configureEndpoint(_endpoint);
    credentials = ProtectedCredentialsRepository(
      access: access,
      store: _Secrets(),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
  });

  Future<void> signIn(String owner) async {
    final slot = await credentials.stage(
      CredentialBundle(
        ownerId: owner,
        endpoint: _endpoint,
        accessToken: 'fictional-access',
        refreshToken: 'fictional-refresh',
        expiresAtMillis: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      ),
    );
    await credentials.activate(
      credentialId: slot,
      expectedTransition: await access.revokeNetwork(),
      sessionGeneration: 1,
    );
  }

  Future<void> signOut() async {
    await access.revokeNetwork();
  }

  group('a plain read after the device state changed', () {
    testWidgets('sees the new session while the app is mounted', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const ConnectionScopeKeeper(child: SizedBox()),
          ),
        );
        await pumpEventQueue();
        final before = container.read(scopedTokenServiceProvider);
        expect(await before.readBundle(), isNull);

        await signIn('a');
        await pumpEventQueue();
        final signedIn = container.read(scopedTokenServiceProvider);
        expect(signedIn.capability, isNotNull);
        expect(await signedIn.getRefreshToken(), 'fictional-refresh');
        // What the device name step and the sync read.
        final client = container.read(apiClientProvider);
        expect(client.networkCapability, signedIn.capability);

        await signOut();
        await pumpEventQueue();
        final signedOut = container.read(scopedTokenServiceProvider);
        expect(signedOut.capability, isNull);
        expect(await signedOut.readBundle(), isNull);
        expect(
          (await signedOut.installation)?.networkEpoch,
          isNot((await signedIn.installation)?.networkEpoch),
          reason: 'Verify key must run against the new installation epoch',
        );
      });
    });

    test(
      'is left on the old scope when nothing listens (the defect)',
      () async {
        final before = container.read(scopedTokenServiceProvider);
        await signIn('a');
        await pumpEventQueue();
        expect(container.read(scopedTokenServiceProvider), same(before));
        expect(await before.readBundle(), isNull);
      },
    );

    test('settling first gives the current scope after a sign-in', () async {
      container.read(scopedTokenServiceProvider);
      await signIn('a');
      await container.read(connectionScopeSettlerProvider)();

      final service = container.read(scopedTokenServiceProvider);
      expect(await service.getRefreshToken(), 'fictional-refresh');
    });

    test('settling first gives the current scope after a sign-out', () async {
      await signIn('a');
      await container.read(connectionScopeSettlerProvider)();
      expect(
        await container.read(scopedTokenServiceProvider).readBundle(),
        isNotNull,
      );

      await signOut();
      await container.read(connectionScopeSettlerProvider)();
      expect(
        await container.read(scopedTokenServiceProvider).readBundle(),
        isNull,
      );
    });

    test('settling on a cold start waits for the first device state', () async {
      await signIn('a');
      // Nothing has read the stream yet: this is the first build.
      await container.read(connectionScopeSettlerProvider)();

      final service = container.read(scopedTokenServiceProvider);
      expect(service.capability, isNotNull);
      expect(await service.readBundle(), isNotNull);
    });
  });
}
