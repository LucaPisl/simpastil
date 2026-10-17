import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import 'workspace_context.dart';

class WorkspaceRepository {
  WorkspaceRepository(this.database);
  final AppDatabase database;
  static const _ids = Uuid();

  Future<CareWorkspace?> byId(String id) => (database.select(
    database.careWorkspaces,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<CareWorkspace?> byOwner(String ownerId) => (database.select(
    database.careWorkspaces,
  )..where((row) => row.ownerUserId.equals(ownerId))).getSingleOrNull();

  Future<CareWorkspace> ensureLocal() => database.transaction(() async {
    final existing = await (database.select(
      database.careWorkspaces,
    )..where((row) => row.singletonKey.equals('standalone'))).getSingleOrNull();
    if (existing != null) return existing;
    final workspaceId = _ids.v4();
    final ownerId = 'local:${_ids.v4()}';
    final authorId = _ids.v4();
    final now = DateTime.now().toUtc();
    await database.usersDao.upsert(
      UsersCompanion.insert(
        id: ownerId,
        email: '',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('local'),
      ),
    );
    await database
        .into(database.careWorkspaces)
        .insert(
          CareWorkspacesCompanion.insert(
            id: workspaceId,
            ownerUserId: ownerId,
            kind: 'local',
            singletonKey: const Value('standalone'),
            bindingState: 'local',
            legacyViewerMigrated: const Value(true),
            currentAuthorId: Value(authorId),
            createdAt: now,
          ),
        );
    await database
        .into(database.workspaceAuthors)
        .insert(
          WorkspaceAuthorsCompanion.insert(
            id: authorId,
            workspaceId: workspaceId,
            provenance: 'workspace',
            createdAt: now,
          ),
        );
    await database
        .into(database.workspaceGrants)
        .insert(
          WorkspaceGrantsCompanion.insert(
            workspaceId: workspaceId,
            isGranted: const Value(true),
          ),
        );
    await database
        .into(database.workspaceDeviceStates)
        .insert(
          WorkspaceDeviceStatesCompanion.insert(id: 'device'),
          mode: InsertMode.insertOrIgnore,
        );
    // Do not change a valid existing viewer or authenticated network session.
    await (database.update(database.workspaceDeviceStates)..where(
          (row) => row.id.equals('device') & row.selectedWorkspaceId.isNull(),
        ))
        .write(
          WorkspaceDeviceStatesCompanion(
            selectedWorkspaceId: Value(workspaceId),
          ),
        );
    return (await byId(workspaceId))!;
  });

  Future<WorkspaceDeviceState> deviceState() async {
    final state = await (database.select(
      database.workspaceDeviceStates,
    )..where((row) => row.id.equals('device'))).getSingleOrNull();
    if (state != null) return state;
    await database
        .into(database.workspaceDeviceStates)
        .insert(
          WorkspaceDeviceStatesCompanion.insert(id: 'device'),
          mode: InsertMode.insertOrIgnore,
        );
    return (await (database.select(
      database.workspaceDeviceStates,
    )..where((row) => row.id.equals('device'))).getSingle());
  }

  Future<String> ensureAuthor(CareWorkspace workspace) async {
    if (workspace.currentAuthorId case final String id) return id;
    final id = _ids.v4();
    await database
        .into(database.workspaceAuthors)
        .insert(
          WorkspaceAuthorsCompanion.insert(
            id: id,
            workspaceId: workspace.id,
            provenance: 'workspace',
            createdAt: DateTime.now().toUtc(),
          ),
        );
    await (database.update(database.careWorkspaces)
          ..where((row) => row.id.equals(workspace.id)))
        .write(CareWorkspacesCompanion(currentAuthorId: Value(id)));
    return id;
  }

  Future<List<Profile>> reminderPeople(String ownerId) async {
    final rows =
        await (database.select(database.profiles).join([
              innerJoin(
                database.devicePersonReminders,
                database.devicePersonReminders.profileId.equalsExp(
                  database.profiles.id,
                ),
              ),
            ])..where(
              database.profiles.userId.equals(ownerId) &
                  database.profiles.isDeleted.equals(false) &
                  database.devicePersonReminders.enabled.equals(true),
            ))
            .get();
    return rows.map((row) => row.readTable(database.profiles)).toList();
  }

  Future<void> requirePerson(String ownerId, String profileId) async {
    final person = await database.profilesDao.getById(profileId);
    if (person == null || person.isDeleted || person.userId != ownerId) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
  }
}
