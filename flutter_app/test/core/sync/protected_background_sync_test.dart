import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/installation_key_repository.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/auth/credential_refresh_factory.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/protected_background_sync.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

class _Store implements CredentialSlotStore {
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

class _Transport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(
        options.path == '/capabilities'
            ? {}
            : {
                'profiles': [
                  {
                    'id': 'fictional-person',
                    'name': 'Fictional person',
                    'avatarEmoji': '🙂',
                    'createdAt': '2026-09-30T00:00:00Z',
                    'updatedAt': '2026-09-30T00:00:00Z',
                    'isActive': true,
                  },
                ],
              },
      ),
      options.path == '/capabilities' ? 404 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://fictional.test/care';
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late ProtectedCredentialsRepository credentials;
  late InstallationKeyRepository keys;
  late _Transport transport;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://unbound.test',
      'current_user_id': 'unbound',
      'active_user_id': 'unbound',
      'session_generation': 99,
    });
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    final store = _Store();
    credentials = ProtectedCredentialsRepository(access: access, store: store);
    keys = InstallationKeyRepository(access: access, store: store);
    transport = _Transport();
    await access.configureEndpoint(endpoint);
  });
  tearDown(() => db.close());
  Future<void> login({bool expired = false}) async {
    final slot = await credentials.stage(
      CredentialBundle(
        ownerId: 'fictional-account',
        endpoint: endpoint,
        accessToken: 'fictional-access',
        refreshToken: 'fictional-refresh',
        expiresAtMillis: expired
            ? 1
            : DateTime.now()
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

  ProtectedBackgroundSync runner({
    Future<void> Function()? afterResponse,
    Future<void> Function()? effects,
    Future<void> Function()? sweep,
    Future<void> Function(String ownerId)? recordSuccess,
  }) => ProtectedBackgroundSync(
    access: access,
    credentials: credentials,
    keys: keys,
    isOnline: () async => true,
    clientFactory: (tokens, refresh, onAuthFailure) {
      final client = ApiClient(
        baseUrl: '${tokens.endpoint}/api/v1',
        tokenService: tokens,
        onAuthFailure: onAuthFailure,
        scopedRefresh: refresh,
      );
      client.dio.httpClientAdapter = transport;
      if (afterResponse != null) {
        client.dio.interceptors.add(
          InterceptorsWrapper(
            onResponse: (response, handler) async {
              if (response.requestOptions.path == '/profiles') {
                await afterResponse();
              }
              handler.next(response);
            },
          ),
        );
      }
      return client;
    },
    publishEffects: effects == null ? null : (_) => effects(),
    sweepMisses: sweep,
    recordSuccess: recordSuccess,
  );
  test(
    'legacy preference identity alone cannot start headless networking',
    () async {
      expect(await runner().run(), isFalse);
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'headless client uses protected capability despite contradictory mirrors',
    () async {
      await login();
      var effects = 0;
      expect(
        await runner(
          effects: () async {
            effects++;
          },
        ).run(),
        isTrue,
      );
      expect(transport.requests, isNotEmpty);
      expect(
        transport.requests.every(
          (request) => request.uri.toString().startsWith('$endpoint/api/v1/'),
        ),
        isTrue,
      );
      expect(
        transport.requests.every(
          (request) => request.path == '/capabilities'
              ? !request.headers.containsKey('Authorization')
              : request.headers['Authorization'] == 'Bearer fictional-access',
        ),
        isTrue,
      );
      expect(effects, 1);
      expect(
        (await db.profilesDao.getByUserId('fictional-account')).single.id,
        'fictional-person',
      );
      expect(transport.closed, isTrue);
    },
  );
  test(
    'revocation after validated response blocks headless care publication and effects',
    () async {
      await login();
      var effects = 0;
      await expectLater(
        runner(
          afterResponse: () async {
            await access.revokeNetwork();
          },
          effects: () async {
            effects++;
          },
        ).run(),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(effects, 0);
      expect(transport.closed, isTrue);
      expect(await db.profilesDao.getByUserId('fictional-account'), isEmpty);
    },
  );
  test('records overdue doses before anything is sent', () async {
    await login();
    int? requestsWhenSwept;
    var sweeps = 0;
    expect(
      await runner(
        sweep: () async {
          sweeps++;
          requestsWhenSwept = transport.requests.length;
        },
      ).run(),
      isTrue,
    );
    expect(sweeps, 1);
    expect(requestsWhenSwept, 0);
    expect(transport.requests, isNotEmpty);
  });
  test('a finished sync is recorded for the app to show', () async {
    await login();
    final recorded = <String>[];
    expect(
      await runner(recordSuccess: (owner) async => recorded.add(owner)).run(),
      isTrue,
    );
    expect(recorded, ['fictional-account']);
  });
  test('a failed recording does not undo the completed sync', () async {
    await login();
    var effects = 0;
    expect(
      await runner(
        recordSuccess: (_) async => throw StateError('fictional prefs'),
        effects: () async => effects++,
      ).run(),
      isTrue,
    );
    expect(effects, 1);
  });
  test('a failed missed-dose sweep does not stop the sync', () async {
    await login();
    expect(
      await runner(
        sweep: () async => throw StateError('fictional sweep failure'),
      ).run(),
      isTrue,
    );
    expect(transport.requests, isNotEmpty);
  });
  test('optional projection failure does not undo completed sync', () async {
    await login();
    expect(
      await runner(
        effects: () async => throw StateError('fictional platform failure'),
      ).run(),
      isTrue,
    );
    expect(transport.closed, isTrue);
  });
  test(
    'hard headless refresh rejection retires the captured grant only',
    () async {
      await login(expired: true);
      final identity = ProjectionIdentity.fromContext(
        (await access.currentContext()),
      );
      final localWorkspace = await access.workspaces.ensureLocal();
      final local = (await access.contextForOwner(localWorkspace.ownerUserId))!;
      final directory = await Directory.systemTemp.createTemp(
        'fictional-headless-reject-',
      );
      final refreshDio = Dio(BaseOptions(baseUrl: '$endpoint/api/v1'));
      addTearDown(() async {
        refreshDio.close(force: true);
        await directory.delete(recursive: true);
      });
      refreshDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/capabilities') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'apiNamespace': 'v1',
                    'contracts': <String, dynamic>{},
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 401,
                  data: {'code': 'AUTH_SESSION_REVOKED'},
                ),
              ),
            );
          },
        ),
      );
      final retired = <ProjectionIdentity>[];
      var publications = 0;
      final run = ProtectedBackgroundSync(
        access: access,
        credentials: credentials,
        keys: keys,
        isOnline: () async => true,
        clientFactory: (tokens, refresh, onAuthFailure) {
          final client = ApiClient(
            baseUrl: '${tokens.endpoint}/api/v1',
            tokenService: tokens,
            onAuthFailure: onAuthFailure,
            scopedRefresh: () async => createCredentialRefreshCoordinator(
              credentials: credentials,
              keys: keys,
              endpoint: endpoint,
              capability: tokens.capability,
              gate: NativeCredentialRefreshGate(
                directory: directory,
                syncDirectory: (_) async {},
              ),
              refreshDio: refreshDio,
            ),
          );
          client.dio.httpClientAdapter = transport;
          return client;
        },
        publishEffects: (_) async {
          publications++;
        },
        retireEffects: (captured) async {
          retired.add(captured);
        },
      );
      expect(await run.run(), isFalse);
      expect(await identity.resolve(access), isNull);
      await access.requireCurrent(local);
      expect(retired, [identity]);
      expect(publications, 0);
      expect(transport.requests.map((r) => r.path), ['/capabilities']);
      expect(transport.closed, isTrue);
    },
  );
  test(
    'preference load failure still attempts captured widget retirement',
    () async {
      var widgetAttempts = 0;
      var reminderAttempts = 0;
      await expectLater(
        retireBackgroundProjections(
          loadPreferences: () async =>
              throw StateError('fictional preference failure'),
          retireReminders: (_) async {
            reminderAttempts++;
          },
          retireWidget: () async {
            widgetAttempts++;
          },
        ),
        throwsStateError,
      );
      expect(reminderAttempts, 0);
      expect(widgetAttempts, 1);
    },
  );
  test(
    'headless restart attempts retirement without an authenticated account',
    () async {
      var recoveries = 0;
      final run = ProtectedBackgroundSync(
        access: access,
        credentials: credentials,
        keys: keys,
        recoverEffects: () async {
          recoveries++;
        },
      );
      expect(await run.run(), isFalse);
      expect(recoveries, 1);
      expect(transport.requests, isEmpty);
    },
  );
}
