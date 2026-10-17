import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/auth/installation_key_repository.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/auth/scoped_token_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

class _Store implements CredentialSlotStore {
  final values = <String, String>{};
  bool failDeletes = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('Fictional secure cleanup failure');
    values.remove(key);
  }
}

void main() {
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late _Store store;
  late InstallationKeyRepository keys;
  late ApiClient client;
  late InstallationCapability scope;
  const endpoint = 'https://fictional.test/InstallA';
  setUp(() async {
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    store = _Store();
    await access.configureEndpoint(endpoint);
    keys = InstallationKeyRepository(access: access, store: store);
    scope = (await access.captureInstallation(endpoint))!;
    client = ApiClient(
      baseUrl: '$endpoint/api/v1',
      onAuthFailure: () {},
      tokenService: ScopedTokenService(
        credentials: ProtectedCredentialsRepository(
          access: access,
          store: store,
        ),
        keys: keys,
        endpoint: endpoint,
        capability: null,
        installation: Future.value(scope),
      ),
    );
  });
  tearDown(() async {
    client.dio.close(force: true);
    await db.close();
  });
  void respond(Object data) => client.dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        expect(options.uri.toString(), '$endpoint/api/v1/auth/verify-key');
        expect(options.headers['X-Api-Key'], 'fictional-key-a');
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: data,
          ),
          true,
        );
      },
    ),
  );
  test(
    'verification publishes key and status bound to captured installation',
    () async {
      respond({'status': 'owned'});
      final verified = await client.verifyAndSaveInstallationKey(
        'fictional-key-a',
      );
      expect(verified.status, 'owned');
      expect(verified.installation.epoch, scope.epoch + 1);
      expect(await keys.readFor(verified.installation), 'fictional-key-a');
      expect(await keys.readVerifiedStatusFor(verified.installation), 'owned');
      expect(await keys.readFor(scope), isNull);
    },
  );
  test('late verified A response cannot publish over installation B', () async {
    respond({'status': 'owned'});
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          await access.configureEndpoint('https://fictional.test/InstallB');
          final b = (await access.captureInstallation(
            'https://fictional.test/InstallB',
          ))!;
          await keys.saveFor(b, 'fictional-key-b', verifiedStatus: 'unclaimed');
          handler.next(response);
        },
      ),
    );
    await expectLater(
      client.verifyAndSaveInstallationKey('fictional-key-a'),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    final b = (await access.captureInstallation(
      'https://fictional.test/InstallB',
    ))!;
    expect(await keys.readFor(b), 'fictional-key-b');
    expect(await keys.readVerifiedStatusFor(b), 'unclaimed');
    expect(
      store.values.values.any((value) => value.contains('fictional-key-a')),
      isFalse,
    );
  });
  test('revoked status cannot publish a key', () async {
    respond({'status': 'revoked'});
    await expectLater(
      client.verifyAndSaveInstallationKey('fictional-key-a'),
      throwsA(isA<InstallationKeyRevoked>()),
    );
    expect((await access.workspaces.deviceState()).installationKeyId, isNull);
    expect(store.values, isEmpty);
  });
  for (final status in ['future-status', '', null]) {
    test(
      'unsupported verification status $status preserves the current slot',
      () async {
        respond({'status': status});
        await expectLater(
          client.verifyAndSaveInstallationKey('fictional-key-a'),
          throwsFormatException,
        );
        expect(
          (await access.workspaces.deviceState()).installationKeyId,
          isNull,
        );
        expect(store.values, isEmpty);
      },
    );
  }
  test(
    'cleanup failure after publication still returns the active reviewed key',
    () async {
      final previous = await keys.saveFor(
        scope,
        'fictional-old-key',
        verifiedStatus: 'unclaimed',
      );
      client.dio.close(force: true);
      client = ApiClient(
        baseUrl: '$endpoint/api/v1',
        onAuthFailure: () {},
        tokenService: ScopedTokenService(
          credentials: ProtectedCredentialsRepository(
            access: access,
            store: store,
          ),
          keys: keys,
          endpoint: endpoint,
          capability: null,
          installation: Future.value(previous),
        ),
      );
      respond({'status': 'owned'});
      store.failDeletes = true;
      VerifiedInstallationKey? verified;
      Object? failure;
      try {
        verified = await client.verifyAndSaveInstallationKey('fictional-key-a');
      } on Object catch (error) {
        failure = error;
      }
      final current = (await access.captureInstallation(endpoint))!;
      expect(await keys.readFor(current), 'fictional-key-a');
      expect(await keys.readVerifiedStatusFor(current), 'owned');
      expect(
        failure,
        isNull,
        reason:
            'The new key is active; deferred old cleanup must not report publication failure',
      );
      expect(verified!.installation.epoch, current.epoch);
      final discarded = await (db.select(
        db.installationKeySlots,
      )..where((row) => row.state.equals('discarded'))).get();
      expect(discarded, hasLength(1));
      store.failDeletes = false;
      await keys.discardUnreferenced(discarded.single.id);
      expect(
        store.values.values.any((value) => value.contains('fictional-old-key')),
        isFalse,
      );
    },
  );
  test('old slots do not invent verified status', () async {
    final published = await keys.saveFor(scope, 'fictional-key-a');
    expect(await keys.readFor(published), 'fictional-key-a');
    expect(await keys.readVerifiedStatusFor(published), isNull);
  });
}
