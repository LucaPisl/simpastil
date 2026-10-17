import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/database.dart';
import '../sync_write_scope.dart';
import '../capabilities_client.dart';
import '../legacy_split_checkpoint.dart';

enum MedicationMutationStatus {
  acknowledged,
  waitingForMapping,
  waitingForAuthority,
  conflict,
  retryable,
  uncertain,
  blocked,

  /// The operation was an automatic miss that is no longer wanted. It is
  /// settled for good, so it is neither a retry nor a partial sync.
  discarded,
}

class MedicationMutationResult {
  const MedicationMutationResult(
    this.status, {
    this.commandId,
    this.serverId,
    this.safeErrorCode,
    this.safeCorrelationId,
  });

  final MedicationMutationStatus status;
  final String? commandId;
  final String? serverId;
  final String? safeErrorCode;
  final String? safeCorrelationId;
}

Future<bool> claimMedicationOperation(
  AppDatabase db,
  PendingOperation operation,
) async {
  if (operation.state != 'queued' && operation.state != 'failedRetryable') {
    return false;
  }
  return db.pendingOperationsDao.transitionState(
    operationId: operation.id,
    from: operation.state,
    to: 'sending',
    attemptedAt: DateTime.now().toUtc(),
  );
}

/// Durably sends exact local split checkpoints to the permanent server
/// reconciliation ledger. It never guesses adoption evidence; ambiguous
/// checkpoints remain blocked for an explicit disposition.
class PermanentMedicationReconciliationAdapter {
  const PermanentMedicationReconciliationAdapter({
    required this.db,
    required this.dio,
    this.writeScope,
  });

  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope? writeScope;
  Future<T> _write<T>(
    PendingOperation operation,
    Future<T> Function() action,
  ) =>
      writeScope?.write(() async {
        await writeScope!.requireOperation(operation);
        return action();
      }) ??
      db.transaction(action);

  Future<MedicationMutationResult> reconcile(PendingOperation operation) async {
    await writeScope?.requireOperation(operation);
    final checkpoint = await LegacySplitCheckpoint.load(db, operation.id);
    if (checkpoint == null) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'MISSING_SPLIT_CHECKPOINT',
      );
    }
    if (!checkpoint.hasRetainedProgress) {
      return const MedicationMutationResult(
        MedicationMutationStatus.acknowledged,
      );
    }
    final payload = _decode(operation.payloadJson);
    if (payload == null) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'INVALID_SPLIT_OPERATION',
      );
    }
    final inventoryCommand = payload['inventoryCommand'];
    final commandId = LegacySplitIdentity.sourceCommandId(
      payload,
      operation.mutationId,
    );
    if (commandId is! String) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'SPLIT_COMMAND_ID_MISSING',
      );
    }
    for (final effect in checkpoint.effects) {
      if (effect.state == 'queued' ||
          (effect.safeResultFingerprint?.startsWith(
                LegacySplitIdentity.recordedMarkerPrefix,
              ) ??
              false)) {
        continue;
      }
      final ids = LegacySplitIdentity(commandId, effect.ordinal);
      final sourceId = effect.state == 'acknowledged'
          ? (effect.kind == 'inventory'
                ? effect.safeServerId
                : effect.safeServerId)
          : null;
      final sourceKind = effect.kind == 'dose' ? 'dose_log' : 'pill_stock';
      final localProjection = payload['localProjection'];
      final baseStock = localProjection is Map<String, dynamic>
          ? localProjection['observedStock']
          : inventoryCommand is Map<String, dynamic>
          ? inventoryCommand['observedBaseStock']
          : null;
      final targetStock = localProjection is Map<String, dynamic>
          ? localProjection['resultingStock']
          : inventoryCommand is Map<String, dynamic>
          ? inventoryCommand['initialStock'] ?? inventoryCommand['targetStock']
          : null;
      final baseRevision = localProjection is Map<String, dynamic>
          ? localProjection['observedBasePillRevision']
          : null;
      final request = <String, Object?>{
        'operation': 'record',
        'issueId': ids.issueId,
        'commandId': ids.resolutionCommandId,
        'commandBundleId': ids.bundleId,
        'transactionCorrelationId': ids.correlationId,
        'checkpoint': {
          'version': 1,
          'reason': 'evidence_ambiguous',
          'legacySourceKind': _isUuid(sourceId) ? sourceKind : null,
          'legacySourceId': _isUuid(sourceId) ? sourceId : null,
          'sourceFingerprint': null,
          'observedBaseRevision':
              baseRevision is String &&
                  RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(baseRevision)
              ? baseRevision
              : null,
          'observedBaseStock': baseStock is int ? baseStock : null,
          'targetStock': targetStock is int ? targetStock : null,
        },
      };
      try {
        final response = await dio.post<dynamic>(
          '/medication/legacy-split/reconcile',
          data: request,
        );
        if (_issueId(response.data) != ids.issueId) {
          await _recordLocalIssue(operation, effect, ids.issueId);
          await _write(
            operation,
            () => db.pendingOperationsDao.markEffectLocalReviewRequired(
              effectId: effect.id,
              issueId: ids.issueId,
            ),
          );
          await _write(
            operation,
            () => db.pendingOperationsDao.blockForReview(
              operationId: operation.id,
              safeErrorCode: 'SPLIT_RECONCILIATION_RECEIPT_MISMATCH',
            ),
          );
          return const MedicationMutationResult(
            MedicationMutationStatus.uncertain,
            safeErrorCode: 'SPLIT_RECONCILIATION_RECEIPT_MISMATCH',
          );
        }
      } on DioException catch (error) {
        if (error.response?.statusCode == 401) rethrow;
        final errorCode = _errorCode(error);
        final correlationId = _correlationId(error);
        if (error.response == null ||
            (error.response?.statusCode ?? 0) >= 500) {
          return MedicationMutationResult(
            MedicationMutationStatus.retryable,
            commandId: commandId,
            safeErrorCode: errorCode ?? 'SPLIT_RECONCILIATION_UNAVAILABLE',
            safeCorrelationId: correlationId,
          );
        }
        await _recordLocalIssue(operation, effect, ids.issueId);
        await _write(
          operation,
          () => db.pendingOperationsDao.markEffectLocalReviewRequired(
            effectId: effect.id,
            issueId: ids.issueId,
          ),
        );
        await _write(
          operation,
          () => db.pendingOperationsDao.blockForReview(
            operationId: operation.id,
            safeErrorCode: errorCode ?? 'SPLIT_REVIEW_REQUIRED',
            safeCorrelationId: correlationId,
          ),
        );
        return MedicationMutationResult(
          MedicationMutationStatus.blocked,
          safeErrorCode: errorCode ?? 'SPLIT_REVIEW_REQUIRES_LOCAL_ACTION',
          safeCorrelationId: correlationId,
        );
      }
      await _recordLocalIssue(operation, effect, ids.issueId);
      await _write(
        operation,
        () => db.pendingOperationsDao.markEffectCheckpointRecorded(
          effectId: effect.id,
          receiptId: ids.issueId,
        ),
      );
    }
    await _write(
      operation,
      () => db.pendingOperationsDao.blockForReview(
        operationId: operation.id,
        safeErrorCode: 'SPLIT_REVIEW_REQUIRED',
      ),
    );
    return MedicationMutationResult(
      MedicationMutationStatus.blocked,
      commandId: commandId,
      safeErrorCode: 'SPLIT_REVIEW_REQUIRED',
    );
  }

  Future<void> _recordLocalIssue(
    PendingOperation operation,
    PendingOperationEffect effect,
    String issueId,
  ) async {
    if (await db.migrationIssuesDao.getById(issueId) != null) return;
    final now = DateTime.now().toUtc();
    await _write(
      operation,
      () => db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: issueId,
          userId: operation.userId,
          entityType: 'medication_command',
          entityId: operation.id,
          issueCode: 'legacy_split_checkpoint_pending_review',
          snapshotJson: jsonEncode({
            'operationId': operation.id,
            'mutationId': operation.mutationId,
            'effectOrdinal': effect.ordinal,
            'kind': effect.kind,
            'requestFingerprint': effect.requestFingerprint,
            'state': effect.state,
          }),
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  Map<String, dynamic>? _decode(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  String? _issueId(Object? data) {
    if (data is! Map<String, dynamic>) return null;
    final issue = data['issue'];
    return issue is Map<String, dynamic> && issue['id'] is String
        ? issue['id'] as String
        : null;
  }

  bool _isUuid(String? value) =>
      value != null &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value);

  String? _errorCode(DioException error) {
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final code = details is Map<String, dynamic> ? details['code'] : null;
    return code is String && RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(code)
        ? code
        : null;
  }

  String? _correlationId(DioException error) {
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final id = details is Map<String, dynamic>
        ? details['correlationId']
        : null;
    return id is String && id.length <= 128 ? id : null;
  }
}

List<MedicationSyncStep> selectMedicationSyncSteps(
  CapabilitySnapshot capabilities, {
  required bool hasRetainedSplitCheckpoints,
}) {
  switch (capabilities.availability) {
    case CapabilityAvailability.absent:
      return const [MedicationSyncStep.legacySplit];
    case CapabilityAvailability.unavailable:
      return const [];
    case CapabilityAvailability.localAccessUnavailable:
      return const [];
    case CapabilityAvailability.present:
      final active = capabilities.capabilities!.medicationLedgerActive;
      return [
        if (hasRetainedSplitCheckpoints)
          MedicationSyncStep.permanentReconciliation,
        active
            ? MedicationSyncStep.activeLedger
            : MedicationSyncStep.inactiveBridge,
      ];
  }
}
