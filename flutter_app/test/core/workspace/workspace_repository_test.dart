import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_repository.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/core/errors/app_error.dart';

void main() {
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late WorkspaceRepository workspaces;
  setUp(() {
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    workspaces = access.workspaces;
  });
  tearDown(() => db.close());

  Future<AuthenticatedWorkspace> authenticate({
    required String ownerId,
    required String endpoint,
    required int expectedNetworkEpoch,
    required int sessionGeneration,
    required String credentialId,
  }) async {
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: credentialId,
            ownerId: ownerId,
            endpoint: canonicalServerEndpoint(endpoint),
            state: 'staged',
            createdAt: DateTime.now(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return access.authenticate(
      ownerId: ownerId,
      endpoint: endpoint,
      expectedNetworkEpoch: expectedNetworkEpoch,
      sessionGeneration: sessionGeneration,
      credentialId: credentialId,
    );
  }

  Future<WorkspaceContext> login(
    String owner,
    String endpoint,
    int generation,
  ) async {
    final epoch = await access.revokeNetwork();
    await authenticate(
      ownerId: owner,
      endpoint: endpoint,
      expectedNetworkEpoch: epoch,
      sessionGeneration: generation,
      credentialId: 'slot-$owner-$generation-$epoch',
    );
    return (await access.contextForOwner(owner))!;
  }

  test(
    'fresh offline workspace has a separate stable author and no credentials',
    () async {
      final first = await access.currentContext();
      final second = await access.currentContext();
      expect(first.workspaceId, second.workspaceId);
      expect(first.authorId, second.authorId);
      expect(first.authorId, isNot(first.ownerUserId));
      expect(first.isLocal, isTrue);
      expect((await workspaces.deviceState()).networkOwnerId, isNull);
      expect(await db.select(db.workspaceAuthors).get(), hasLength(1));
      expect(await db.select(db.pendingOperations).get(), isEmpty);
    },
  );

  test(
    'two people share one author; viewing never changes reminder choice',
    () async {
      final context = await access.currentContext();
      final repo = ProfileRepositoryImpl(
        dao: db.profilesDao,
        pendingOperations: PendingOperationRepository(db),
        userId: context.ownerUserId,
        reconcileProjections: () async {},
        access: access,
        context: context,
      );
      final first = (await repo.create('One', '👤') as Ok<Profile>).value;
      final second = (await repo.create('Two', '👤') as Ok<Profile>).value;
      await db
          .into(db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: first.id,
              enabled: const Value(true),
            ),
          );
      await db
          .into(db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: second.id,
              enabled: const Value(true),
            ),
          );
      await access.viewPerson(context, first.id);
      expect(
        await workspaces.reminderPeople(context.ownerUserId),
        hasLength(2),
      );
      await access.viewPerson(context, null, everyone: true);
      await access.viewPerson(context, second.id);
      expect((await access.currentContext()).authorId, context.authorId);
      expect(
        (await workspaces.byId(context.workspaceId))?.selectedProfileId,
        second.id,
      );
      expect(
        await workspaces.reminderPeople(context.ownerUserId),
        hasLength(2),
      );
      expect(await db.select(db.pendingOperations).get(), isEmpty);
    },
  );

  test(
    'sign-out revokes captured connected capabilities and retains local access',
    () async {
      final local = await access.currentContext();
      final accountA = await login('account-a', 'https://care.test/a', 1);
      final epochBefore = (await workspaces.deviceState()).networkEpoch;
      await access.revokeNetwork();
      expect(
        (await workspaces.deviceState()).networkEpoch,
        greaterThan(epochBefore),
      );
      await expectLater(
        access.requireCurrent(accountA),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await access.requireCurrent(local);
      expect((await access.currentContext()).workspaceId, local.workspaceId);
      final accountB = await login('account-b', 'https://care.test/a', 2);
      expect(accountB.workspaceId, isNot(accountA.workspaceId));
      expect(await access.contextForOwner('account-a'), isNull);
      await access.requireCurrent(local);
    },
  );

  test(
    'same owner UUID from another installation refuses before activation',
    () async {
      final context = await login('occupied-id', 'https://care.test/A', 1);
      final epoch = await access.revokeNetwork();
      await expectLater(
        authenticate(
          ownerId: 'occupied-id',
          endpoint: 'https://care.test/B',
          expectedNetworkEpoch: epoch,
          sessionGeneration: 2,
          credentialId: 'collision-slot',
        ),
        throwsA(
          isA<WorkspaceAccessFailure>().having(
            (failure) => failure.code,
            'code',
            WorkspaceAccessFailureCode.ownerCollision,
          ),
        ),
      );
      expect(
        (await workspaces.byId(context.workspaceId))?.endpoint,
        'https://care.test/A',
      );
      expect((await workspaces.deviceState()).networkOwnerId, isNull);
    },
  );

  test('stale network response cannot activate after transition', () async {
    final stale = await access.revokeNetwork();
    await access.revokeNetwork();
    await expectLater(
      authenticate(
        ownerId: 'late-account',
        endpoint: 'https://care.test',
        expectedNetworkEpoch: stale,
        sessionGeneration: 1,
        credentialId: 'stale-slot',
      ),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(await workspaces.byOwner('late-account'), isNull);
    expect(await db.usersDao.getById('late-account'), isNull);
  });

  test(
    'one authentication transition cannot activate two completions',
    () async {
      final epoch = await access.revokeNetwork();
      await authenticate(
        ownerId: 'winner',
        endpoint: 'https://care.test',
        expectedNetworkEpoch: epoch,
        sessionGeneration: 1,
        credentialId: 'winner-slot',
      );
      await expectLater(
        authenticate(
          ownerId: 'late-completion',
          endpoint: 'https://care.test',
          expectedNetworkEpoch: epoch,
          sessionGeneration: 1,
          credentialId: 'loser-slot',
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect((await workspaces.deviceState()).networkOwnerId, 'winner');
      expect(await db.usersDao.getById('late-completion'), isNull);
    },
  );

  test(
    'unmapped existing owner cannot be bound based on empty visible care',
    () async {
      final now = DateTime.now();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'old-owner',
          email: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final epoch = await access.revokeNetwork();
      await authenticate(
        ownerId: 'old-owner',
        endpoint: 'https://care.test',
        expectedNetworkEpoch: epoch,
        sessionGeneration: 1,
        credentialId: 'old-owner-slot',
      );
      expect(
        (await workspaces.byOwner('old-owner'))?.bindingState,
        'unresolved',
      );
      expect(await access.contextForOwner('old-owner'), isNull);
    },
  );

  test(
    'captured connected grant cannot outlive its network capability',
    () async {
      final context = await login('network-owner', 'https://care.test', 1);
      final state = await workspaces.deviceState();
      await (db.update(
        db.workspaceDeviceStates,
      )..where((row) => row.id.equals('device'))).write(
        WorkspaceDeviceStatesCompanion(
          networkEpoch: Value(state.networkEpoch + 1),
        ),
      );
      await expectLater(
        access.requireCurrent(context),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
    },
  );

  test(
    'wrong-person access is refused and local owners cannot enqueue',
    () async {
      final local = await access.currentContext();
      final connected = await login('remote-owner', 'https://care.test', 1);
      final now = DateTime.now();
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'remote-person',
          userId: connected.ownerUserId,
          name: 'Remote',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await expectLater(
        access.withGrant(local, () async {}, profileId: 'remote-person'),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      var applied = false;
      await expectLater(
        PendingOperationRepository(db).record(
          operation: PendingOperationDraft(
            userId: local.ownerUserId,
            operationType: 'profile.create',
            entityType: 'profile',
            entityLocalId: 'forbidden-intent',
            payload: const {},
          ),
          applyProjection: () async {
            applied = true;
          },
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(applied, isFalse);
      expect(await db.select(db.pendingOperations).get(), isEmpty);
    },
  );

  test('endpoint identity retains base path and path case', () {
    expect(
      canonicalServerEndpoint('https://CARE.test:443/Installation/'),
      'https://care.test/Installation',
    );
    expect(
      canonicalServerEndpoint('https://care.test/a'),
      isNot(canonicalServerEndpoint('https://care.test/b')),
    );
    for (final invalid in [
      'http://care.test',
      'https://person:secret@care.test',
      'https://care.test?q=1',
      'https://care.test/#x',
    ]) {
      expect(() => canonicalServerEndpoint(invalid), throwsArgumentError);
    }
  });

  test(
    'workspace stream emits connected selection and local context after revocation',
    () async {
      final connected = Completer<WorkspaceContext>();
      final localAfter = Completer<WorkspaceContext>();
      var sawConnected = false;
      final subscription = access.watchContext().listen((context) {
        if (context.ownerUserId == 'stream-account' && !connected.isCompleted) {
          sawConnected = true;
          connected.complete(context);
        } else if (sawConnected && context.isLocal && !localAfter.isCompleted) {
          localAfter.complete(context);
        }
      });
      addTearDown(subscription.cancel);
      final account = await login('stream-account', 'https://care.test', 1);
      expect(
        (await connected.future.timeout(
          const Duration(seconds: 3),
        )).accessEpoch,
        account.accessEpoch,
      );
      await access.revokeNetwork();
      expect(
        (await localAfter.future.timeout(const Duration(seconds: 3))).isLocal,
        isTrue,
      );
    },
  );

  test(
    'cross-connection revocation waits for prior write; stale later writes refuse',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'workspace-access-race-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/fictional.db');
      db = AppDatabase(NativeDatabase(file));
      access = WorkspaceAccessRepository(db);
      workspaces = access.workspaces;
      final connected = await login('race-account', 'https://care.test', 1);
      final now = DateTime.now();
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'race-person',
          userId: 'race-account',
          name: 'Fictional',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final second = AppDatabase(NativeDatabase(file));
      addTearDown(second.close);
      await second.customSelect('SELECT 1').get();
      final busy = Completer<void>();
      final background = WorkspaceAccessRepository(
        second,
        onWriteBusy: () {
          if (!busy.isCompleted) busy.complete();
        },
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final mutation = access.withGrant(connected, () async {
        entered.complete();
        await release.future;
        await db.profilesDao.setActive('race-person', false);
      }, profileId: 'race-person');
      await entered.future;
      var completedRevocation = false;
      final revocation = background.revokeNetwork().then((value) {
        completedRevocation = true;
        return value;
      });
      await busy.future.timeout(const Duration(seconds: 3));
      expect(completedRevocation, isFalse);
      release.complete();
      await mutation;
      await revocation;
      expect((await db.profilesDao.getById('race-person'))?.isActive, isFalse);
      await expectLater(
        access.withGrant(connected, () async {
          await db.profilesDao.setActive('race-person', true);
        }),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect((await db.profilesDao.getById('race-person'))?.isActive, isFalse);
      expect(await access.contextForOwner('race-account'), isNull);
      expect((await access.currentContext()).isLocal, isTrue);
    },
  );
}
