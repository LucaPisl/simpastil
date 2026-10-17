//
// Integration-style unit tests verifying that:
//   1. AuthNotifier.login() triggers pullFromServer() and populates the DB.
//   2. Sign-out revokes connected access while retaining the complete care collection.
//
// Uses:
//   - AppDatabase.forTesting() (in-memory Drift DB — no filesystem)
//   - mocktail for faking Dio HTTP calls
//   - FakeAuthRepository / FakeTokenService for auth layer isolation

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:simpastil/core/api/api_client.dart';
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
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/auth_repository.dart';

// ── Mocks ─────────────────────────────────────────────────────────────────────

class _MockDio extends Mock implements Dio {}

class _MockApiClient extends Mock implements ApiClient {
  _MockApiClient(this._dio);
  final Dio _dio;

  @override
  Dio get dio => _dio;
}

// ── Fakes ─────────────────────────────────────────────────────────────────────

/// Minimal TokenService that satisfies the interface without FlutterSecureStorage.
class _FakeTokenService implements TokenService {
  String? _refresh;

  @override
  Future<String?> getAccessToken() async => null;

  @override
  Future<String?> getRefreshToken() async => _refresh;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresIn,
  }) async {
    _refresh = refreshToken;
  }

  @override
  Future<void> clearTokens() async {
    _refresh = null;
  }

  @override
  Future<bool> isAuthenticated() async => _refresh != null;

  @override
  Future<bool> hasSession() async => _refresh != null;

  @override
  Future<String?> getUserId() async => null;

  @override
  Future<String?> getApiKey() async => null;

  @override
  Future<void> saveApiKey(String key) async {}

  @override
  Future<void> clearApiKey() async {}

  @override
  Future<void> clearSessionTokens() async {}
}

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

late ProtectedCredentialsRepository testCredentials;
late Directory authDirectory;

class _FakeAuthRepository implements AuthRepository {
  String userIdToReturn;
  _FakeAuthRepository({this.userIdToReturn = 'user-uuid-1'});

  @override
  Future<Result<LoginResult>> login(String email, String password) async => Ok(
    LoginSuccess(
      userIdToReturn,
      credentialId: await testCredentials.stage(
        CredentialBundle(
          ownerId: userIdToReturn,
          endpoint: 'https://fictional.test',
          accessToken: 'fictional-access',
          refreshToken: 'fictional-refresh',
          expiresAtMillis: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      ),
    ),
  );

  @override
  Future<Result<void>> register(String email, String password) async =>
      const Ok(null);

  @override
  Future<Result<void>> logout(String refreshToken) async => const Ok(null);

  @override
  Future<Result<void>> changePassword(String c, String n) async =>
      const Ok(null);

  @override
  Future<Result<void>> setDeviceName(String deviceName) async => const Ok(null);

  @override
  Future<Result<LoginSuccess>> challenge2fa(
    String challengeToken,
    String code,
  ) async => const Ok(LoginSuccess('user-uuid-1'));

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

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _kUserId = 'user-uuid-1';
const _kProfileId = 'profile-uuid-1';
const _kPillId = 'pill-uuid-1';
const _kScheduleId = 'schedule-uuid-1';
const _kLogId = 'log-uuid-1';

final _profileFixture = {
  'id': _kProfileId,
  'name': 'Alice',
  'avatarEmoji': '👤',
  'isActive': true,
  'createdAt': '2025-01-01T00:00:00.000Z',
  'updatedAt': '2025-01-01T00:00:00.000Z',
};

final _pillFixture = {
  'id': _kPillId,
  'profileId': _kProfileId,
  'name': 'Aspirin',
  'dosage': '100mg',
  'notes': null,
  'color': null,
  'createdAt': '2025-01-01T00:00:00.000Z',
  'updatedAt': '2025-01-01T00:00:00.000Z',
};

final _scheduleFixture = {
  'id': _kScheduleId,
  'pillId': _kPillId,
  'hour': 8,
  'minute': 0,
  'frequency': 'daily',
  'frequencyDays': null,
  'isActive': true,
  'createdAt': '2025-01-01T00:00:00.000Z',
  'updatedAt': '2025-01-01T00:00:00.000Z',
};

final _logFixture = {
  'id': _kLogId,
  'scheduleId': _kScheduleId,
  'scheduledAt': '2025-01-02T08:00:00.000Z',
  'takenAt': null,
  'status': 'taken',
  'createdAt': '2025-01-02T08:00:00.000Z',
};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Stubs [mockDio] to return server fixture data for all four pull endpoints.
void _stubDioSuccess(_MockDio mockDio) {
  _stubCapabilitiesAbsent(mockDio);

  when(
    () => mockDio.get<Map<String, dynamic>>(
      '/profiles',
      queryParameters: any(named: 'queryParameters'),
      options: any(named: 'options'),
      cancelToken: any(named: 'cancelToken'),
      onReceiveProgress: any(named: 'onReceiveProgress'),
    ),
  ).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/profiles'),
      data: {
        'profiles': [_profileFixture],
      },
      statusCode: 200,
    ),
  );

  when(
    () => mockDio.get<Map<String, dynamic>>(
      '/profiles/$_kProfileId/pills',
      queryParameters: any(named: 'queryParameters'),
      options: any(named: 'options'),
      cancelToken: any(named: 'cancelToken'),
      onReceiveProgress: any(named: 'onReceiveProgress'),
    ),
  ).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/profiles/$_kProfileId/pills'),
      data: {
        'pills': [_pillFixture],
      },
      statusCode: 200,
    ),
  );

  when(
    () => mockDio.get<Map<String, dynamic>>(
      '/pills/$_kPillId/schedules',
      queryParameters: any(named: 'queryParameters'),
      options: any(named: 'options'),
      cancelToken: any(named: 'cancelToken'),
      onReceiveProgress: any(named: 'onReceiveProgress'),
    ),
  ).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/pills/$_kPillId/schedules'),
      data: {
        'schedules': [_scheduleFixture],
      },
      statusCode: 200,
    ),
  );

  when(
    () => mockDio.get<Map<String, dynamic>>(
      '/profiles/$_kProfileId/logs',
      queryParameters: any(named: 'queryParameters'),
      options: any(named: 'options'),
      cancelToken: any(named: 'cancelToken'),
      onReceiveProgress: any(named: 'onReceiveProgress'),
    ),
  ).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/profiles/$_kProfileId/logs'),
      data: {
        'logs': [_logFixture],
      },
      statusCode: 200,
    ),
  );
}

void _stubCapabilitiesAbsent(_MockDio mockDio) {
  when(() => mockDio.get<Map<String, dynamic>>('/capabilities')).thenThrow(
    DioException(
      requestOptions: RequestOptions(path: '/capabilities'),
      response: Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/capabilities'),
        statusCode: 404,
      ),
      type: DioExceptionType.badResponse,
    ),
  );
}

/// Builds a [ProviderContainer] wired with:
///   - an in-memory [AppDatabase]
///   - [_MockApiClient] / [_MockDio]
///   - [_FakeAuthRepository] + [_FakeTokenService]
ProviderContainer _buildContainer({
  required AppDatabase db,
  required _MockApiClient apiClient,
  required SharedPreferences preferences,
  AuthRepository? authRepo,
  TokenService? tokenService,
}) {
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      sharedPreferencesProvider.overrideWithValue(preferences),
      apiClientProvider.overrideWithValue(apiClient),
      syncServiceProvider.overrideWithValue(
        SyncService(db: db, dio: apiClient.dio, isOnline: () async => true),
      ),
      sessionRuntimeCoordinatorProvider.overrideWith((ref) {
        final generations = ref.read(sessionGenerationRepositoryProvider);
        final autoSync = ref.read(autoSyncServiceProvider);
        return SessionRuntimeCoordinator(
          generations: generations,
          startSync: (userId, generation) =>
              autoSync.start(userId, generation: generation),
          stopSync: autoSync.stop,
          drainSync: autoSync.drain,
          scheduleStart: (start) => start(),
        );
      }),
      if (authRepo != null) authRepositoryProvider.overrideWithValue(authRepo),
      if (authRepo != null)
        authTransitionRepositoryFactoryProvider.overrideWithValue(
          (_) => authRepo,
        ),
      protectedCredentialsRepositoryProvider.overrideWithValue(testCredentials),
      credentialRefreshGateProvider.overrideWithValue(
        () async => NativeCredentialRefreshGate(
          directory: authDirectory,
          syncDirectory: (_) async {},
        ),
      ),
      sessionRemoteRevocationProvider.overrideWithValue((_, _) async {}),
      if (tokenService != null)
        tokenServiceProvider.overrideWithValue(tokenService),
    ],
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late _MockDio mockDio;
  late _MockApiClient mockApiClient;
  late AppDatabase db;
  late _FakeAuthRepository fakeRepo;
  late _FakeTokenService fakeTokenService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://fictional.test',
    });
    preferences = await SharedPreferences.getInstance();
    mockDio = _MockDio();
    mockApiClient = _MockApiClient(mockDio);
    db = AppDatabase.forTesting();
    final access = WorkspaceAccessRepository(db);
    await access.configureEndpoint('https://fictional.test');
    testCredentials = ProtectedCredentialsRepository(
      access: access,
      store: _MemorySecrets(),
    );
    authDirectory = await Directory.systemTemp.createTemp(
      'fictional-pull-auth-',
    );
    fakeRepo = _FakeAuthRepository(userIdToReturn: _kUserId);
    fakeTokenService = _FakeTokenService();
  });

  tearDown(() async {
    await db.close();
    await authDirectory.delete(recursive: true);
  });

  group('BUG-01 — pull on login', () {
    test('profile appears in DB after successful login', () async {
      _stubDioSuccess(mockDio);

      final container = _buildContainer(
        db: db,
        apiClient: mockApiClient,
        preferences: preferences,
        authRepo: fakeRepo,
        tokenService: fakeTokenService,
      );
      addTearDown(container.dispose);

      final result = await container
          .read(authNotifierProvider.notifier)
          .login('user@example.com', 'password');
      await container.read(autoSyncServiceProvider).drain();

      expect(result, isA<Ok<void>>());

      // Profile must now be present in the local DB.
      final profiles = await db.profilesDao.getByUserId(_kUserId);
      expect(profiles, hasLength(1));
      expect(profiles.first.id, equals(_kProfileId));
      expect(profiles.first.name, equals('Alice'));
      expect(profiles.first.syncStatus, equals('synced'));
    });

    test(
      'pill, schedule and dose_log appear in DB after successful login',
      () async {
        _stubDioSuccess(mockDio);

        final container = _buildContainer(
          db: db,
          apiClient: mockApiClient,
          preferences: preferences,
          authRepo: fakeRepo,
          tokenService: fakeTokenService,
        );
        addTearDown(container.dispose);

        await container
            .read(authNotifierProvider.notifier)
            .login('user@example.com', 'password');
        await container.read(autoSyncServiceProvider).drain();

        final pills = await db.pillsDao.getByProfileId(_kProfileId);
        expect(pills, hasLength(1));
        expect(pills.first.id, equals(_kPillId));
        expect(pills.first.dosage, equals('100mg'));

        final schedules = await db.schedulesDao.getByPillId(_kPillId);
        expect(schedules, hasLength(1));
        expect(schedules.first.id, equals(_kScheduleId));
        expect(schedules.first.hour, equals(8));

        final logs = await db.doseLogsDao.getByScheduleId(_kScheduleId);
        expect(logs, hasLength(1));
        expect(logs.first.id, equals(_kLogId));
        expect(logs.first.status, equals('taken'));
      },
    );

    test('login succeeds even when pull network request fails', () async {
      // No stubs — Dio will throw ConnectionError.
      when(
        () => mockDio.get<Map<String, dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/profiles'),
          type: DioExceptionType.connectionError,
        ),
      );
      _stubCapabilitiesAbsent(mockDio);

      final container = _buildContainer(
        db: db,
        apiClient: mockApiClient,
        preferences: preferences,
        authRepo: fakeRepo,
        tokenService: fakeTokenService,
      );
      addTearDown(container.dispose);

      final result = await container
          .read(authNotifierProvider.notifier)
          .login('user@example.com', 'password');
      await container.read(autoSyncServiceProvider).drain();

      // Auth succeeds; pull failure is swallowed.
      expect(result, isA<Ok<void>>());
      expect(
        container.read(authNotifierProvider),
        isA<AuthAuthenticated>().having(
          (state) => state.userId,
          'owner',
          _kUserId,
        ),
      );
    });

    test(
      'login session remains established when background pull returns 401',
      () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(
            '/profiles',
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          ),
        ).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/profiles'),
            response: Response(
              requestOptions: RequestOptions(path: '/profiles'),
              statusCode: 401,
            ),
            type: DioExceptionType.badResponse,
          ),
        );
        _stubCapabilitiesAbsent(mockDio);

        final container = _buildContainer(
          db: db,
          apiClient: mockApiClient,
          preferences: preferences,
          authRepo: fakeRepo,
          tokenService: fakeTokenService,
        );
        addTearDown(container.dispose);

        final result = await container
            .read(authNotifierProvider.notifier)
            .login('user@example.com', 'password');
        await container.read(autoSyncServiceProvider).drain();

        expect(result, isA<Ok<void>>());
        expect(
          container.read(authNotifierProvider),
          isA<AuthAuthenticated>().having(
            (state) => state.userId,
            'owner',
            _kUserId,
          ),
        );
      },
    );
  });

  group('connected care retained on sign-out', () {
    test('sign-out retains care and revokes its access', () async {
      _stubDioSuccess(mockDio);

      final container = _buildContainer(
        db: db,
        apiClient: mockApiClient,
        preferences: preferences,
        authRepo: fakeRepo,
        tokenService: fakeTokenService,
      );
      addTearDown(container.dispose);

      // Login to populate DB.
      await container
          .read(authNotifierProvider.notifier)
          .login('user@example.com', 'password');
      await container.read(autoSyncServiceProvider).drain();

      // Verify data is present.
      final profilesBefore = await db.profilesDao.getByUserId(_kUserId);
      expect(profilesBefore, hasLength(1));

      // Logout.
      await container.read(authNotifierProvider.notifier).logout();

      // Care remains in its original connected collection.
      final profilesAfter = await db.profilesDao.getByUserId(_kUserId);
      expect(profilesAfter, profilesBefore);

      final pillsAfter = await db.pillsDao.getByProfileId(_kProfileId);
      expect(pillsAfter, hasLength(1));
      final access = WorkspaceAccessRepository(db);
      expect(await access.contextForOwner(_kUserId), isNull);
      expect((await access.currentContext()).isLocal, isTrue);
    });

    test('state is AuthUnauthenticated after logout', () async {
      _stubDioSuccess(mockDio);

      final container = _buildContainer(
        db: db,
        apiClient: mockApiClient,
        preferences: preferences,
        authRepo: fakeRepo,
        tokenService: fakeTokenService,
      );
      addTearDown(container.dispose);

      await container
          .read(authNotifierProvider.notifier)
          .login('user@example.com', 'password');
      await container.read(autoSyncServiceProvider).drain();
      await container.read(authNotifierProvider.notifier).logout();

      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    });
  });
}
