import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/auth/credential_refresh_factory.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/session/session_runtime_coordinator.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecrets implements CredentialSlotStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

// ── Fakes ─────────────────────────────────────────────────────────────────────

class FakeAuthRepository implements AuthRepository {
  Result<LoginResult>? loginResult;
  Result<void>? registerResult;
  Result<LoginSuccess>? challenge2faResult;
  late ProtectedCredentialsRepository credentials;
  Future<LoginSuccess> _stage(String owner) async => LoginSuccess(
    owner,
    credentialId: await credentials.stage(
      CredentialBundle(
        ownerId: owner,
        endpoint: 'https://fictional.test',
        accessToken: 'fictional-access',
        refreshToken: 'fictional-refresh',
        expiresAtMillis: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      ),
    ),
  );

  @override
  Future<Result<LoginResult>> login(String email, String password) async {
    final result =
        loginResult ??
        const Err<LoginResult>(UnknownError('loginResult not set'));
    if (result case Ok(value: LoginSuccess(:final userId))) {
      return Ok(await _stage(userId));
    }
    return result;
  }

  @override
  Future<Result<void>> register(String email, String password) async =>
      registerResult ?? const Err(UnknownError('registerResult not set'));

  @override
  Future<Result<void>> logout(String refreshToken) async => const Ok(null);

  @override
  Future<Result<void>> changePassword(
    String currentPassword,
    String newPassword,
  ) async => const Ok(null);

  @override
  Future<Result<void>> setDeviceName(String deviceName) async => const Ok(null);

  @override
  Future<Result<LoginSuccess>> challenge2fa(
    String challengeToken,
    String code,
  ) async {
    final result = challenge2faResult ?? const Ok(LoginSuccess('user-uuid'));
    if (result case Ok(:final value)) return Ok(await _stage(value.userId));
    return result;
  }

  @override
  Future<Result<TotpSetupResult>> setup2fa() async =>
      const Ok(TotpSetupResult(secret: 'test', otpauthUri: 'otpauth://test'));

  @override
  Future<Result<List<String>>> enable2fa(String code) async =>
      const Ok(['code1']);

  @override
  Future<Result<void>> disable2fa(String code) async => const Ok(null);

  @override
  Future<Result<List<String>>> regenerateBackupCodes(String code) async =>
      const Ok(['code1']);
}

class FakeTokenService extends TokenService {
  // Not const — FlutterSecureStorage internals may not be const-compatible
  // at runtime even though TokenService() is declared const.
  // ignore: prefer_const_constructors_in_immutables
  FakeTokenService({this.userId, this.accessToken, this.refreshToken});

  final String? userId;
  final String? accessToken;
  final String? refreshToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async =>
      refreshToken ?? 'fake-refresh-token';

  @override
  Future<bool> isAuthenticated() async => false;

  @override
  Future<bool> hasSession() async {
    final refresh = await getRefreshToken();
    return refresh != null && refresh.isNotEmpty;
  }

  @override
  Future<String?> getUserId() async => userId;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresIn,
  }) async {}

  @override
  Future<void> clearTokens() async {}

  @override
  Future<void> clearSessionTokens() async {}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

late SharedPreferences testPrefs;

Future<ProviderContainer> makeContainer({
  required FakeAuthRepository fakeRepo,
  FakeTokenService? tokenService,
}) async {
  final db = AppDatabase.forTesting();
  final access = WorkspaceAccessRepository(db);
  await access.configureEndpoint('https://fictional.test');
  final credentials = ProtectedCredentialsRepository(
    access: access,
    store: _MemorySecrets(),
  );
  fakeRepo.credentials = credentials;
  final directory = await Directory.systemTemp.createTemp(
    'fictional-auth-notifier-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final generations = SessionGenerationRepository(testPrefs, access: access);
  final runtime = SessionRuntimeCoordinator(
    generations: generations,
    startSync: (_, _) {},
    stopSync: () {},
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      sharedPreferencesProvider.overrideWithValue(testPrefs),
      sessionGenerationRepositoryProvider.overrideWithValue(generations),
      sessionRuntimeCoordinatorProvider.overrideWithValue(runtime),
      authRepositoryProvider.overrideWithValue(fakeRepo),
      authTransitionRepositoryFactoryProvider.overrideWithValue(
        (_) => fakeRepo,
      ),
      protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
      credentialRefreshGateProvider.overrideWithValue(
        () async => NativeCredentialRefreshGate(
          directory: directory,
          syncDirectory: (_) async {},
        ),
      ),
      sessionRemoteRevocationProvider.overrideWithValue((_, _) async {}),
      tokenServiceProvider.overrideWithValue(
        tokenService ?? FakeTokenService(),
      ),
    ],
  );
  addTearDown(db.close);
  return container;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://fictional.test',
    });
    testPrefs = await SharedPreferences.getInstance();
  });

  group('AuthNotifier initial state', () {
    test('starts as AuthUnauthenticated', () async {
      final container = await makeContainer(fakeRepo: FakeAuthRepository());
      addTearDown(container.dispose);

      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    });
  });

  group('AuthNotifier.login()', () {
    test('transitions to AuthAuthenticated on Ok', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('user-123'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      int? generationAtPublication;
      container.listen(authNotifierProvider, (_, state) {
        if (state is AuthAuthenticated) {
          generationAtPublication = testPrefs.getInt('session_generation');
        }
      });

      final result = await container
          .read(authNotifierProvider.notifier)
          .login('a@b.com', 'password123');

      expect(result, isA<Ok<void>>());
      expect(
        container.read(authNotifierProvider),
        isA<AuthAuthenticated>().having((s) => s.userId, 'userId', 'user-123'),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('current_user_id'), 'user-123');
      expect(prefs.getString('active_user_id'), 'user-123');
      expect(prefs.getInt('session_generation'), 3);
      expect(generationAtPublication, 3);
    });

    test(
      'transitions to AuthUnauthenticated and returns Err on failure',
      () async {
        final repo = FakeAuthRepository()
          ..loginResult = const Err(UnauthorizedError());
        final container = await makeContainer(fakeRepo: repo);
        addTearDown(container.dispose);

        final result = await container
            .read(authNotifierProvider.notifier)
            .login('a@b.com', 'wrong');

        expect(result, isA<Err<void>>());
        expect((result as Err).error, isA<UnauthorizedError>());
        expect(
          container.read(authNotifierProvider),
          isA<AuthUnauthenticated>(),
        );
      },
    );

    test('passes through AuthLoading during the async call', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('user-abc'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      final states = <AuthState>[];
      container.listen(authNotifierProvider, (_, s) => states.add(s));

      await container
          .read(authNotifierProvider.notifier)
          .login('a@b.com', 'pw');

      expect(states.first, isA<AuthLoading>());
      expect(states.last, isA<AuthAuthenticated>());
    });
  });

  group('AuthNotifier.register()', () {
    test(
      'auto-logins and transitions to AuthAuthenticated on full success',
      () async {
        final repo = FakeAuthRepository()
          ..registerResult = const Ok(null)
          ..loginResult = const Ok(LoginSuccess('auto-user'));
        final container = await makeContainer(fakeRepo: repo);
        addTearDown(container.dispose);

        final result = await container
            .read(authNotifierProvider.notifier)
            .register('new@user.com', 'password123');

        expect(result, isA<Ok<void>>());
        expect(
          container.read(authNotifierProvider),
          isA<AuthAuthenticated>().having(
            (s) => s.userId,
            'userId',
            'auto-user',
          ),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('current_user_id'), 'auto-user');
      },
    );

    test('returns Err and stays unauthenticated if register fails', () async {
      final repo = FakeAuthRepository()
        ..registerResult = const Err(ConflictError());
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      final result = await container
          .read(authNotifierProvider.notifier)
          .register('taken@email.com', 'password123');

      expect(result, isA<Err<void>>());
      expect((result as Err).error, isA<ConflictError>());
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    });

    test('returns Err if register succeeds but auto-login fails', () async {
      final repo = FakeAuthRepository()
        ..registerResult = const Ok(null)
        ..loginResult = const Err(NetworkError('offline'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      final result = await container
          .read(authNotifierProvider.notifier)
          .register('a@b.com', 'password123');

      expect(result, isA<Err<void>>());
      expect((result as Err).error, isA<NetworkError>());
    });
  });

  test(
    'account replacement advances generation before publishing the new owner',
    () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('user-a'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      await container
          .read(authNotifierProvider.notifier)
          .login('a@b.com', 'pw');
      repo.loginResult = const Ok(LoginSuccess('user-b'));
      int? generationAtPublication;
      container.listen(authNotifierProvider, (_, state) {
        if (state is AuthAuthenticated && state.userId == 'user-b') {
          generationAtPublication = testPrefs.getInt('session_generation');
        }
      });

      await container
          .read(authNotifierProvider.notifier)
          .login('b@b.com', 'pw');

      expect(generationAtPublication, 5);
      expect(testPrefs.getString('active_user_id'), 'user-b');
    },
  );

  group('AuthNotifier.logout()', () {
    test('retains signed-out care and its pending work', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('retained-account'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);
      await container
          .read(authNotifierProvider.notifier)
          .login('fictional@example.test', 'fictional');
      final db = container.read(databaseProvider);
      final now = DateTime.utc(2026, 9, 30);
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'retained-account',
          email: 'fictional@example.test',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'retained-person',
          userId: 'retained-account',
          name: 'Fictional person',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'retained-operation',
          userId: 'retained-account',
          mutationId: 'retained-mutation',
          component: 'stable',
          operationType: 'profile.create',
          contractVersion: 2,
          payloadJson: '{}',
          createdAt: now,
        ),
      );

      await container.read(authNotifierProvider.notifier).logout();

      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
      expect(await db.profilesDao.getById('retained-person'), isNotNull);
      expect(
        await db.pendingOperationsDao.getById('retained-operation'),
        isNotNull,
      );
      expect(
        await container
            .read(sessionGenerationRepositoryProvider)
            .currentIdentity(),
        isNull,
      );
    });

    test('transitions to AuthUnauthenticated', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('user-xyz'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      // First log in
      await container
          .read(authNotifierProvider.notifier)
          .login('a@b.com', 'pw');
      expect(container.read(authNotifierProvider), isA<AuthAuthenticated>());

      // Then log out
      await container.read(authNotifierProvider.notifier).logout();
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('current_user_id'), isNull);
      expect(prefs.getString('active_user_id'), isNull);
      expect(prefs.getInt('session_generation'), 4);
    });
  });

  group('signing out and switching accounts', () {
    test('drops the signed-out account\'s refused-setting memory', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('user-xyz'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.login('a@b.com', 'pw');
      await testPrefs.setString(
        'account_settings_refused_user-xyz',
        '{"settings.siblingDetection":{"fingerprint":"f","revision":0}}',
      );
      await testPrefs.setString('account_settings_refused_user-abc', '{}');

      await notifier.logout();
      expect(
        testPrefs.containsKey('account_settings_refused_user-xyz'),
        isFalse,
      );
      expect(
        testPrefs.containsKey('account_settings_refused_user-abc'),
        isTrue,
        reason: 'another account\'s memory is not this sign-out\'s',
      );

      // Another account signs in on the same phone: the only refusal memory
      // left is its own, untouched by the sign-in.
      repo.loginResult = const Ok(LoginSuccess('user-abc'));
      await notifier.login('c@d.com', 'pw');
      expect(
        testPrefs.getKeys().where(
          (k) => k.startsWith('account_settings_refus'),
        ),
        ['account_settings_refused_user-abc'],
      );
      expect(testPrefs.getString('account_settings_refused_user-abc'), '{}');
    });

    test('a session the server ends also forgets the refusals', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginSuccess('user-xyz'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.login('a@b.com', 'pw');
      await testPrefs.setString(
        'account_settings_refused_user-xyz',
        '{"settings.siblingDetection":{"fingerprint":"f","keyed":true,'
            '"revision":0}}',
      );
      await testPrefs.setString('account_settings_refusal_key_user-xyz', 'k');
      await testPrefs.setString('account_settings_refused_user-abc', '{}');

      expect(await notifier.clearSession(), isTrue);
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
      expect(
        testPrefs.containsKey('account_settings_refused_user-xyz'),
        isFalse,
      );
      expect(
        testPrefs.containsKey('account_settings_refusal_key_user-xyz'),
        isFalse,
      );
      expect(
        testPrefs.containsKey('account_settings_refused_user-abc'),
        isTrue,
      );
    });
  });

  group('AuthNotifier.restoreSession()', () {
    test(
      'unbound global tokens and saved owner do not authorize retained care',
      () async {
        await testPrefs.setString('current_user_id', 'saved-user');
        final container = await makeContainer(
          fakeRepo: FakeAuthRepository(),
          tokenService: FakeTokenService(
            userId: 'saved-user',
            refreshToken: 'opaque-legacy-refresh',
          ),
        );
        addTearDown(container.dispose);
        await container.read(authNotifierProvider.notifier).restoreSession();
        expect(
          container.read(authNotifierProvider),
          isA<AuthUnauthenticated>(),
        );
        expect(
          await container
              .read(sessionGenerationRepositoryProvider)
              .currentIdentity(),
          isNull,
        );
        expect(testPrefs.getString('current_user_id'), 'saved-user');
      },
    );
  });

  group('AuthNotifier 2FA challenge flow', () {
    test(
      'login transitions to AuthRequires2fa when repo returns LoginRequires2fa',
      () async {
        final repo = FakeAuthRepository()
          ..loginResult = const Ok(LoginRequires2fa('challenge-token-abc'));
        final container = await makeContainer(fakeRepo: repo);
        addTearDown(container.dispose);

        final result = await container
            .read(authNotifierProvider.notifier)
            .login('a@b.com', 'password123');

        expect(result, isA<Ok<void>>());
        expect(
          container.read(authNotifierProvider),
          isA<AuthRequires2fa>()
              .having(
                (s) => s.challengeToken,
                'challengeToken',
                'challenge-token-abc',
              )
              .having((s) => s.email, 'email', 'a@b.com'),
        );
      },
    );

    test('verify2fa transitions to AuthAuthenticated on success', () async {
      final repo = FakeAuthRepository()
        ..loginResult = const Ok(LoginRequires2fa('challenge-token-abc'));
      final container = await makeContainer(fakeRepo: repo);
      addTearDown(container.dispose);

      await container
          .read(authNotifierProvider.notifier)
          .login('a@b.com', 'password123');
      expect(container.read(authNotifierProvider), isA<AuthRequires2fa>());

      final result = await container
          .read(authNotifierProvider.notifier)
          .verify2fa('123456');

      expect(result, isA<Ok<void>>());
      expect(
        container.read(authNotifierProvider),
        isA<AuthAuthenticated>().having((s) => s.userId, 'userId', 'user-uuid'),
      );
    });

    test(
      'verify2fa returns Err and restores AuthRequires2fa on failure',
      () async {
        final repo = FakeAuthRepository()
          ..loginResult = const Ok(LoginRequires2fa('challenge-token-abc'));
        final container = await makeContainer(fakeRepo: repo);
        addTearDown(container.dispose);

        await container
            .read(authNotifierProvider.notifier)
            .login('a@b.com', 'password123');

        // Override challenge2fa to fail
        repo.challenge2faResult = const Err(UnauthorizedError());

        final result = await container
            .read(authNotifierProvider.notifier)
            .verify2fa('wrong-code');

        expect(result, isA<Err<void>>());
        expect(container.read(authNotifierProvider), isA<AuthRequires2fa>());
      },
    );

    test('verify2fa returns Err when not in 2FA state', () async {
      final container = await makeContainer(fakeRepo: FakeAuthRepository());
      addTearDown(container.dispose);

      final result = await container
          .read(authNotifierProvider.notifier)
          .verify2fa('123456');

      expect(result, isA<Err<void>>());
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    });
  });

  // ── C-1 fix: session expiry preserves local data ─────────────────────────
  group('AuthNotifier.clearSession() (C-1 fix)', () {
    test(
      'transitions to AuthUnauthenticated without deleting local data',
      () async {
        final repo = FakeAuthRepository()
          ..loginResult = const Ok(LoginSuccess('user-c1'));
        final container = await makeContainer(fakeRepo: repo);
        addTearDown(container.dispose);

        // Log in first
        await container
            .read(authNotifierProvider.notifier)
            .login('a@b.com', 'password123');
        expect(container.read(authNotifierProvider), isA<AuthAuthenticated>());

        // Insert test data into the local DB to verify it's preserved
        final db = container.read(databaseProvider);
        final now = DateTime.now();
        await db.profilesDao.upsert(
          ProfilesCompanion.insert(
            id: 'test-profile-c1',
            name: 'Preserved Profile',
            userId: 'user-c1',
            createdAt: now,
            updatedAt: now,
            syncStatus: const Value('pending'),
          ),
        );
        final profilesBefore = await db.profilesDao.getByUserId('user-c1');
        expect(profilesBefore, isNotEmpty);

        // Call clearSession (simulates session expiry path)
        await container.read(authNotifierProvider.notifier).clearSession();

        // State transitions to unauthenticated
        expect(
          container.read(authNotifierProvider),
          isA<AuthUnauthenticated>(),
        );

        // Local data is PRESERVED — this is the critical assertion for C-1
        final profilesAfter = await db.profilesDao.getByUserId('user-c1');
        expect(profilesAfter.length, profilesBefore.length);
      },
    );
  });

  // A refresh credential is required before an expired access token can resume.
  group('AuthNotifier.restoreSession() without a refresh session', () {
    test('does not authenticate when no refresh credential remains', () async {
      // An absent access token plus an empty refresh token cannot resume.
      final ts = FakeTokenService(userId: 'expired-user', refreshToken: '');
      final container = await makeContainer(
        fakeRepo: FakeAuthRepository(),
        tokenService: ts,
      );
      addTearDown(container.dispose);

      await container.read(authNotifierProvider.notifier).restoreSession();

      // With the default FakeTokenService returning null access token,
      // JwtUtils.isExpired(null) == true, so both are expired → stays unauthenticated
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    });
  });
}
