import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _userId = 'test-user-id';

Future<void> _seedUser(AppDatabase db) async {
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: _userId,
          email: 'user@test.com',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
}

ProfileRepository _makeRepo(AppDatabase db) => ProfileRepositoryImpl(
  dao: db.profilesDao,
  pendingOperations: PendingOperationRepository(db),
  userId: _userId,
  reconcileProjections: () async {},
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seedUser(db);
  });

  tearDown(() async => db.close());

  group('protected device reminder choice', () {
    late ProtectedWorkspaceFixture workspace;
    late ProfileRepository repo;
    late int reconciliations;

    setUp(() async {
      workspace = await ProtectedWorkspaceFixture.create(database: db);
      reconciliations = 0;
      repo = ProfileRepositoryImpl(
        dao: db.profilesDao,
        pendingOperations: PendingOperationRepository(db),
        userId: workspace.context.ownerUserId,
        access: workspace.access,
        context: workspace.context,
        reconcileProjections: () async {
          reconciliations++;
        },
      );
    });

    test(
      'guarded read returns the explicit choice and absent-row default',
      () async {
        final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
        expect(
          (await repo.getDeviceRemindersEnabled(person.id) as Ok<bool>).value,
          isFalse,
        );
        await repo.setDeviceRemindersEnabled(person.id, true);
        expect(
          (await repo.getDeviceRemindersEnabled(person.id) as Ok<bool>).value,
          isTrue,
        );
        await repo.setDeviceRemindersEnabled(person.id, false);
        expect(
          (await repo.getDeviceRemindersEnabled(person.id) as Ok<bool>).value,
          isFalse,
        );
        await (db.delete(
          db.devicePersonReminders,
        )..where((row) => row.profileId.equals(person.id))).go();
        expect(
          (await repo.getDeviceRemindersEnabled(person.id) as Ok<bool>).value,
          isFalse,
        );
        expect(await db.select(db.devicePersonReminders).get(), isEmpty);
        expect(reconciliations, 2);
      },
    );

    test(
      'guarded read refuses unavailable people and stale authorization',
      () async {
        expect(
          await repo.getDeviceRemindersEnabled('missing'),
          isA<Err<bool>>(),
        );
        final foreign =
            (await _makeRepo(db).create('Other', '👤') as Ok<Profile>).value;
        await expectLater(
          repo.getDeviceRemindersEnabled(foreign.id),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        final deleted =
            (await repo.create('Deleted', '👤') as Ok<Profile>).value;
        await db.profilesDao.softDelete(deleted.id);
        expect(
          await repo.getDeviceRemindersEnabled(deleted.id),
          isA<Err<bool>>(),
        );
        final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
        await repo.setDeviceRemindersEnabled(person.id, true);
        await (db.update(db.workspaceGrants)..where(
              (row) => row.workspaceId.equals(workspace.context.workspaceId),
            ))
            .write(
              WorkspaceGrantsCompanion(
                epoch: Value(workspace.context.accessEpoch + 1),
              ),
            );
        await expectLater(
          repo.getDeviceRemindersEnabled(person.id),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
      },
    );

    test(
      'create stays off; opt-in and opt-out preserve person and authorship',
      () async {
        final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
        final authors = await db.select(db.workspaceAuthors).get();
        expect(
          (await db.select(db.devicePersonReminders).get()).single.enabled,
          isFalse,
        );

        expect(
          await repo.setDeviceRemindersEnabled(person.id, true),
          isA<Ok<void>>(),
        );
        expect(
          (await db.select(db.devicePersonReminders).get()).single.enabled,
          isTrue,
        );
        expect(await db.profilesDao.getById(person.id), person);
        expect(
          await repo.setDeviceRemindersEnabled(person.id, false),
          isA<Ok<void>>(),
        );
        expect(
          (await db.select(db.devicePersonReminders).get()).single.enabled,
          isFalse,
        );
        expect(await db.profilesDao.getById(person.id), person);
        expect(await db.select(db.workspaceAuthors).get(), authors);
        expect(await db.select(db.pendingOperations).get(), isEmpty);
        expect(reconciliations, 2);
      },
    );

    test('active-state changes preserve explicit reminder choice', () async {
      final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
      expect(
        await repo.setDeviceRemindersEnabled(person.id, true),
        isA<Ok<void>>(),
      );
      expect(await repo.toggleActive(person.id, false), isA<Ok<void>>());
      expect((await db.profilesDao.getById(person.id))!.isActive, isFalse);
      expect(
        (await db.select(db.devicePersonReminders).get()).single.enabled,
        isTrue,
      );
      expect(
        await repo.setDeviceRemindersEnabled(person.id, false),
        isA<Ok<void>>(),
      );
      expect(await repo.toggleActive(person.id, true), isA<Ok<void>>());
      expect((await db.profilesDao.getById(person.id))!.isActive, isTrue);
      expect(
        (await db.select(db.devicePersonReminders).get()).single.enabled,
        isFalse,
      );
    });

    test(
      'opting an inactive person in leaves active state unchanged',
      () async {
        final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
        await (db.update(db.profiles)..where((row) => row.id.equals(person.id)))
            .write(const ProfilesCompanion(isActive: Value(false)));
        expect(
          await repo.setDeviceRemindersEnabled(person.id, true),
          isA<Ok<void>>(),
        );
        expect((await db.profilesDao.getById(person.id))!.isActive, isFalse);
        expect(
          (await db.select(db.devicePersonReminders).get()).single.enabled,
          isTrue,
        );
      },
    );

    test('missing and deleted people cannot gain a preference', () async {
      expect(
        await repo.setDeviceRemindersEnabled('missing', true),
        isA<Err<void>>(),
      );
      final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
      await db.profilesDao.softDelete(person.id);
      await (db.delete(
        db.devicePersonReminders,
      )..where((row) => row.profileId.equals(person.id))).go();
      expect(
        await repo.setDeviceRemindersEnabled(person.id, true),
        isA<Err<void>>(),
      );
      expect(await db.select(db.devicePersonReminders).get(), isEmpty);
      expect(reconciliations, 0);
    });

    test(
      'deleting the selected person selects a remaining valid person',
      () async {
        final sam = (await repo.create('Sam', '👤') as Ok<Profile>).value;
        final fixture =
            (await repo.create('Fictional fixture', '👤') as Ok<Profile>).value;
        await workspace.access.viewPerson(workspace.context, fixture.id);

        expect(await repo.delete(fixture.id), isA<Ok<void>>());

        final after = await workspace.access.workspaces.byId(
          workspace.context.workspaceId,
        );
        expect(after?.selectedProfileId, sam.id);
        expect(after?.viewEveryone, isFalse);
        await workspace.access.requireCurrent(
          workspace.context,
          profileId: sam.id,
        );
      },
    );

    test(
      'foreign person and stale grant are refused without updating preferences',
      () async {
        final foreign =
            (await _makeRepo(db).create('Other', '👤') as Ok<Profile>).value;
        await expectLater(
          repo.setDeviceRemindersEnabled(foreign.id, true),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        final person = (await repo.create('Sam', '👤') as Ok<Profile>).value;
        await (db.update(db.workspaceGrants)..where(
              (row) => row.workspaceId.equals(workspace.context.workspaceId),
            ))
            .write(
              WorkspaceGrantsCompanion(
                epoch: Value(workspace.context.accessEpoch + 1),
              ),
            );
        await expectLater(
          repo.setDeviceRemindersEnabled(person.id, true),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(
          (await db.select(db.devicePersonReminders).get()).every(
            (row) => !row.enabled,
          ),
          isTrue,
        );
        expect(reconciliations, 0);
      },
    );
  });

  test('persists create intent with its optimistic profile', () async {
    final result = await _makeRepo(db).create('Alice', '👤');

    expect(result, isA<Ok<Profile>>());
    final profiles = await db.profilesDao.getByUserId(_userId);
    final operations = await db.pendingOperationsDao.getForUser(_userId);
    expect(profiles, hasLength(1));
    expect(profiles.single.name, 'Alice');
    expect(profiles.single.syncStatus, 'pending');
    expect(operations, hasLength(1));
    expect(operations.single.operationType, 'profile.create');
  });

  test('chains profile edits by durable operation ID', () async {
    final repo = _makeRepo(db);
    final created = await repo.create('Alice', '👤');
    final profile = (created as Ok<Profile>).value;

    final updated = await repo.update(profile.id, 'Alicia', '🙂');

    expect(updated, isA<Ok<Profile>>());
    final operations = await db.pendingOperationsDao.getForUser(_userId);
    expect(operations, hasLength(2));
    final create = operations.singleWhere(
      (operation) => operation.operationType == 'profile.create',
    );
    final update = operations.singleWhere(
      (operation) => operation.operationType == 'profile.update',
    );
    expect(update.dependsOnOperationId, create.id);
    expect((await db.profilesDao.getById(profile.id))?.name, 'Alicia');
  });

  test('toggle and delete are also durable optimistic mutations', () async {
    final repo = _makeRepo(db);
    final created = await repo.create('Alice', '👤');
    final profile = (created as Ok<Profile>).value;

    expect(await repo.toggleActive(profile.id, false), isA<Ok<void>>());
    expect(await repo.delete(profile.id), isA<Ok<void>>());

    final visible = await db.profilesDao.getByUserId(_userId);
    final operations = await db.pendingOperationsDao.getForUser(_userId);
    expect(visible, isEmpty);
    final create = operations.singleWhere(
      (operation) => operation.operationType == 'profile.create',
    );
    final update = operations.singleWhere(
      (operation) => operation.operationType == 'profile.update',
    );
    final delete = operations.singleWhere(
      (operation) => operation.operationType == 'profile.delete',
    );
    expect(create.createdAt.isBefore(update.createdAt), isTrue);
    expect(update.createdAt.isBefore(delete.createdAt), isTrue);
    expect(update.dependsOnOperationId, create.id);
    expect(
      delete.dependsOnOperationId,
      update.id,
      reason: operations
          .map(
            (operation) =>
                '${operation.operationType} ${operation.id} '
                'depends=${operation.dependsOnOperationId} '
                'at=${operation.createdAt.toIso8601String()} '
                'payload=${operation.payloadJson}',
          )
          .join('\n'),
    );
  });
}
