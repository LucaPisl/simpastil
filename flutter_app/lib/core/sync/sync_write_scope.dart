import 'dart:convert';

import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../utils/safe_diagnostics.dart';

/// Immutable authority shared by a sync client and all of its local writes.
/// Network and secure-storage work must stay outside [write].
class SyncWriteScope {
  SyncWriteScope({required this.access, required this.capability});

  final WorkspaceAccessRepository access;
  final NetworkCapability? capability;
  Future<WorkspaceContext>? _context;

  void requireOwner(String ownerId) {
    if (capability == null || capability!.ownerId != ownerId) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
  }

  Future<WorkspaceContext> _capture() async {
    final captured = capability;
    if (captured == null) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    final context = await access.contextForOwner(captured.ownerId);
    if (context == null ||
        context.isLocal ||
        context.endpoint != captured.endpoint ||
        context.networkEpoch != captured.epoch ||
        context.sessionGeneration != captured.generation) {
      throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.staleGrant);
    }
    return context;
  }

  Future<String> get workspaceId async =>
      (await (_context ??= _capture())).workspaceId;

  Future<WorkspaceContext> captureContext() async {
    final context = await (_context ??= _capture());
    await access.requireCurrent(context);
    return context;
  }

  Future<void> check() async =>
      access.requireCurrent(await (_context ??= _capture()));

  Future<T> write<T>(Future<T> Function() action) async =>
      access.withGrant(await (_context ??= _capture()), action);

  Future<void> requireEntity(
    String type,
    String id, {
    bool allowMissing = false,
  }) async {
    final db = access.database;
    String? owner;
    bool found = false;
    switch (type) {
      case 'profile':
        final row = await db.profilesDao.getById(id);
        found = row != null;
        owner = row?.userId;
      case 'pill':
        final row = await db.pillsDao.getById(id);
        found = row != null;
        owner = row == null
            ? null
            : (await db.profilesDao.getById(row.profileId))?.userId;
      case 'schedule':
        final row = await db.schedulesDao.getById(id);
        found = row != null;
        if (row != null) {
          final pill = await db.pillsDao.getById(row.pillId);
          owner = pill == null
              ? null
              : (await db.profilesDao.getById(pill.profileId))?.userId;
        }
      case 'occurrence':
        final row = await db.medicationLedgerDao.getOccurrenceById(id);
        found = row != null;
        owner = row?.userId;
        if (row?.pillId != null) await requireEntity('pill', row!.pillId!);
        if (row?.scheduleId != null) {
          await requireEntity('schedule', row!.scheduleId!);
        }
      case 'doseLog':
        final row = await db.doseLogsDao.getById(id);
        found = row != null;
        if (row != null) {
          await requireEntity('schedule', row.scheduleId);
          owner = capability?.ownerId;
        }
      default:
        SafeDiagnostics.logAccessRefusal(
          entityType: type,
          reason: 'unsupported_entity_type',
        );
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
    }
    if (!found && allowMissing) return;
    if (!found || owner != capability?.ownerId) {
      SafeDiagnostics.logAccessRefusal(
        entityType: type,
        reason: found ? 'owner_mismatch' : 'missing_entity',
      );
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
  }

  Future<void> requireOperation(PendingOperation operation) async {
    requireOwner(operation.userId);
    await check();
    final retained = await access.database.pendingOperationsDao.getById(
      operation.id,
    );
    if (retained == null ||
        retained.userId != operation.userId ||
        retained.mutationId != operation.mutationId ||
        retained.payloadJson != operation.payloadJson) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final decoded = jsonDecode(operation.payloadJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid operation');
    }
    for (final pair in [
      ('entityType', 'entityLocalId'),
      ('parentEntityType', 'parentEntityLocalId'),
    ]) {
      final type = decoded[pair.$1];
      final id = decoded[pair.$2];
      if (type is String && id is String && type != 'account') {
        await requireEntity(type, id);
      }
    }
    final command = decoded['command'];
    if (command is Map<String, dynamic> && command['occurrenceId'] is String) {
      final row = await access.database.medicationLedgerDao.getOccurrenceById(
        command['occurrenceId'] as String,
      );
      if (row == null || row.userId != capability?.ownerId) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.wrongPerson,
        );
      }
    }
    final inventory = decoded['inventoryCommand'];
    if (inventory is Map<String, dynamic> && inventory['pillId'] is String) {
      await requireEntity('pill', inventory['pillId'] as String);
    }
  }
}
