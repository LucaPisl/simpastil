import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_provider.dart';

/// A stable local write and its optimistic projection are recorded together.
/// The identifiers in [payload] are local IDs; adapters resolve server IDs only
/// when their parent operation has committed.
class PendingOperationDraft {
  const PendingOperationDraft({
    required this.userId,
    required this.operationType,
    required this.entityType,
    required this.entityLocalId,
    required this.payload,
    this.parentEntityType,
    this.parentEntityLocalId,
    this.dependsOnOperationId,
    this.mutationId,
    this.component = 'stable',
    this.contractVersion = 2,
    this.effects = const [],
  });

  final String userId;
  final String operationType;
  final String entityType;
  final String entityLocalId;
  final Map<String, Object?> payload;
  final String? parentEntityType;
  final String? parentEntityLocalId;
  final String? dependsOnOperationId;
  final String? mutationId;
  final String component;
  final int contractVersion;
  final List<PendingOperationEffectDraft> effects;
}

class PendingOperationEffectDraft {
  const PendingOperationEffectDraft({
    required this.kind,
    required this.requestFingerprint,
    this.legacySourceId,
  });

  final String kind;
  final String requestFingerprint;
  final String? legacySourceId;
}

class RecordedPendingOperation {
  const RecordedPendingOperation({
    required this.operationId,
    required this.mutationId,
  });

  final String operationId;
  final String mutationId;
}

/// Owns durable intent, dependency ordering, and state transitions.
class PendingOperationRepository {
  PendingOperationRepository(
    this._db, {
    WorkspaceAccessRepository? access,
    WorkspaceContext? context,
  }) : _access = access,
       _context = context {
    if ((access == null) != (context == null)) {
      throw ArgumentError('Access and context must be captured together');
    }
  }

  final AppDatabase _db;
  final WorkspaceAccessRepository? _access;
  final WorkspaceContext? _context;
  WorkspaceAccessRepository? get access => _access;
  WorkspaceContext? get context => _context;

  /// Care reads share the same captured authority as the queued mutation.
  /// Network and platform effects must remain outside this transaction.
  Future<T> withCareGrant<T>(Future<T> Function() action) => _write(action);

  void requireCareOwner(String ownerId) => _requireOwner(ownerId);
  Future<T> _write<T>(Future<T> Function() action) => _context == null
      ? _db.transaction(action)
      : _access!.withGrant(_context, action);
  void _requireOwner(String ownerId) {
    if (_context != null && ownerId != _context.ownerUserId) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
  }

  Future<T> _writeOperation<T>(String id, Future<T> Function() action) =>
      _write(() async {
        final row = await _db.pendingOperationsDao.getById(id);
        if (row != null) _requireOwner(row.userId);
        return action();
      });
  static const _ids = Uuid();

  /// Inserts the complete operation batch before applying [applyProjection],
  /// inside one SQLite transaction. A crash therefore preserves either both
  /// intent and projection, or neither.
  Future<List<RecordedPendingOperation>> recordAtomically({
    required List<PendingOperationDraft> operations,
    required Future<void> Function() applyProjection,
  }) async {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'must not be empty');
    }
    final userId = operations.first.userId;
    _requireOwner(userId);
    if (operations.any((operation) => operation.userId != userId)) {
      throw ArgumentError('An atomic operation batch must have one owner');
    }

    final mutationIds = [
      for (final operation in operations) operation.mutationId ?? _ids.v4(),
    ];
    if (mutationIds.toSet().length != mutationIds.length) {
      throw ArgumentError('An atomic batch must have distinct mutation IDs');
    }
    final recorded = <RecordedPendingOperation>[];

    await _write(() async {
      final workspace = await (_db.select(
        _db.careWorkspaces,
      )..where((row) => row.ownerUserId.equals(userId))).getSingleOrNull();
      if (workspace?.kind == 'local' || userId.startsWith('local:')) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.unavailable,
        );
      }
      final existing = <PendingOperation?>[];
      for (final mutationId in mutationIds) {
        existing.add(
          await _db.pendingOperationsDao.getByMutationId(userId, mutationId),
        );
      }
      final existingCount = existing.whereType<PendingOperation>().length;
      // A batch may be only partly recorded when a deterministic draft (for
      // example an inventory command) is re-submitted together with a fresh
      // draft. Already-recorded drafts must still describe the same intent;
      // only the missing drafts are inserted.
      for (var index = 0; index < operations.length; index++) {
        final prior = existing[index];
        if (prior == null) continue;
        final draft = operations[index];
        final payload = _operationPayload(draft);
        if (prior.operationType != draft.operationType ||
            prior.component != draft.component ||
            prior.contractVersion != draft.contractVersion ||
            prior.payloadJson != _canonicalJson(payload)) {
          throw StateError('A mutation ID was reused for different intent');
        }
        final priorEffects = await _db.pendingOperationsDao.getEffects(
          prior.id,
        );
        if (priorEffects.length != draft.effects.length ||
            List.generate(draft.effects.length, (effectIndex) {
              final expected = draft.effects[effectIndex];
              final actual = priorEffects[effectIndex];
              return actual.ordinal == effectIndex &&
                  actual.kind == expected.kind &&
                  actual.legacySourceId == expected.legacySourceId &&
                  actual.requestFingerprint == expected.requestFingerprint;
            }).any((matches) => !matches)) {
          throw StateError('A mutation ID was reused with different effects');
        }
      }
      if (existingCount == operations.length) {
        for (final prior in existing) {
          recorded.add(
            RecordedPendingOperation(
              operationId: prior!.id,
              mutationId: prior.mutationId,
            ),
          );
        }
        return;
      }

      final operationIdsByEntity = <String, String>{};
      var lastCreatedAt = await _db.pendingOperationsDao.getLatestCreatedAt(
        userId,
      );
      for (var index = 0; index < operations.length; index++) {
        final prior = existing[index];
        if (prior != null) {
          operationIdsByEntity[_entityKey(
                operations[index].entityType,
                operations[index].entityLocalId,
              )] =
              prior.id;
          recorded.add(
            RecordedPendingOperation(
              operationId: prior.id,
              mutationId: prior.mutationId,
            ),
          );
          continue;
        }
        final draft = operations[index];
        final entityKey = _entityKey(draft.entityType, draft.entityLocalId);

        // Chain repeated edits to the same entity, then link a newly-created
        // child to its parent's latest uncommitted operation. Dependencies are
        // operation IDs, never local or server entity IDs.
        var dependencyId = draft.dependsOnOperationId;
        dependencyId ??= operationIdsByEntity[entityKey];
        dependencyId ??= await _findLatestOpenOperation(
          userId,
          draft.entityType,
          draft.entityLocalId,
        );
        final parentType = draft.parentEntityType;
        final parentId = draft.parentEntityLocalId;
        if (dependencyId == null && parentType != null && parentId != null) {
          dependencyId = operationIdsByEntity[_entityKey(parentType, parentId)];
          dependencyId ??= await _findLatestOpenOperation(
            userId,
            parentType,
            parentId,
          );
        }

        final item = RecordedPendingOperation(
          operationId: _ids.v4(),
          mutationId: mutationIds[index],
        );
        recorded.add(item);
        final clockNow = DateTime.now().toUtc();
        const millisecondsPerSecond = Duration.millisecondsPerSecond;
        var createdAt = DateTime.fromMillisecondsSinceEpoch(
          clockNow.millisecondsSinceEpoch ~/
              millisecondsPerSecond *
              millisecondsPerSecond,
          isUtc: true,
        );
        if (lastCreatedAt != null && !createdAt.isAfter(lastCreatedAt)) {
          // Drift stores SQLite DateTime values as whole Unix seconds. Keep
          // same-entity edits strictly ordered at that persisted precision,
          // even when several mutations are recorded in one clock tick.
          createdAt = lastCreatedAt.add(const Duration(seconds: 1));
        }
        lastCreatedAt = createdAt;
        final payload = _operationPayload(draft);
        await _db.pendingOperationsDao.enqueue(
          PendingOperationsCompanion.insert(
            id: item.operationId,
            userId: userId,
            mutationId: item.mutationId,
            component: draft.component,
            operationType: draft.operationType,
            contractVersion: draft.contractVersion,
            payloadJson: _canonicalJson(payload),
            dependsOnOperationId: dependencyId == null
                ? const Value.absent()
                : Value(dependencyId),
            createdAt: createdAt,
          ),
          effects: [
            for (var ordinal = 0; ordinal < draft.effects.length; ordinal++)
              PendingOperationEffectsCompanion.insert(
                id: _ids.v4(),
                operationId: item.operationId,
                ordinal: ordinal,
                kind: draft.effects[ordinal].kind,
                legacySourceId: Value(draft.effects[ordinal].legacySourceId),
                requestFingerprint: draft.effects[ordinal].requestFingerprint,
              ),
          ],
        );
        operationIdsByEntity[entityKey] = item.operationId;
      }
      await applyProjection();
    });
    return recorded;
  }

  Future<RecordedPendingOperation> record({
    required PendingOperationDraft operation,
    required Future<void> Function() applyProjection,
  }) async => (await recordAtomically(
    operations: [operation],
    applyProjection: applyProjection,
  )).single;

  Future<List<PendingOperation>> ready(String userId) => _write(() async {
    _requireOwner(userId);
    return _db.pendingOperationsDao.getReady(
      userId,
      workspaceId: _context?.workspaceId,
    );
  });

  Future<PendingOperation?> claimNext(String userId) => _write(() async {
    _requireOwner(userId);
    for (final operation in await ready(userId)) {
      final claimed = await _db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: operation.state,
        to: 'sending',
        attemptedAt: DateTime.now().toUtc(),
      );
      if (claimed) return _db.pendingOperationsDao.getById(operation.id);
    }
    return null;
  });

  /// A versioned success is committed only when the returned identity matches
  /// the mutation that was sent. Legacy success without a receipt is retained
  /// for reconciliation instead of being treated as exactly-once.
  Future<bool> commitWithMatchingReceipt({
    required String operationId,
    required String acknowledgedMutationId,
  }) => _writeOperation(operationId, () async {
    final operation = await _db.pendingOperationsDao.getById(operationId);
    if (operation == null ||
        operation.state != 'sending' ||
        operation.mutationId != acknowledgedMutationId) {
      return false;
    }
    return _db.pendingOperationsDao.transitionState(
      operationId: operationId,
      from: 'sending',
      to: 'committed',
    );
  });

  Future<bool> markUncertain(
    String operationId, {
    String? safeErrorCode,
    String? safeCorrelationId,
  }) => _writeOperation(
    operationId,
    () => _db.pendingOperationsDao.transitionState(
      operationId: operationId,
      from: 'sending',
      to: 'blocked',
      safeErrorCode: safeErrorCode,
      safeCorrelationId: safeCorrelationId,
    ),
  );

  Future<bool> markRetryable(
    String operationId, {
    String? safeErrorCode,
    String? safeCorrelationId,
  }) => _writeOperation(
    operationId,
    () => _db.pendingOperationsDao.transitionState(
      operationId: operationId,
      from: 'sending',
      to: 'failedRetryable',
      safeErrorCode: safeErrorCode,
      safeCorrelationId: safeCorrelationId,
    ),
  );

  Future<bool> markConflict(
    String operationId, {
    String? safeErrorCode,
    String? safeCorrelationId,
  }) => _writeOperation(
    operationId,
    () => _db.pendingOperationsDao.transitionState(
      operationId: operationId,
      from: 'sending',
      to: 'conflict',
      safeErrorCode: safeErrorCode,
      safeCorrelationId: safeCorrelationId,
    ),
  );

  Future<String?> _findLatestOpenOperation(
    String userId,
    String entityType,
    String entityLocalId,
  ) async {
    final operations = await _db.pendingOperationsDao.getUnsettledForUser(
      userId,
    );
    for (final operation in operations.reversed) {
      if (operation.state == 'committed' || operation.state == 'discarded') {
        continue;
      }
      try {
        final payload = jsonDecode(operation.payloadJson);
        if (payload is Map<String, dynamic> &&
            payload['entityType'] == entityType &&
            payload['entityLocalId'] == entityLocalId) {
          return operation.id;
        }
      } on FormatException {
        // Corrupt queued intent must not become a dependency by guesswork.
      }
    }
    return null;
  }

  String _entityKey(String entityType, String localId) =>
      '$entityType:$localId';

  Map<String, Object?> _operationPayload(PendingOperationDraft draft) => {
    ...draft.payload,
    'entityType': draft.entityType,
    'entityLocalId': draft.entityLocalId,
    if (draft.parentEntityType != null)
      'parentEntityType': draft.parentEntityType,
    if (draft.parentEntityLocalId != null)
      'parentEntityLocalId': draft.parentEntityLocalId,
  };

  static String _canonicalJson(Object? value) =>
      jsonEncode(_canonicalize(value));

  static Object? _canonicalize(Object? value) {
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is Iterable) return value.map(_canonicalize).toList();
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw ArgumentError.value(value, 'payload', 'must be JSON-compatible');
  }
}

final pendingOperationRepositoryProvider = Provider<PendingOperationRepository>(
  (ref) {
    return PendingOperationRepository(
      ref.watch(databaseProvider),
      access: ref.watch(workspaceAccessRepositoryProvider),
      context: ref.watch(workspaceContextProvider).requireValue,
    );
  },
);
