import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

class _MemorySecrets implements CredentialSlotStore {
  final values = <String, String>{};
  Completer<void>? deleting;
  Completer<void>? releaseDelete;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (deleting != null && !deleting!.isCompleted) deleting!.complete();
    await releaseDelete?.future;
    values.remove(key);
  }
}

CredentialBundle _bundle(String owner, String token) => CredentialBundle(
  ownerId: owner,
  endpoint: 'https://fictional.test/care',
  accessToken: 'fictional-access-$token',
  refreshToken: 'fictional-refresh-$token',
  expiresAtMillis: DateTime.utc(2030).millisecondsSinceEpoch,
);

void main() {
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late _MemorySecrets store;
  late ProtectedCredentialsRepository credentials;
  setUp(() {
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    store = _MemorySecrets();
    credentials = ProtectedCredentialsRepository(access: access, store: store);
  });
  tearDown(() => db.close());

  test(
    'competing replies use separate slots; loser cannot overwrite or delete winner',
    () async {
      final transition = await access.revokeNetwork();
      final first = await credentials.stage(_bundle('winner', 'one'));
      final second = await credentials.stage(_bundle('loser', 'two'));
      expect(first, isNot(second));
      final activated = await credentials.activate(
        credentialId: first,
        expectedTransition: transition,
        sessionGeneration: 1,
      );
      await expectLater(
        credentials.activate(
          credentialId: second,
          expectedTransition: transition,
          sessionGeneration: 1,
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await credentials.discardUnreferenced(first);
      final read = await credentials.readFor(activated.network);
      expect(read?.credentialId, first);
      expect(read?.bundle.refreshToken, 'fictional-refresh-one');
      expect(store.values, hasLength(1));
      expect((await access.workspaces.deviceState()).networkOwnerId, 'winner');
    },
  );

  test(
    'stale account capability never reads newer account credentials on same endpoint',
    () async {
      final first = await credentials.stage(_bundle('account-a', 'a'));
      final a = await credentials.activate(
        credentialId: first,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 1,
      );
      final second = await credentials.stage(_bundle('account-b', 'b'));
      final b = await credentials.activate(
        credentialId: second,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 2,
      );
      expect(await credentials.readFor(a.network), isNull);
      expect(
        (await credentials.readFor(b.network))?.bundle.refreshToken,
        'fictional-refresh-b',
      );
      expect(await access.revokeIfCurrent(a.network), isFalse);
      expect((await credentials.readFor(b.network))?.credentialId, second);
    },
  );

  test(
    'refresh pointer compare-and-swap and process restoration preserve the actual winner',
    () async {
      final first = await credentials.stage(_bundle('account-a', 'first'));
      final active = await credentials.activate(
        credentialId: first,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 1,
      );
      final refresh = await credentials.stage(
        _bundle('account-a', 'refreshed'),
      );
      final restarted = ProtectedCredentialsRepository(
        access: WorkspaceAccessRepository(db),
        store: store,
      );
      expect((await restarted.readFor(active.network))?.credentialId, first);
      expect(
        await credentials.replace(
          active.network,
          expectedCredentialId: first,
          stagedCredentialId: refresh,
        ),
        isTrue,
      );
      final stale = await credentials.stage(_bundle('account-a', 'stale'));
      expect(
        await credentials.replace(
          active.network,
          expectedCredentialId: first,
          stagedCredentialId: stale,
        ),
        isFalse,
      );
      expect((await restarted.readFor(active.network))?.credentialId, refresh);
      expect(
        (await restarted.readFor(active.network))?.bundle.refreshToken,
        'fictional-refresh-refreshed',
      );
    },
  );

  test(
    'discard is durably claimed before secure deletion; discarded candidate cannot activate',
    () async {
      final transition = await access.revokeNetwork();
      final candidate = await credentials.stage(
        _bundle('account-a', 'candidate'),
      );
      store.deleting = Completer<void>();
      store.releaseDelete = Completer<void>();
      final discard = credentials.discardUnreferenced(candidate);
      await store.deleting!.future;
      final activation = credentials.activate(
        credentialId: candidate,
        expectedTransition: transition,
        sessionGeneration: 1,
      );
      store.deleting = null;
      store.releaseDelete!.complete();
      await expectLater(activation, throwsA(isA<WorkspaceAccessFailure>()));
      await discard;
      expect((await access.workspaces.deviceState()).networkOwnerId, isNull);
    },
  );

  test(
    'malformed or wrong-owner bundle cannot become usable credentials',
    () async {
      final slot = await credentials.stage(_bundle('account-a', 'a'));
      final active = await credentials.activate(
        credentialId: slot,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 1,
      );
      final key = store.values.keys.single;
      store.values[key] = _bundle('other-account', 'other').encode();
      expect(await credentials.readFor(active.network), isNull);
      store.values[key] = 'truncated';
      await expectLater(
        credentials.readFor(active.network),
        throwsFormatException,
      );
      expect((await access.workspaces.deviceState()).networkCredentialId, slot);
      expect(
        _bundle('account-a', 'secret').toString(),
        isNot(contains('secret')),
      );
    },
  );
}
