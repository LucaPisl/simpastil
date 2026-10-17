import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:uuid/uuid.dart';

import '../../db/database.dart';
import '../../workspace/workspace_context.dart';
import '../../utils/app_logger.dart';
import '../sync_retry_policy.dart';
import '../sync_write_scope.dart';
import '../../projections/projection_command_id.dart';
import '../legacy_split_checkpoint.dart';
import 'medication_sync_adapter.dart';

class BridgeMedicationSyncAdapter {
  const BridgeMedicationSyncAdapter({
    required this.db,
    required this.dio,
    this.writeScope,
    this.bridgeUndo = false,
  });

  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope? writeScope;

  /// The server advertised `bridgeUndo`: it accepts status `pending` as a soft
  /// delete of the dose. Absent or false means an Undo can never be sent.
  final bool bridgeUndo;
  static const _ids = Uuid();
  Future<T> _write<T>(
    PendingOperation operation,
    Future<T> Function() action,
  ) =>
      writeScope?.write(() async {
        await writeScope!.requireOperation(operation);
        return action();
      }) ??
      db.transaction(action);

  /// Converts an already-attempted pre-freeze bridge write into explicit
  /// ambiguous delivery evidence. It never reconstructs or sends the request.
  Future<bool> captureUnfrozenAttemptForReview(
    PendingOperation operation,
  ) async {
    if (writeScope == null ||
        operation.component != 'medication' ||
        operation.operationType != 'medication.command' ||
        operation.state != 'blocked' ||
        operation.attemptCount <= 0 ||
        operation.lastAttemptAt == null) {
      return false;
    }
    return _write(operation, () async {
      final retained = await db.pendingOperationsDao.getById(operation.id);
      if (retained == null ||
          retained.state != 'blocked' ||
          retained.attemptCount <= 0 ||
          retained.lastAttemptAt == null ||
          retained.component != 'medication' ||
          retained.operationType != 'medication.command') {
        return false;
      }
      final payload = _decode(retained.payloadJson);
      final command = payload?['command'];
      final projection = payload?['localProjection'];
      if (payload == null ||
          payload.containsKey('medicationBridgeRequest') ||
          payload['inventoryCommand'] != null ||
          command is! Map<String, dynamic> ||
          projection is! Map<String, dynamic>) {
        return false;
      }
      final occurrenceId = command['occurrenceId'];
      final pillId = projection['pillId'];
      final localDoseId = projection['legacyDoseSourceId'];
      final eventId = payload['eventId'];
      final baseVersion = command['baseVersion'] is String
          ? int.tryParse(command['baseVersion'] as String)
          : null;
      if (occurrenceId is! String ||
          pillId is! String ||
          localDoseId is! String ||
          baseVersion == null ||
          (eventId != null && eventId is! String) ||
          command['commandId'] != retained.mutationId) {
        return false;
      }
      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        occurrenceId,
      );
      if (occurrence == null ||
          occurrence.userId != retained.userId ||
          occurrence.source != 'scheduled' ||
          occurrence.provenance != 'exact' ||
          !occurrence.expected ||
          occurrence.serverId == null ||
          occurrence.pillId != pillId ||
          occurrence.scheduleId == null ||
          occurrence.plannedAt == null) {
        return false;
      }
      final event = await db.medicationLedgerDao.getOccurrenceEventByCommandId(
        retained.mutationId,
      );
      if (event == null ||
          (eventId != null && event.id != eventId) ||
          event.userId != retained.userId ||
          event.occurrenceId != occurrence.id ||
          event.commandId != retained.mutationId ||
          event.action != command['action'] ||
          event.baseVersion != baseVersion ||
          event.resultVersion != baseVersion + 1 ||
          event.fromState != projection['fromState'] ||
          event.toState != projection['toState'] ||
          occurrence.occurrenceKey != command['occurrenceKey']) {
        return false;
      }
      final pill = await db.pillsDao.getById(pillId);
      final schedule = await db.schedulesDao.getById(occurrence.scheduleId!);
      final person = pill == null
          ? null
          : await db.profilesDao.getById(pill.profileId);
      if (pill?.serverId == null ||
          schedule?.serverId == null ||
          person?.serverId == null ||
          person!.userId != retained.userId ||
          schedule!.pillId != pill!.id) {
        return false;
      }
      final effects = await db.pendingOperationsDao.getEffects(retained.id);
      if (effects.isEmpty ||
          effects.where((effect) => effect.kind == 'dose').length != 1 ||
          effects.where((effect) => effect.kind == 'inventory').length > 1 ||
          effects.any(
            (effect) =>
                effect.operationId != retained.id ||
                effect.state != 'queued' ||
                !const {'dose', 'inventory'}.contains(effect.kind) ||
                effect.legacySourceId !=
                    (effect.kind == 'dose' ? localDoseId : pillId) ||
                effect.requestFingerprint.isEmpty,
          )) {
        return false;
      }
      for (final effect in effects) {
        final changed =
            await (db.update(db.pendingOperationEffects)..where(
                  (row) =>
                      row.id.equals(effect.id) &
                      row.operationId.equals(retained.id) &
                      row.state.equals('queued'),
                ))
                .write(
                  PendingOperationEffectsCompanion(
                    state: const Value('uncertain'),
                    attemptedAt: Value(retained.lastAttemptAt),
                  ),
                );
        if (changed != 1) {
          throw StateError('Bridge attempt evidence changed during capture');
        }
      }
      final changed =
          await (db.update(db.pendingOperations)..where(
                (row) =>
                    row.id.equals(retained.id) & row.state.equals('blocked'),
              ))
              .write(
                const PendingOperationsCompanion(
                  safeErrorCode: Value(
                    'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
                  ),
                ),
              );
      if (changed != 1) {
        throw StateError('Bridge operation changed during evidence capture');
      }
      return true;
    });
  }

  Future<MedicationMutationResult> send(
    PendingOperation operation, {
    bool splitReconciled = false,
  }) async {
    await writeScope?.requireOperation(operation);
    final checkpoint = await LegacySplitCheckpoint.load(db, operation.id);
    if (checkpoint?.hasRetainedProgress == true && !splitReconciled) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'SPLIT_RECONCILIATION_REQUIRED',
      );
    }
    final payload = _decode(operation.payloadJson);
    if (payload?['inventoryCommand'] is Map<String, dynamic>) {
      return const MedicationMutationResult(
        MedicationMutationStatus.waitingForAuthority,
        safeErrorCode: 'INVENTORY_COMMAND_REQUIRES_ACTIVE_LEDGER',
      );
    }
    final command = payload?['command'];
    final projection = payload?['localProjection'];
    if (command is! Map<String, dynamic> ||
        projection is! Map<String, dynamic>) {
      return _blockUnsendable(operation, 'INVALID_MEDICATION_OPERATION');
    }
    final occurrenceId = command['occurrenceId'];
    final pillId = projection['pillId'];
    final localDoseId = projection['legacyDoseSourceId'];
    if (occurrenceId is! String ||
        pillId is! String ||
        localDoseId is! String) {
      return _blockUnsendable(operation, 'MEDICATION_IDENTITY_MISSING');
    }
    final occurrence = await db.medicationLedgerDao.getOccurrenceById(
      occurrenceId,
    );
    final pill = await db.pillsDao.getById(pillId);
    final scheduleId = occurrence?.scheduleId;
    final schedule = scheduleId == null
        ? null
        : await db.schedulesDao.getById(scheduleId);
    if (pill?.serverId == null ||
        schedule?.serverId == null ||
        occurrence?.plannedAt == null) {
      // Fixed booleans only: identify the missing link without exposing care.
      AppLogger.debug(
        'SyncDiag',
        jsonEncode({
          'event': 'medication_mapping_wait',
          'occurrenceMapped': occurrence?.serverId != null,
          'pillMapped': pill?.serverId != null,
          'scheduleMapped': schedule?.serverId != null,
          'plannedAtPresent': occurrence?.plannedAt != null,
          'canonicalV1':
              occurrence != null &&
              occurrence.snapshotVersion == 1 &&
              RegExp(
                r'^scheduled:v1:[0-9a-f]{64}$',
              ).hasMatch(occurrence.occurrenceKey),
        }),
      );
      return const MedicationMutationResult(
        MedicationMutationStatus.waitingForMapping,
        safeErrorCode: 'MEDICATION_PARENT_NOT_MAPPED',
      );
    }
    // The inactive bridge addresses dose history by canonical schedule + time,
    // not by occurrence ID. Older locally hashed plans may never have a server
    // occurrence match; prove their original native intent instead of rebinding.
    if (occurrence!.serverId == null &&
        !await _hasUnmappedScheduledIntent(
          operation,
          payload!,
          command,
          projection,
          occurrence,
          pill!,
          schedule!,
        )) {
      return _blockUnsendable(
        operation,
        'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
      );
    }
    final targetState = _targetState(command);
    if (targetState == null) {
      return _blockUnsendable(
        operation,
        'BRIDGE_CANNOT_REPRESENT_PENDING_STATE',
      );
    }
    if (targetState == 'pending' && !bridgeUndo) {
      // An older server cannot undo a dose. Never leave this queued: the retake
      // depends on it and would wait forever behind a silent operation.
      return _blockUnsendable(
        operation,
        'BRIDGE_UNDO_UNSUPPORTED',
        issueCode: 'bridge_undo_unsupported',
      );
    }
    final retained = payload?['medicationBridgeRequest'];
    if (retained != null && retained is! Map<String, dynamic>) {
      await _write(
        operation,
        () => db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: operation.state,
          to: 'blocked',
          safeErrorCode: 'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
        ),
      );
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
      );
    }
    if (retained == null &&
        (operation.attemptCount > 0 || operation.lastAttemptAt != null)) {
      await _write(
        operation,
        () => db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: operation.state,
          to: 'blocked',
          safeErrorCode: 'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
        ),
      );
      return const MedicationMutationResult(
        MedicationMutationStatus.uncertain,
        safeErrorCode: 'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
      );
    }
    final dose = await db.doseLogsDao.getById(localDoseId);
    final Map<String, Object?> request;
    if (retained is Map<String, dynamic>) {
      request = Map<String, Object?>.from(retained);
    } else {
      request = <String, Object?>{
        'commandId': command['commandId'],
        'commandBundleId': projectionCommandIdForKey(
          'medication-bundle-v1:${command['commandId']}',
        ),
        'transactionCorrelationId': projectionCommandIdForKey(
          'medication-correlation-v1:${command['commandId']}',
        ),
        'pillId': pill!.serverId,
        'scheduleId': schedule!.serverId,
        'legacyDoseId': dose?.serverId ?? localDoseId,
        'allowCreate': targetState != 'pending' && dose?.serverId == null,
        'scheduledAt': occurrence.plannedAt!.toUtc().toIso8601String(),
        'status': targetState,
        'takenAt': targetState == 'taken' ? command['actualAt'] : null,
        'note': command['note'],
        'observedBaseDoseFingerprint':
            projection['observedBaseDoseFingerprint'],
        // Bridge commands apply their delta under the server's row lock. The
        // local projection keeps the observed values for review and split
        // reconciliation, but they are never sent: the bridge bumps the pill
        // revision without a stable sync change, so a sent base goes stale
        // after the first command.
        'observedBaseStock': null,
        'observedBasePillRevision': null,
      };
    }
    if (request['commandId'] != operation.mutationId ||
        request['commandId'] != command['commandId'] ||
        request['commandBundleId'] !=
            projectionCommandIdForKey(
              'medication-bundle-v1:${command['commandId']}',
            ) ||
        request['transactionCorrelationId'] !=
            projectionCommandIdForKey(
              'medication-correlation-v1:${command['commandId']}',
            ) ||
        request['pillId'] != pill!.serverId ||
        request['scheduleId'] != schedule!.serverId ||
        request['allowCreate'] is! bool ||
        request['legacyDoseId'] != (dose?.serverId ?? localDoseId) ||
        request['scheduledAt'] !=
            occurrence.plannedAt!.toUtc().toIso8601String() ||
        request['status'] != targetState ||
        request['takenAt'] !=
            (targetState == 'taken' ? command['actualAt'] : null) ||
        request['note'] != command['note'] ||
        request['observedBaseDoseFingerprint'] !=
            projection['observedBaseDoseFingerprint'] ||
        // Requests frozen before null bases were sent keep their original base.
        (request['observedBaseStock'] != null &&
            request['observedBaseStock'] != projection['observedBaseStock']) ||
        (request['observedBasePillRevision'] != null &&
            request['observedBasePillRevision'] !=
                projection['observedBasePillRevision'])) {
      _refuseBridgeIdentity('frozen_request_mismatch');
      return _blockUnsendable(
        operation,
        'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
      );
    }
    var sending = operation;
    if (retained == null) {
      await _write(operation, () async {
        await (db.update(
          db.pendingOperations,
        )..where((row) => row.id.equals(operation.id))).write(
          PendingOperationsCompanion(
            payloadJson: Value(
              jsonEncode({...payload!, 'medicationBridgeRequest': request}),
            ),
          ),
        );
      });
      sending = (await db.pendingOperationsDao.getById(operation.id))!;
    }
    if (!await _write(sending, () => claimMedicationOperation(db, sending))) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'MEDICATION_OPERATION_CLAIM_LOST',
      );
    }
    try {
      final response = await dio.post<dynamic>(
        '/medication/bridge/commands',
        data: request,
      );
      if (_commandId(response.data) != command['commandId']) {
        await _write(
          sending,
          () => db.pendingOperationsDao.transitionState(
            operationId: sending.id,
            from: 'sending',
            to: 'blocked',
            safeErrorCode: 'MEDICATION_RECEIPT_IDENTITY_MISMATCH',
          ),
        );
        return const MedicationMutationResult(
          MedicationMutationStatus.uncertain,
          safeErrorCode: 'MEDICATION_RECEIPT_IDENTITY_MISMATCH',
        );
      }
      final committed = await _write(sending, () async {
        final moved = await db.pendingOperationsDao.transitionState(
          operationId: sending.id,
          from: 'sending',
          to: 'committed',
        );
        if (moved) await _adoptPillRevision(pill, response.data);
        return moved;
      });
      return MedicationMutationResult(
        committed
            ? MedicationMutationStatus.acknowledged
            : MedicationMutationStatus.uncertain,
        commandId: command['commandId'] as String,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        await _write(
          sending,
          () => db.pendingOperationsDao.transitionState(
            operationId: sending.id,
            from: 'sending',
            to: 'failedRetryable',
            safeErrorCode: 'AUTH_REQUIRED',
          ),
        );
        rethrow;
      }
      final status = error.response?.statusCode;
      final errorBody = error.response?.data;
      final details = errorBody is Map<String, dynamic>
          ? errorBody['error']
          : null;
      final code =
          details is Map<String, dynamic> &&
              details['code'] is String &&
              RegExp(
                r'^[A-Z][A-Z0-9_]{0,63}$',
              ).hasMatch(details['code'] as String)
          ? details['code'] as String
          : null;
      final correlation =
          details is Map<String, dynamic> &&
              details['correlationId'] is String &&
              (details['correlationId'] as String).length <= 128
          ? details['correlationId'] as String
          : null;
      final retryable =
          details is Map<String, dynamic> && details['retryable'] == true;
      if (SyncRetryPolicy.isAwaitingReconciliation(error)) {
        await _write(
          sending,
          () => db.pendingOperationsDao.transitionState(
            operationId: sending.id,
            from: 'sending',
            to: 'blocked',
            safeErrorCode: SyncRetryPolicy.awaitingReconciliationCode,
            safeCorrelationId: correlation,
          ),
        );
        return MedicationMutationResult(
          MedicationMutationStatus.blocked,
          safeErrorCode: SyncRetryPolicy.awaitingReconciliationCode,
          safeCorrelationId: correlation,
        );
      }
      if (status != 409 && (SyncRetryPolicy.isTransient(error) || retryable)) {
        // The command id is a permanent server receipt and the body is frozen,
        // so a later replay is safe. Bounded: the cap blocks with an issue.
        await _write(
          sending,
          () => db.pendingOperationsDao.settleTransientFailure(
            operation: sending,
            safeErrorCode: code ?? 'MEDICATION_BRIDGE_REJECTED',
            safeCorrelationId: correlation,
            retryAfter: SyncRetryPolicy.retryAfter(error),
          ),
        );
        final settled = await db.pendingOperationsDao.getById(sending.id);
        final exhausted = settled?.state == 'blocked';
        return MedicationMutationResult(
          exhausted
              ? MedicationMutationStatus.blocked
              : MedicationMutationStatus.retryable,
          safeErrorCode: exhausted ? SyncRetryPolicy.retryExhaustedCode : code,
          safeCorrelationId: correlation,
        );
      }
      if (status == 409 && code == 'CONFLICT_STALE_UPDATE') {
        // A stale observed base is not a decision for the person: the server
        // applies the command under its own row lock and reports the truth.
        // Drop the observed bases once and retry with a bounded budget.
        await _write(sending, () async {
          await _dropObservedBases(sending, payload!, request);
          return db.pendingOperationsDao.settleTransientFailure(
            operation: sending,
            safeErrorCode: code,
            safeCorrelationId: correlation,
          );
        });
        return MedicationMutationResult(
          MedicationMutationStatus.retryable,
          safeErrorCode: code,
          safeCorrelationId: correlation,
        );
      }
      await _write(
        sending,
        () => db.pendingOperationsDao.transitionState(
          operationId: sending.id,
          from: 'sending',
          to: status == 409 ? 'conflict' : 'blocked',
          safeErrorCode: code ?? 'MEDICATION_BRIDGE_REJECTED',
          safeCorrelationId: correlation,
        ),
      );
      return MedicationMutationResult(
        status == 409
            ? MedicationMutationStatus.conflict
            : MedicationMutationStatus.blocked,
        safeErrorCode: code,
        safeCorrelationId: correlation,
      );
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object {
      await _write(
        sending,
        () => db.pendingOperationsDao.transitionState(
          operationId: sending.id,
          from: 'sending',
          to: 'blocked',
          safeErrorCode: 'MEDICATION_BRIDGE_RESULT_UNCERTAIN',
        ),
      );
      return const MedicationMutationResult(
        MedicationMutationStatus.uncertain,
        safeErrorCode: 'MEDICATION_BRIDGE_RESULT_UNCERTAIN',
      );
    }
  }

  /// Rewrites the retained request and its local projection without the
  /// optimistic observed bases, so the retry no longer trips the stale-base
  /// check. Identity, body and ids are untouched.
  Future<void> _dropObservedBases(
    PendingOperation sending,
    Map<String, dynamic> payload,
    Map<String, Object?> request,
  ) async {
    final projection = payload['localProjection'];
    if (projection is! Map<String, dynamic>) return;
    await (db.update(
      db.pendingOperations,
    )..where((row) => row.id.equals(sending.id))).write(
      PendingOperationsCompanion(
        payloadJson: Value(
          jsonEncode({
            ...payload,
            'medicationBridgeRequest': {
              ...request,
              'observedBaseDoseFingerprint': null,
              'observedBaseStock': null,
              'observedBasePillRevision': null,
            },
            'localProjection': {
              ...projection,
              'observedBaseDoseFingerprint': null,
            },
          }),
        ),
      ),
    );
  }

  /// Records why [operation] can never be sent and moves it out of the queue.
  /// A non-HTTP refusal must be a durable transition, or the operation (and
  /// everything that depends on it) is re-evaluated forever without any
  /// visible state. A review issue makes the block discoverable.
  Future<MedicationMutationResult> _blockUnsendable(
    PendingOperation operation,
    String code, {
    String issueCode = 'bridge_command_unsendable',
  }) async {
    await _write(operation, () async {
      final moved = await db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: operation.state,
        to: 'blocked',
        safeErrorCode: code,
      );
      if (!moved) return;
      final now = DateTime.now().toUtc();
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: _ids.v4(),
          userId: operation.userId,
          entityType: 'medication_operation',
          entityId: operation.id,
          issueCode: issueCode,
          snapshotJson: jsonEncode({
            'operationId': operation.id,
            'mutationId': operation.mutationId,
            'reason': code,
          }),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
    return MedicationMutationResult(
      MedicationMutationStatus.blocked,
      safeErrorCode: code,
    );
  }

  /// The bridge bumps `pills.revision` without a stable sync change. Adopt the
  /// returned revision so a later stable PATCH is not rejected as stale.
  ///
  /// Only this command's own one-step bump is taken, for synced and pending
  /// rows alike, so a revision advanced by another device is never hidden
  /// from a later PATCH; the next pull delivers foreign revisions together
  /// with their content.
  Future<void> _adoptPillRevision(Pill pill, Object? data) async {
    final raw = _resultField(data, 'pillRevision');
    final revision = raw is String ? int.tryParse(raw) : null;
    if (revision == null) return;
    final current = await db.pillsDao.getById(pill.id);
    if (current == null || current.revision >= revision) return;
    if (revision != current.revision + 1) return;
    await (db.update(db.pills)..where(
          (row) =>
              row.id.equals(current.id) & row.revision.equals(current.revision),
        ))
        .write(PillsCompanion(revision: Value(revision)));
  }

  Object? _resultField(Object? data, String key) {
    if (data is! Map<String, dynamic>) return null;
    if (data.containsKey(key)) return data[key];
    final nested = data['data'];
    return nested is Map<String, dynamic> ? nested[key] : null;
  }

  Future<bool> _hasUnmappedScheduledIntent(
    PendingOperation operation,
    Map<String, dynamic> payload,
    Map<String, dynamic> command,
    Map<String, dynamic> projection,
    MedicationOccurrence occurrence,
    Pill pill,
    Schedule schedule,
  ) async {
    if (writeScope == null ||
        operation.component != 'medication' ||
        operation.operationType != 'medication.command' ||
        payload['userId'] != operation.userId ||
        occurrence.userId != operation.userId ||
        occurrence.source != 'scheduled' ||
        occurrence.provenance != 'exact' ||
        !occurrence.expected ||
        occurrence.snapshotVersion != 1 ||
        !RegExp(
          r'^scheduled:v1:[0-9a-f]{64}$',
        ).hasMatch(occurrence.occurrenceKey) ||
        occurrence.pillId != pill.id ||
        occurrence.scheduleId != schedule.id ||
        schedule.pillId != pill.id ||
        command['commandId'] != operation.mutationId ||
        command['occurrenceKey'] != occurrence.occurrenceKey) {
      return _refuseBridgeIdentity('native_shape_mismatch');
    }
    final person = await db.profilesDao.getById(pill.profileId);
    if (person == null ||
        person.serverId == null ||
        person.userId != operation.userId) {
      return _refuseBridgeIdentity('person_mapping_missing');
    }
    final directPill = await db.pillsDao.getById(pill.serverId!);
    final directSchedule = await db.schedulesDao.getById(schedule.serverId!);
    final directPerson = await db.profilesDao.getById(person.serverId!);
    if ((directPill != null && directPill.id != pill.id) ||
        (directSchedule != null && directSchedule.id != schedule.id) ||
        (directPerson != null && directPerson.id != person.id)) {
      return _refuseBridgeIdentity('parent_alias');
    }
    final snapshot = _decode(occurrence.scheduleSnapshotJson);
    if (snapshot?['version'] != 1 ||
        snapshot?['profileId'] != person.id ||
        snapshot?['timeZone'] != occurrence.timeZone) {
      return _refuseBridgeIdentity('snapshot_mismatch');
    }
    final intent = payload['intent'];
    if (intent is! Map<String, dynamic> ||
        intent['action'] != command['action'] ||
        intent['actualAt'] != command['actualAt'] ||
        intent['actualTimeKnown'] != command['actualTimeKnown'] ||
        intent['note'] != command['note'] ||
        (intent.containsKey('targetState') &&
            intent['targetState'] != command['targetState'])) {
      return _refuseBridgeIdentity('retained_intent_mismatch');
    }
    final event = await db.medicationLedgerDao.getOccurrenceEventByCommandId(
      operation.mutationId,
    );
    final base = command['baseVersion'] is String
        ? int.tryParse(command['baseVersion'] as String)
        : null;
    if (base == null ||
        event == null ||
        (payload.containsKey('eventId') && event.id != payload['eventId']) ||
        event.userId != operation.userId ||
        event.occurrenceId != occurrence.id ||
        event.origin != 'native' ||
        event.action != command['action'] ||
        event.baseVersion != base ||
        event.resultVersion != base + 1 ||
        event.fromState != projection['fromState'] ||
        event.toState != projection['toState'] ||
        event.toState != _targetState(command) ||
        event.note != command['note'] ||
        event.actualTimeKnown != command['actualTimeKnown'] ||
        !_storedInstantMatches(event.actualAt, command['actualAt'])) {
      return _refuseBridgeIdentity('native_event_mismatch');
    }
    final dose = await db.doseLogsDao.getById(
      projection['legacyDoseSourceId'] as String,
    );
    // Dose state, including its local Undo tombstone, is a mutable projection.
    // Its schedule/time identity must match; the immutable native event above
    // proves the original state, time and note being uploaded.
    if (dose == null ||
        dose.scheduleId != schedule.id ||
        dose.scheduledAt.toUtc() != occurrence.plannedAt!.toUtc()) {
      return _refuseBridgeIdentity('dose_locator_mismatch');
    }
    await writeScope!.requireEntity('occurrence', occurrence.id);
    await writeScope!.requireEntity('profile', person.id);
    return true;
  }

  bool _storedInstantMatches(DateTime? stored, Object? wire) {
    if (stored == null || wire == null) return stored == null && wire == null;
    if (wire is! String) return false;
    final parsed = DateTime.tryParse(wire);
    if (parsed == null) return false;
    // Drift persists these event instants as Unix seconds. Validate at that
    // precision; the request retains the full original frozen intent above.
    return db.typeMapping.mapToSqlVariable(stored.toUtc()) ==
        db.typeMapping.mapToSqlVariable(parsed.toUtc());
  }

  bool _refuseBridgeIdentity(String reason) {
    AppLogger.debug(
      'SyncDiag',
      jsonEncode({
        'event': 'medication_bridge_identity_refused',
        'reason': reason,
      }),
    );
    return false;
  }

  Map<String, dynamic>? _decode(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  String? _commandId(Object? data) {
    if (data is! Map<String, dynamic>) return null;
    if (data['commandId'] is String) return data['commandId'] as String;
    final nested = data['data'];
    return nested is Map<String, dynamic> && nested['commandId'] is String
        ? nested['commandId'] as String
        : null;
  }

  String? _targetState(Map<String, dynamic> command) {
    final target = command['targetState'];
    if (target is String) return target;
    return switch (command['action']) {
      'take' => 'taken',
      'skip' => 'skipped',
      _ => null,
    };
  }
}
