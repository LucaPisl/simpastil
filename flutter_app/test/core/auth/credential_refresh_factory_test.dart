import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/auth/credential_refresh_factory.dart';
import 'package:simpastil/core/auth/installation_key_repository.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';

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

void main() {
  for (final discovery in ['offline', 'legacy', 'recovery']) {
    test(
      'capability $discovery cannot downgrade an attempted recovery',
      () async {
        final db = AppDatabase.forTesting();
        final directory = await Directory.systemTemp.createTemp(
          'fictional-negotiation-',
        );
        addTearDown(() async {
          await db.close();
          await directory.delete(recursive: true);
        });
        final access = WorkspaceAccessRepository(db);
        const endpoint = 'https://fictional.test';
        await access.configureEndpoint(endpoint);
        final store = _Secrets();
        final credentials = ProtectedCredentialsRepository(
          access: access,
          store: store,
        );
        final slot = await credentials.stage(
          const CredentialBundle(
            ownerId: 'a',
            endpoint: endpoint,
            accessToken: 'fictional-expired-access',
            refreshToken: 'fictional-refresh',
            expiresAtMillis: 1,
          ),
        );
        final capability = (await credentials.activate(
          credentialId: slot,
          expectedTransition: await access.revokeNetwork(),
          sessionGeneration: 1,
        )).network;
        final requests = <String>[];
        final dio = Dio(BaseOptions(baseUrl: '$endpoint/api/v1'));
        String? proposal;
        var attempts = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options.path);
              if (options.path == '/capabilities' && discovery == 'recovery') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'apiNamespace': 'v1',
                      'contracts': {'refreshRecovery': 1},
                    },
                  ),
                );
                return;
              }
              if (options.path == '/auth/refresh' ||
                  options.path == '/auth/refresh/recoverable' &&
                      ++attempts > 1) {
                final data = options.data as Map;
                if (data['nextRefreshToken'] != null) {
                  expect(data['nextRefreshToken'], proposal);
                }
                final claims = base64Url.encode(
                  utf8.encode(jsonEncode({'sub': 'a', 'exp': 2000000000})),
                );
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'accessToken': 'header.$claims.signature',
                      'refreshToken':
                          data['nextRefreshToken'] ?? 'fictional-new-refresh',
                    },
                  ),
                );
                return;
              }
              if (options.path == '/auth/refresh/recoverable') {
                proposal = (options.data as Map)['nextRefreshToken'] as String;
              }
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: discovery == 'offline'
                      ? DioExceptionType.connectionError
                      : DioExceptionType.badResponse,
                  response: discovery == 'offline'
                      ? null
                      : Response(requestOptions: options, statusCode: 404),
                ),
              );
            },
          ),
        );
        final gate = NativeCredentialRefreshGate(
          directory: directory,
          syncDirectory: (_) async {},
        );
        CredentialRefreshCoordinator coordinator() =>
            createCredentialRefreshCoordinator(
              credentials: credentials,
              keys: InstallationKeyRepository(access: access, store: store),
              gate: gate,
              endpoint: endpoint,
              capability: capability,
              refreshDio: dio,
            );
        final first = await coordinator().refresh(capability);
        if (discovery == 'offline') {
          expect(first, CredentialRefreshOutcome.busy);
          expect(requests, ['/capabilities']);
          expect(await gate.run((j) => j.currentAttempt()), isNull);
        } else if (discovery == 'legacy') {
          expect(first, CredentialRefreshOutcome.ready);
          expect(requests, ['/capabilities', '/auth/refresh']);
        } else {
          expect(first, CredentialRefreshOutcome.busy);
          expect(
            await coordinator().refresh(capability),
            CredentialRefreshOutcome.ready,
          );
          expect(requests, [
            '/capabilities',
            '/auth/refresh/recoverable',
            '/auth/refresh/recoverable',
          ]);
        }
      },
    );
  }

  for (final code in ['AUTH_KEY_INVALID', 'AUTH_KEY_REVOKED']) {
    test(
      '$code repairs installation access without revoking offline care',
      () async {
        final db = AppDatabase.forTesting();
        final directory = await Directory.systemTemp.createTemp(
          'fictional-key-rejection-',
        );
        addTearDown(() async {
          await db.close();
          await directory.delete(recursive: true);
        });
        final access = WorkspaceAccessRepository(db);
        const endpoint = 'https://fictional.test/care';
        await access.configureEndpoint(endpoint);
        final store = _Secrets();
        final credentials = ProtectedCredentialsRepository(
          access: access,
          store: store,
        );
        final slot = await credentials.stage(
          const CredentialBundle(
            ownerId: 'a',
            endpoint: endpoint,
            accessToken: 'fictional-expired-access',
            refreshToken: 'fictional-refresh',
            expiresAtMillis: 1,
          ),
        );
        final capability = (await credentials.activate(
          credentialId: slot,
          expectedTransition: await access.revokeNetwork(),
          sessionGeneration: 1,
        )).network;
        final dio = Dio(BaseOptions(baseUrl: '$endpoint/api/v1'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 401,
                    data: {'error': 'Unauthorized', 'code': code},
                  ),
                ),
              );
            },
          ),
        );
        final gate = NativeCredentialRefreshGate(
          directory: directory,
          syncDirectory: (_) async {},
        );
        final coordinator = createCredentialRefreshCoordinator(
          credentials: credentials,
          keys: InstallationKeyRepository(access: access, store: store),
          gate: gate,
          endpoint: endpoint,
          capability: capability,
          refreshDio: dio,
        );
        expect(
          await coordinator.refresh(capability),
          isNot(CredentialRefreshOutcome.rejected),
        );
        expect(await access.contextForOwner('a'), isNotNull);
        expect((await credentials.readFor(capability))?.credentialId, slot);
        expect(await gate.run((journal) => journal.currentAttempt()), isNull);
      },
    );
  }
}
