import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/api/scoped_auth_interceptor.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/auth/installation_key_repository.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';

class _MemorySecrets implements CredentialSlotStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://fictional.test/care';
  const outcomes = {
    CredentialRefreshOutcome.stale: 'credential_refresh_stale',
    CredentialRefreshOutcome.busy: 'credential_refresh_busy',
    CredentialRefreshOutcome.uncertain: 'credential_refresh_uncertain',
    CredentialRefreshOutcome.rejected: 'credential_refresh_rejected',
    CredentialRefreshOutcome.installationRequired:
        'credential_refresh_installation_required',
    CredentialRefreshOutcome.accountDeleted:
        'credential_refresh_account_deleted',
  };

  for (final preflight in [true, false]) {
    for (final entry in outcomes.entries) {
      test(
        '${entry.key.name} remains distinct after ${preflight ? 'expiry' : 'HTTP 401'}',
        () async {
          final db = AppDatabase.forTesting();
          final directory = await Directory.systemTemp.createTemp(
            'fictional-refresh-diagnostics-',
          );
          final previousDebugPrint = debugPrint;
          final messages = <String>[];
          debugPrint = (String? message, {int? wrapWidth}) {
            if (message != null) messages.add(message);
          };
          addTearDown(() async {
            debugPrint = previousDebugPrint;
            await db.close();
            await directory.delete(recursive: true);
          });
          final access = WorkspaceAccessRepository(db);
          await access.configureEndpoint(endpoint);
          final store = _MemorySecrets();
          final credentials = ProtectedCredentialsRepository(
            access: access,
            store: store,
          );
          final slot = await credentials.stage(
            CredentialBundle(
              ownerId: 'fictional-owner',
              endpoint: endpoint,
              accessToken: 'fictional-access',
              refreshToken: 'fictional-refresh',
              expiresAtMillis: preflight
                  ? 1
                  : DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch,
            ),
          );
          final capability = (await credentials.activate(
            credentialId: slot,
            expectedTransition: await access.revokeNetwork(),
            sessionGeneration: 1,
          )).network;
          final coordinator = CredentialRefreshCoordinator(
            credentials: credentials,
            gate: NativeCredentialRefreshGate(
              directory: directory,
              syncDirectory: (_) async {},
            ),
            request: (_) async {
              if (entry.key == CredentialRefreshOutcome.uncertain) {
                throw const SocketException('fictional lost response');
              }
              if (entry.key == CredentialRefreshOutcome.rejected) {
                throw const CredentialRefreshRejected();
              }
              throw CredentialRefreshNotConsumed(entry.key);
            },
          );
          final tokens = ScopedTokenService(
            credentials: credentials,
            keys: InstallationKeyRepository(access: access, store: store),
            endpoint: endpoint,
            capability: capability,
            installation: access.captureInstallation(endpoint),
          );
          var authFailures = 0;
          var deletions = 0;
          var sends = 0;
          final dio = Dio(BaseOptions(baseUrl: '$endpoint/api/v1'));
          addTearDown(() => dio.close(force: true));
          dio.interceptors.add(
            ScopedAuthInterceptor(
              dio: dio,
              tokens: tokens,
              baseUrl: '$endpoint/api/v1',
              onAuthFailure: () => authFailures++,
              onAccountDeleted: () => deletions++,
              refresh: () async => coordinator,
            ),
          );
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                sends++;
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response<void>(
                      requestOptions: options,
                      statusCode: 401,
                    ),
                  ),
                  true,
                );
              },
            ),
          );

          await expectLater(
            dio.get<void>('/sync/profiles'),
            throwsA(isA<DioException>()),
          );

          expect(sends, preflight ? 0 : 1);
          expect(
            authFailures,
            entry.key == CredentialRefreshOutcome.rejected ? 1 : 0,
          );
          expect(
            deletions,
            entry.key == CredentialRefreshOutcome.accountDeleted ? 1 : 0,
          );
          expect(
            messages.where(
              (line) => line.contains('connection_access_refused'),
            ),
            [
              '[DBG][SyncDiag] {"event":"connection_access_refused",'
                  '"route":"/sync/:component","reason":"${entry.value}"}',
            ],
          );
          expect(messages.join(), isNot(contains('fictional-owner')));
          expect(messages.join(), isNot(contains('fictional-refresh')));
        },
      );
    }
  }
}
