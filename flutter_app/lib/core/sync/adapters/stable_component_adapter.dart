import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;

import '../../db/database.dart';
import '../sync_models.dart';
import '../sync_retry_policy.dart';
import '../pending_operation_repository.dart';
import 'stable_record_adapter.dart';

abstract class StableComponentAdapter {
  const StableComponentAdapter(this.db);

  final AppDatabase db;

  String get entityType;
  String get operationComponent => 'stable';

  Future<SyncComponentOutcome> flush(
    String userId,
    StableRecordAdapter mutationAdapter, {
    String? onlyOperationId,
    bool? ledgerActive,
  }) async {
    mutationAdapter.writeScope?.requireOwner(userId);
    await mutationAdapter.writeScope?.check();
    final workspaceId = await mutationAdapter.writeScope?.workspaceId;
    final split = await db.pendingOperationsDao.getReadySplit(
      userId,
      workspaceId: workspaceId,
      ledgerActive: ledgerActive,
      // A caller naming one operation is the person asking for it now.
      honorBackoff: onlyOperationId == null,
    );
    bool mine(PendingOperation operation) =>
        (onlyOperationId == null || operation.id == onlyOperationId) &&
        operation.component == operationComponent &&
        _entityType(operation) == entityType;
    final candidates = split.ready.where(mine).toList();
    final backingOff = split.waiting.where(mine).toList();
    var hadDeferredOperation = false;
    String? safeErrorCode;
    String? safeCorrelationId;
    if (backingOff.isNotEmpty) {
      // Retrying later is not synced: say so instead of reporting success.
      hadDeferredOperation = true;
      safeErrorCode = 'SYNC_RETRY_SCHEDULED';
    }

    for (var operation in candidates) {
      final claim = await _claimAndFreeze(mutationAdapter, operation);
      if (claim.blockedCode != null) {
        hadDeferredOperation = true;
        safeErrorCode = claim.blockedCode;
        continue;
      }
      if (claim.operation == null) {
        hadDeferredOperation = true;
        safeErrorCode = 'STABLE_OPERATION_CLAIM_LOST';
        continue;
      }
      // The claim rewrote the payload (frozen request); every later write and
      // the send must see the retained row.
      operation = claim.operation!;

      late StableMutationResult result;
      try {
        result = await mutationAdapter.send(operation);
      } on DioException catch (error) {
        if (error.response?.statusCode == 401) {
          await mutationAdapter.writeOperation(
            operation,
            () => db.pendingOperationsDao.transitionState(
              operationId: operation.id,
              from: 'sending',
              to: 'failedRetryable',
              safeErrorCode: 'AUTH_REQUIRED',
            ),
          );
          rethrow;
        }
        result = mutationAdapter.classifyFailure(error);
      }

      safeErrorCode = result.safeErrorCode;
      safeCorrelationId = result.safeCorrelationId;
      switch (result.status) {
        case StableMutationStatus.acknowledged:
          final committed = await mutationAdapter.writeOperation(
            operation,
            () async {
              if (result.acknowledgedMutationId != operation.mutationId) {
                return false;
              }
              final committed = await PendingOperationRepository(db)
                  .commitWithMatchingReceipt(
                    operationId: operation.id,
                    acknowledgedMutationId: result.acknowledgedMutationId!,
                  );
              if (committed) await result.applyReceipt?.call();
              return committed;
            },
          );
          if (!committed) {
            hadDeferredOperation = true;
            safeErrorCode = 'STABLE_RECEIPT_MISMATCH';
            await mutationAdapter.writeOperation(
              operation,
              () => db.pendingOperationsDao.transitionState(
                operationId: operation.id,
                from: 'sending',
                to: 'blocked',
                safeErrorCode: safeErrorCode,
              ),
            );
          }
        case StableMutationStatus.legacyAcceptedAwaitingReconciliation:
          hadDeferredOperation = true;
          await mutationAdapter.writeOperation(operation, () async {
            await result.applyReceipt?.call();
            return db.pendingOperationsDao.transitionState(
              operationId: operation.id,
              from: 'sending',
              to: 'blocked',
              safeErrorCode: 'LEGACY_STABLE_AWAITING_RECONCILIATION',
            );
          });
        case StableMutationStatus.conflict:
          hadDeferredOperation = true;
          await mutationAdapter.writeOperation(operation, () async {
            await result.applyReceipt?.call();
            return db.pendingOperationsDao.transitionState(
              operationId: operation.id,
              from: 'sending',
              to: 'conflict',
              safeErrorCode: result.safeErrorCode ?? 'STABLE_CONFLICT',
              safeCorrelationId: result.safeCorrelationId,
            );
          });
        case StableMutationStatus.retryable:
          hadDeferredOperation = true;
          await mutationAdapter.writeOperation(
            operation,
            () => db.pendingOperationsDao.settleTransientFailure(
              operation: operation,
              safeErrorCode: result.safeErrorCode ?? 'STABLE_RETRYABLE',
              safeCorrelationId: result.safeCorrelationId,
              retryAfter: result.retryAfter,
            ),
          );
        case StableMutationStatus.uncertain:
        case StableMutationStatus.blocked:
          hadDeferredOperation = true;
          await mutationAdapter.writeOperation(
            operation,
            () => db.pendingOperationsDao.transitionState(
              operationId: operation.id,
              from: 'sending',
              to: 'blocked',
              safeErrorCode: result.safeErrorCode ?? 'STABLE_REVIEW_REQUIRED',
              safeCorrelationId: result.safeCorrelationId,
            ),
          );
      }
    }

    return hadDeferredOperation
        ? SyncComponentOutcome.partiallySynced(
            safeErrorCode: safeErrorCode,
            safeCorrelationId: safeCorrelationId,
          )
        : const SyncComponentOutcome.succeeded();
  }

  /// Claims the operation and freezes its request in one transaction. A
  /// replay rebuilds the request and refuses to send anything that differs
  /// from the frozen one under the same mutation id.
  Future<({PendingOperation? operation, String? blockedCode})> _claimAndFreeze(
    StableRecordAdapter adapter,
    PendingOperation operation,
  ) => adapter.writeOperation(operation, () async {
    final payload = jsonDecode(operation.payloadJson);
    final fresh = await adapter.buildFrozenRequest(operation);
    Map<String, dynamic>? updatedPayload;
    if (payload is Map<String, dynamic> && fresh != null) {
      final frozen = payload['frozenRequest'];
      if (frozen is Map) {
        if (jsonEncode(frozen) != jsonEncode(fresh)) {
          await db.pendingOperationsDao.transitionState(
            operationId: operation.id,
            from: operation.state,
            to: 'blocked',
            safeErrorCode: SyncRetryPolicy.bodyChangedCode,
          );
          return (
            operation: null,
            blockedCode: SyncRetryPolicy.bodyChangedCode,
          );
        }
      } else {
        updatedPayload = {...payload, 'frozenRequest': fresh};
      }
    }
    final claimed = await db.pendingOperationsDao.transitionState(
      operationId: operation.id,
      from: operation.state,
      to: 'sending',
      attemptedAt: DateTime.now().toUtc(),
    );
    if (!claimed) return (operation: null, blockedCode: null);
    if (updatedPayload != null) {
      await (db.update(
        db.pendingOperations,
      )..where((row) => row.id.equals(operation.id))).write(
        PendingOperationsCompanion(
          payloadJson: Value(jsonEncode(updatedPayload)),
        ),
      );
    }
    return (
      operation: await db.pendingOperationsDao.getById(operation.id),
      blockedCode: null,
    );
  });

  String? _entityType(PendingOperation operation) {
    try {
      final payload = jsonDecode(operation.payloadJson);
      final value = payload is Map<String, dynamic>
          ? payload['entityType']
          : null;
      return value is String ? value : null;
    } on FormatException {
      return null;
    }
  }
}
