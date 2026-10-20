import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import '../../helpers/held_provider_read.dart';

class _Secrets implements CredentialSlotStore {
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

class _OldGlobalTokens extends TokenService {
  String accessToken = 'fictional-access-a';
  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<String?> getApiKey() async => null;
}

class _NoSessionScopedTokens extends Mock implements ScopedTokenService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://fictional.test/care';
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late ProtectedCredentialsRepository credentials;
  late ProviderContainer container;
  late _OldGlobalTokens oldTokens;
  Future<void> login(String owner) async {
    final slot = await credentials.stage(
      CredentialBundle(
        ownerId: owner,
        endpoint: endpoint,
        accessToken: 'fictional-access-$owner',
        refreshToken: 'fictional-refresh-$owner',
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
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    await access.configureEndpoint(endpoint);
    credentials = ProtectedCredentialsRepository(
      access: access,
      store: _Secrets(),
    );
    oldTokens = _OldGlobalTokens();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        protectedCredentialsRepositoryProvider.overrideWithValue(credentials),
        tokenServiceProvider.overrideWithValue(oldTokens),
      ],
    );
    await login('a');
    // Riverpod 3 pauses a stream provider nobody listens to.
    container.listen(networkCapabilityProvider, (_, _) {});
    await container.readHeld(networkCapabilityProvider);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  List<RequestOptions> capture(ApiClient client) {
    final requests = <RequestOptions>[];
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        },
      ),
    );
    return requests;
  }

  Future<void> attempt(ApiClient client, String path) async {
    try {
      await client.dio.get<void>(path);
    } on DioException {
      /* no real HTTP */
    }
  }

  test(
    'retained A client never acquires B credentials on the same server',
    () async {
      final retained = container.read(apiClientProvider);
      final requests = capture(retained);
      await attempt(retained, '/profiles');
      expect(
        requests.single.headers['Authorization'],
        'Bearer fictional-access-a',
      );
      requests.clear();
      await login('b');
      oldTokens.accessToken = 'fictional-access-b';
      await attempt(retained, '/profiles');
      expect(
        requests,
        isEmpty,
        reason:
            'A retained client must reject before handing any B credential to transport',
      );
    },
  );
  test(
    'protected client refuses a URL outside its installation path',
    () async {
      final client = container.read(apiClientProvider);
      final requests = capture(client);
      await attempt(client, 'https://fictional.test/other/api/v1/profiles');
      expect(requests, isEmpty);
    },
  );

  test(
    'public capability discovery works with a stale scoped session',
    () async {
      final tokens = _NoSessionScopedTokens();
      when(() => tokens.capability).thenReturn(null);
      when(() => tokens.isCurrent()).thenAnswer((_) async => false);
      when(
        () => tokens.scopeRefusalReason(),
      ).thenAnswer((_) async => 'installation_scope_missing');
      when(() => tokens.getApiKey()).thenAnswer((_) async => null);
      final client = ApiClient(
        baseUrl: endpoint,
        tokenService: tokens,
        onAuthFailure: () {},
      );
      final requests = <RequestOptions>[];
      client.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const {'apiNamespace': 'v1'},
              ),
            );
          },
        ),
      );

      await attempt(client, '/profiles');
      expect(
        requests,
        isEmpty,
        reason: 'account data still requires a session',
      );

      final response = await client.dio.get<Map<String, dynamic>>(
        '/capabilities',
      );

      expect(requests, hasLength(1));
      expect(requests.single.path, '/capabilities');
      expect(requests.single.headers['Authorization'], isNull);
      expect(requests.single.headers['X-Api-Key'], isNull);
      expect(response.data?['apiNamespace'], 'v1');
    },
  );
}
