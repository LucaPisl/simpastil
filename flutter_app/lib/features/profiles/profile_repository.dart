import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/daos/profiles_dao.dart';
import '../../core/db/database.dart';
import '../../core/errors/app_error.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_access_repository.dart';
import '../../core/workspace/workspace_context.dart';

// ── Abstract interface ────────────────────────────────────────────────────────

abstract class ProfileRepository {
  Future<Result<Profile>> create(String name, String avatarEmoji);
  Future<Result<Profile>> update(
    String localId,
    String name,
    String avatarEmoji,
  );
  Future<Result<void>> toggleActive(String localId, bool isActive);
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId);
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool enabled,
  );
  Future<Result<void>> delete(String localId);
}

// ── Concrete implementation ───────────────────────────────────────────────────

class ProfileRepositoryImpl implements ProfileRepository {
  ProfileRepositoryImpl({
    required ProfilesDao dao,
    required PendingOperationRepository pendingOperations,
    required String userId,
    required Future<void> Function() reconcileProjections,
    WorkspaceAccessRepository? access,
    WorkspaceContext? context,
  }) : _dao = dao,
       _pendingOperations = pendingOperations,
       _userId = userId,
       _reconcileProjections = reconcileProjections,
       _access = access,
       _context = context,
       assert((access == null) == (context == null)),
       assert(context == null || context.ownerUserId == userId);

  final ProfilesDao _dao;
  final PendingOperationRepository _pendingOperations;
  final String _userId;
  final Future<void> Function() _reconcileProjections;
  final WorkspaceAccessRepository? _access;
  final WorkspaceContext? _context;

  static const _uuid = Uuid();

  Future<T> _write<T>(Future<T> Function() action, {String? profileId}) async {
    Future<T> checked() async {
      if (profileId != null) {
        final person = await _dao.getById(profileId);
        if (person != null && person.userId != _userId) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
      }
      return action();
    }

    final context = _context;
    if (context != null) return _access!.withGrant(context, checked);
    return _dao.attachedDatabase.transaction(checked);
  }

  Future<void> _record({
    required PendingOperationDraft operation,
    required Future<void> Function() applyProjection,
  }) async {
    final context = _context;
    if (context != null && context.isLocal) {
      await applyProjection();
      await (_dao.attachedDatabase.update(_dao.attachedDatabase.profiles)
            ..where((row) => row.id.equals(operation.entityLocalId)))
          .write(const ProfilesCompanion(syncStatus: Value('local')));
    } else {
      await _pendingOperations.record(
        operation: operation,
        applyProjection: applyProjection,
      );
    }
  }

  // ── create ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<Profile>> create(
    String name,
    String avatarEmoji,
  ) => _write(() async {
    final localId = _uuid.v4();
    final now = DateTime.now();

    final companion = ProfilesCompanion.insert(
      id: localId,
      userId: _userId,
      name: name,
      avatarEmoji: Value(avatarEmoji),
      createdAt: now,
      updatedAt: now,
    );

    await _record(
      operation: PendingOperationDraft(
        userId: _userId,
        operationType: 'profile.create',
        entityType: 'profile',
        entityLocalId: localId,
        payload: {
          'action': 'create',
          'data': {'name': name, 'avatarEmoji': avatarEmoji, 'isActive': true},
        },
      ),
      applyProjection: () => _dao.upsert(companion),
    );
    final db = _dao.attachedDatabase;
    await db
        .into(db.devicePersonReminders)
        .insert(
          // People added on this phone get its reminders: a person created
          // here is who this phone is for. People pulled from the account
          // keep no row and stay off until chosen.
          DevicePersonRemindersCompanion.insert(
            profileId: localId,
            enabled: const Value(true),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    if (_context case final WorkspaceContext context) {
      await (db.update(db.careWorkspaces)..where(
            (row) =>
                row.id.equals(context.workspaceId) &
                row.selectedProfileId.isNull() &
                row.viewEveryone.equals(false),
          ))
          .write(CareWorkspacesCompanion(selectedProfileId: Value(localId)));
    }
    final local = await _dao.getById(localId);
    if (local == null) {
      return const Err(UnknownError('Failed to read profile after insert'));
    }

    final updated = await _dao.getById(localId);
    return Ok(updated ?? local);
  });

  // ── update ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<Profile>> update(
    String localId,
    String name,
    String avatarEmoji,
  ) => _write(() async {
    final existing = await _dao.getById(localId);
    if (existing == null) return const Err(NotFoundError());

    final companion = ProfilesCompanion(
      id: Value(localId),
      userId: Value(_userId),
      name: Value(name),
      avatarEmoji: Value(avatarEmoji),
      isActive: Value(existing.isActive),
      createdAt: Value(existing.createdAt),
      updatedAt: Value(DateTime.now()),
      serverId: Value(existing.serverId),
      revision: Value(existing.revision),
      syncStatus: Value(_context?.isLocal == true ? 'local' : 'pending'),
      lastSyncAt: Value(existing.lastSyncAt),
      isDeleted: Value(existing.isDeleted),
    );

    await _record(
      operation: PendingOperationDraft(
        userId: _userId,
        operationType: 'profile.update',
        entityType: 'profile',
        entityLocalId: localId,
        payload: {
          'action': 'update',
          'data': {'name': name, 'avatarEmoji': avatarEmoji},
        },
      ),
      applyProjection: () => _dao.update_(companion),
    );

    final result = await _dao.getById(localId);
    return Ok(result!);
  }, profileId: localId);

  // ── toggleActive ───────────────────────────────────────────────────────────

  @override
  Future<Result<void>> toggleActive(String localId, bool isActive) async {
    final result = await _write<Result<void>>(() async {
      final existing = await _dao.getById(localId);
      if (existing == null) return const Err(NotFoundError());

      await _record(
        operation: PendingOperationDraft(
          userId: _userId,
          operationType: 'profile.update',
          entityType: 'profile',
          entityLocalId: localId,
          payload: {
            'action': 'update',
            'data': {'isActive': isActive},
          },
        ),
        applyProjection: () => _dao.setActive(localId, isActive),
      );
      return const Ok(null);
    }, profileId: localId);
    await _reconcileProjections();
    return result;
  }

  @override
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId) =>
      _write<Result<bool>>(() async {
        final person = await _dao.getById(profileId);
        if (person == null || person.isDeleted) {
          return const Err(NotFoundError());
        }
        final db = _dao.attachedDatabase;
        final choice = await (db.select(
          db.devicePersonReminders,
        )..where((row) => row.profileId.equals(profileId))).getSingleOrNull();
        return Ok(choice?.enabled ?? false);
      }, profileId: profileId);

  @override
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool enabled,
  ) async {
    final result = await _write<Result<void>>(() async {
      final existing = await _dao.getById(profileId);
      if (existing == null || existing.isDeleted) {
        return const Err(NotFoundError());
      }
      final db = _dao.attachedDatabase;
      await db
          .into(db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: profileId,
              enabled: Value(enabled),
            ),
          );
      return const Ok(null);
    }, profileId: profileId);
    if (result is Ok<void>) await _reconcileProjections();
    return result;
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  @override
  Future<Result<void>> delete(String localId) async {
    final result = await _write<Result<void>>(() async {
      final existing = await _dao.getById(localId);
      if (existing == null) return const Ok(null); // already gone

      await _record(
        operation: PendingOperationDraft(
          userId: _userId,
          operationType: 'profile.delete',
          entityType: 'profile',
          entityLocalId: localId,
          payload: {'action': 'delete', 'data': <String, Object?>{}},
        ),
        applyProjection: () async {
          await _dao.softDelete(localId);
          final context = _context;
          if (context == null) return;
          final db = _dao.attachedDatabase;
          final workspace =
              await (db.select(db.careWorkspaces)
                    ..where((row) => row.id.equals(context.workspaceId)))
                  .getSingleOrNull();
          if (workspace?.selectedProfileId != localId) return;

          final remainingPeople = await _dao.getByUserId(_userId);
          final replacement = remainingPeople.isEmpty
              ? null
              : remainingPeople.first.id;
          await (db.update(
            db.careWorkspaces,
          )..where((row) => row.id.equals(context.workspaceId))).write(
            CareWorkspacesCompanion(
              selectedProfileId: Value(replacement),
              viewEveryone: Value(replacement == null),
            ),
          );
        },
      );
      return const Ok(null);
    }, profileId: localId);
    await _reconcileProjections();
    return result;
  }
}
