import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/features/auth/auth_provider.dart';

class _Secrets implements CredentialSlotStore {
  final values = <String, String>{};
  Future<void> Function()? beforeRead;
  @override
  Future<String?> read(String key) async {
    await beforeRead?.call();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _UnboundLegacyTokens extends TokenService {
  @override
  Future<String?> getUserId() async => 'unbound-b';
  @override
  Future<bool> hasSession() async => true;
  @override
  Future<void> clearSessionTokens() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://fictional.test/care';
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late ProtectedCredentialsRepository credentials;
  late ProviderContainer container;
  late _Secrets secrets;
  Future<void> activateA() async {
    final slot = await credentials.stage(
      CredentialBundle(
        ownerId: 'a',
        endpoint: endpoint,
        accessToken: 'fictional-access-a',
        refreshToken: 'fictional-refresh-a',
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({'server_url': endpoint});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    await access.configureEndpoint(endpoint);
    secrets = _Secrets();
    credentials = ProtectedCredentialsRepository(
      access: access,
      store: secrets,
    );
    final generations = SessionGenerationRepository(prefs, access: access);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
        tokenServiceProvider.overrideWithValue(_UnboundLegacyTokens()),
        sessionRemoteRevocationProvider.overrideWithValue((_, _) async {}),
        sessionGenerationRepositoryProvider.overrideWithValue(generations),
        sessionRuntimeCoordinatorProvider.overrideWithValue(
          SessionRuntimeCoordinator(
            generations: generations,
            startSync: (_, _) {},
            stopSync: () {},
          ),
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  test(
    'warm restore uses protected A without copying unbound legacy B',
    () async {
      await activateA();
      final before =
          (await access.workspaces.deviceState()).networkCredentialId;
      await container.read(authNotifierProvider.notifier).restoreSession();
      expect(
        (container.read(authNotifierProvider) as AuthAuthenticated).userId,
        'a',
      );
      expect(
        (await access.workspaces.deviceState()).networkCredentialId,
        before,
      );
    },
  );
  test('unbound legacy token cannot create protected account access', () async {
    await container.read(authNotifierProvider.notifier).restoreSession();
    expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    expect(await access.currentNetworkCapability(), isNull);
    expect((await access.currentContext()).isLocal, isTrue);
  });
  test(
    'confirmed session clearing durably revokes retained account access',
    () async {
      await activateA();
      await container.read(authNotifierProvider.notifier).clearSession();
      expect(await access.contextForOwner('a'), isNull);
      expect(await access.workspaces.byOwner('a'), isNotNull);
      expect((await access.currentContext()).isLocal, isTrue);
    },
  );
  test('a forced sign-out gives the next screen a fresh connection', () async {
    await activateA();
    // The app has been running with a connection built for A's session.
    final stale = container.read(scopedTokenServiceProvider);
    final staleScope = await stale.installation;
    expect(await access.installationIsCurrent(staleScope!), isTrue);

    await container.read(authNotifierProvider.notifier).clearSession();

    final fresh = container.read(scopedTokenServiceProvider);
    expect(identical(fresh, stale), isFalse);
    final freshScope = await fresh.installation;
    expect(await access.installationIsCurrent(freshScope!), isTrue);
    expect(await access.installationIsCurrent(staleScope), isFalse);
  });
  test('logout revokes care before a blocked secure credential read', () async {
    await activateA();
    await container.read(authNotifierProvider.notifier).restoreSession();
    final entered = Completer<void>();
    final release = Completer<void>();
    secrets.beforeRead = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final logout = container.read(authNotifierProvider.notifier).logout();
    try {
      await entered.future.timeout(const Duration(seconds: 3));
      expect(await access.contextForOwner('a'), isNull);
      expect(await access.workspaces.byOwner('a'), isNotNull);
      expect((await access.currentContext()).isLocal, isTrue);
    } finally {
      release.complete();
      await logout;
    }
  });
}
