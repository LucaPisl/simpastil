import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import '../../db/database.dart';
import '../../workspace/workspace_context.dart';
import '../ledger_mode_hint.dart';
import '../sync_write_scope.dart';
import 'medication_sync_adapter.dart';

class BridgePrnSyncAdapter {
  const BridgePrnSyncAdapter({
    required this.db,
    required this.dio,
    required this.writeScope,
  });
  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope writeScope;
  Future<T> _write<T>(
    PendingOperation operation,
    Future<T> Function() action,
  ) => writeScope.write(() async {
    await writeScope.requireOperation(operation);
    return action();
  });

  /// Sends one exact PRN take or undo. With [ledgerActive] the server also
  /// moves tracked stock and its receipt carries the stock outcome and the
  /// pill revision the move produced.
  Future<MedicationMutationResult> send(
    PendingOperation operation, {
    bool ledgerActive = false,
  }) async {
    await writeScope.requireOperation(operation);
    final payload = jsonDecode(operation.payloadJson) as Map<String, dynamic>;
    final command = payload['command'];
    if (command is! Map<String, dynamic> ||
        command['occurrenceId'] is! String) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'INVALID_PRN_OPERATION',
      );
    }
    final occurrence = await db.medicationLedgerDao.getOccurrenceById(
      command['occurrenceId'] as String,
    );
    if (occurrence == null ||
        occurrence.pillId == null ||
        occurrence.scheduleId == null ||
        occurrence.source != 'prn' ||
        occurrence.provenance != 'exact' ||
        occurrence.occurrenceKey != 'prn:v1:${occurrence.id}' ||
        occurrence.expected ||
        occurrence.plannedAt != null) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'PRN_IDENTITY_UNPROVEN',
      );
    }
    await writeScope.requireEntity('occurrence', occurrence.id);
    final event = await db.medicationLedgerDao.getOccurrenceEventByCommandId(
      operation.mutationId,
    );
    if (event == null ||
        event.userId != operation.userId ||
        event.occurrenceId != occurrence.id ||
        event.id != payload['eventId'] ||
        event.commandId != command['commandId']) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'PRN_EVENT_IDENTITY_UNPROVEN',
      );
    }
    if (!await _hasExactCausalChain(operation, occurrence, event)) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'PRN_CAUSAL_CHAIN_UNPROVEN',
      );
    }
    final pill = await db.pillsDao.getById(occurrence.pillId!);
    final person = pill == null
        ? null
        : await db.profilesDao.getById(pill.profileId);
    final schedule = occurrence.scheduleId == null
        ? null
        : await db.schedulesDao.getById(occurrence.scheduleId!);
    if (pill?.serverId == null ||
        person?.serverId == null ||
        schedule?.serverId == null) {
      return const MedicationMutationResult(
        MedicationMutationStatus.waitingForMapping,
        safeErrorCode: 'PRN_PARENT_NOT_MAPPED',
      );
    }
    if (person!.userId != operation.userId || schedule!.pillId != pill!.id) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    // Persisted in queued operation payloads: keep this key across renames so
    // retries of already-queued doses reuse the same request identity.
    final retained = payload['phase1PrnRequest'];
    if (retained != null && retained is! Map<String, dynamic>) {
      return _block(operation, 'PRN_REQUEST_IDENTITY_MISMATCH');
    }
    final Map<String, dynamic> request;
    if (retained is Map<String, dynamic>) {
      request = retained;
    } else if (event.action == 'take' && event.baseVersion == 0) {
      if (!pill.isPrn ||
          schedule.frequency != 'prn' ||
          !schedule.isActive ||
          schedule.isDeleted ||
          schedule.timeZoneStatus != 'known' ||
          schedule.timeZone != occurrence.timeZone ||
          schedule.revision != occurrence.scheduleRevision) {
        return const MedicationMutationResult(
          MedicationMutationStatus.conflict,
          safeErrorCode: 'PRN_ROUTINE_CHANGED',
        );
      }
      request = {
        'operation': 'take',
        'commandId': event.commandId,
        'eventId': event.id,
        'occurrenceId': occurrence.id,
        'occurrenceKey': occurrence.occurrenceKey,
        'profileId': person.serverId,
        'pillId': pill.serverId,
        'scheduleId': schedule.serverId,
        'scheduleRevision': occurrence.scheduleRevision.toString(),
        'plannedLocalDate': occurrence.plannedLocalDate,
        'timeZone': occurrence.timeZone,
        'actualAt': command['actualAt'],
        'actualTimeKnown': command['actualTimeKnown'],
        'amount': payload['administrationAmount'],
        'note': command['note'],
        ...await _recordedByField(payload),
      };
    } else if (event.action == 'undo' && occurrence.serverId == occurrence.id) {
      final head =
          await db.medicationLedgerDao.getOccurrenceEventByServerId(
            event.reversesEventId ?? '',
          ) ??
          (await db.medicationLedgerDao.getEventsForOccurrence(occurrence.id))
              .where((e) => e.id == event.reversesEventId && e.serverId == e.id)
              .singleOrNull;
      if (head == null ||
          head.userId != operation.userId ||
          head.action != 'take' ||
          head.resultVersion != event.baseVersion) {
        return const MedicationMutationResult(
          MedicationMutationStatus.waitingForMapping,
          safeErrorCode: 'PRN_REVERSAL_NOT_MAPPED',
        );
      }
      request = {
        'operation': 'undo',
        'commandId': event.commandId,
        'eventId': event.id,
        'occurrenceId': occurrence.id,
        'occurrenceKey': occurrence.occurrenceKey,
        'baseVersion': event.baseVersion.toString(),
        'reversesEventId': head.serverId,
        'note': command['note'],
        ...await _recordedByField(payload),
      };
    } else {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'PRN_COMMAND_UNSUPPORTED',
      );
    }
    if (request['commandId'] != event.commandId ||
        request['eventId'] != event.id ||
        request['occurrenceId'] != occurrence.id ||
        request['occurrenceKey'] != occurrence.occurrenceKey ||
        request['operation'] != event.action ||
        !_requestMatchesLocalEvidence(
          request: request,
          command: command,
          payload: payload,
          occurrence: occurrence,
          event: event,
          person: person,
          pill: pill,
          schedule: schedule,
        )) {
      return _block(operation, 'PRN_REQUEST_IDENTITY_MISMATCH');
    }
    var sending = operation;
    if (retained == null) {
      await _write(operation, () async {
        await (db.update(
          db.pendingOperations,
        )..where((o) => o.id.equals(operation.id))).write(
          PendingOperationsCompanion(
            payloadJson: Value(
              jsonEncode({...payload, 'phase1PrnRequest': request}),
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
      await writeScope.check();
      final response = await dio.post<dynamic>(
        '/medication/bridge/prn/commands',
        data: request,
      );
      final raw = response.data;
      final body =
          raw is Map<String, dynamic> && raw['data'] is Map<String, dynamic>
          ? raw['data']
          : raw;
      if (body is! Map ||
          body['commandId'] != event.commandId ||
          body['eventId'] != event.id ||
          body['occurrenceId'] != occurrence.id ||
          body['occurrenceKey'] != occurrence.occurrenceKey ||
          body['action'] != event.action ||
          body['state'] != event.toState ||
          body['stateVersion'] != event.resultVersion.toString() ||
          !_matchesStockReceipt(body, ledgerActive) ||
          !const DeepCollectionEquality().equals(
            body['amount'],
            event.action == 'take' ? request['amount'] : null,
          )) {
        await _write(
          sending,
          () => db.pendingOperationsDao.transitionState(
            operationId: sending.id,
            from: 'sending',
            to: 'blocked',
            safeErrorCode: 'PRN_RECEIPT_IDENTITY_MISMATCH',
          ),
        );
        return const MedicationMutationResult(
          MedicationMutationStatus.uncertain,
          safeErrorCode: 'PRN_RECEIPT_IDENTITY_MISMATCH',
        );
      }
      final committed = await _write(sending, () async {
        final ok = await db.pendingOperationsDao.transitionState(
          operationId: sending.id,
          from: 'sending',
          to: 'committed',
        );
        if (!ok) return false;
        await (db.update(
          db.medicationOccurrences,
        )..where((o) => o.id.equals(occurrence.id))).write(
          MedicationOccurrencesCompanion(serverId: Value(occurrence.id)),
        );
        await db.medicationLedgerDao.updateOccurrenceEvent(
          event.id,
          OccurrenceEventsCompanion(serverId: Value(event.id)),
        );
        if (ledgerActive) await _adoptPillRevision(pill.id, body);
        return true;
      });
      return MedicationMutationResult(
        committed
            ? MedicationMutationStatus.acknowledged
            : MedicationMutationStatus.uncertain,
        commandId: event.commandId,
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final retry =
          status == null || status >= 500 || status == 401 || status == 429;
      final code = status == 401
          ? 'AUTH_REQUIRED'
          : status == 409
          ? 'PRN_REVIEW_REQUIRED'
          : 'PRN_SHARING_UNAVAILABLE';
      await _write(
        sending,
        () => db.pendingOperationsDao.transitionState(
          operationId: sending.id,
          from: 'sending',
          to: status == 409
              ? 'conflict'
              : retry
              ? 'failedRetryable'
              : 'blocked',
          safeErrorCode: code,
        ),
      );
      if (status == 401) rethrow;
      return MedicationMutationResult(
        status == 409
            ? MedicationMutationStatus.conflict
            : retry
            ? MedicationMutationStatus.retryable
            : MedicationMutationStatus.blocked,
        safeErrorCode: code,
      );
    }
  }

  /// An inactive-ledger receipt never moves stock. An active-ledger receipt
  /// states whether stock is tracked and, if so, the signed move.
  bool _matchesStockReceipt(Map<dynamic, dynamic> body, bool ledgerActive) {
    if (!ledgerActive) {
      return body['inventoryEventId'] == null && body['inventoryDelta'] == null;
    }
    final tracked = body['inventoryTracked'];
    if (tracked is! bool || body['pillRevision'] is! String) return false;
    if (!tracked) {
      return body['inventoryEventId'] == null && body['inventoryDelta'] == null;
    }
    return body['inventoryDelta'] is int &&
        (body['inventoryEventId'] == null) == (body['inventoryDelta'] == 0);
  }

  /// Adopts the pill revision a stock move produced, as the ledger adapter
  /// does, so the next pill or inventory write has the right base. Only a
  /// single-step advance is adopted; anything else waits for the next pull.
  Future<void> _adoptPillRevision(
    String localPillId,
    Map<dynamic, dynamic> body,
  ) async {
    final raw = body['pillRevision'];
    final revision = raw is String ? int.tryParse(raw) : null;
    if (revision == null) return;
    final pill = await db.pillsDao.getById(localPillId);
    if (pill == null || revision != pill.revision + 1) return;
    await (db.update(db.pills)..where(
          (row) => row.id.equals(pill.id) & row.revision.equals(pill.revision),
        ))
        .write(PillsCompanion(revision: Value(revision)));
  }

  Future<MedicationMutationResult> _block(
    PendingOperation operation,
    String code,
  ) async {
    if (operation.state != 'blocked') {
      await _write(
        operation,
        () => db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: operation.state,
          to: 'blocked',
          safeErrorCode: code,
        ),
      );
    }
    return MedicationMutationResult(
      MedicationMutationStatus.blocked,
      safeErrorCode: code,
    );
  }

  /// The Recorded-by name, only for a server that advertised storing it. An
  /// older server's strict schema would refuse the field.
  Future<Map<String, Object?>> _recordedByField(
    Map<String, dynamic> payload,
  ) async {
    final recordedBy = payload['recordedBy'];
    if (recordedBy is! Map || !await LedgerModeHint.readRecordedBy()) {
      return const {};
    }
    return {'recordedBy': Map<String, Object?>.from(recordedBy)};
  }

  bool _requestMatchesLocalEvidence({
    required Map<String, dynamic> request,
    required Map<String, dynamic> command,
    required Map<String, dynamic> payload,
    required MedicationOccurrence occurrence,
    required OccurrenceEvent event,
    required Profile person,
    required Pill pill,
    required Schedule schedule,
  }) {
    if (request['note'] != event.note || command['note'] != event.note) {
      return false;
    }
    // A frozen name must be the one recorded with the dose, never another.
    if (request.containsKey('recordedBy') &&
        !const DeepCollectionEquality().equals(
          request['recordedBy'],
          payload['recordedBy'],
        )) {
      return false;
    }
    if (event.action == 'undo') {
      return request['baseVersion'] == event.baseVersion.toString() &&
          request['reversesEventId'] == event.reversesEventId;
    }
    Object? amount;
    try {
      amount = event.administrationAmountJson == null
          ? null
          : jsonDecode(event.administrationAmountJson!);
    } on FormatException {
      return false;
    }
    return request['profileId'] == person.serverId &&
        request['pillId'] == pill.serverId &&
        request['scheduleId'] == schedule.serverId &&
        request['scheduleRevision'] == occurrence.scheduleRevision.toString() &&
        request['plannedLocalDate'] == occurrence.plannedLocalDate &&
        request['timeZone'] == occurrence.timeZone &&
        request['actualTimeKnown'] == event.actualTimeKnown &&
        command['actualTimeKnown'] == event.actualTimeKnown &&
        _sameInstant(request['actualAt'], event.actualAt) &&
        _sameInstant(command['actualAt'], event.actualAt) &&
        const DeepCollectionEquality().equals(request['amount'], amount) &&
        const DeepCollectionEquality().equals(
          payload['administrationAmount'],
          amount,
        );
  }

  bool _sameInstant(Object? wireValue, DateTime? localValue) {
    if (wireValue == null || localValue == null) {
      return wireValue == null && localValue == null;
    }
    if (wireValue is! String) return false;
    final parsed = DateTime.tryParse(wireValue);
    if (parsed == null) return false;
    // Drift persists event instants as Unix seconds, while the frozen intent
    // keeps the instant the person recorded. Compare at stored precision, as
    // the bridge adapter does; the request still carries the full intent.
    return db.typeMapping.mapToSqlVariable(parsed.toUtc()) ==
        db.typeMapping.mapToSqlVariable(localValue.toUtc());
  }

  Future<bool> _hasExactCausalChain(
    PendingOperation operation,
    MedicationOccurrence occurrence,
    OccurrenceEvent event,
  ) async {
    final events = await db.medicationLedgerDao.getEventsForOccurrence(
      occurrence.id,
    );
    if (events.length !=
        events.map((candidate) => candidate.resultVersion).toSet().length) {
      return false;
    }
    final take = events.where(_isInitialTake).singleOrNull;
    if (take == null) return false;

    if (event.action == 'take') {
      if (event.id != take.id || event.commandId != take.commandId) {
        return false;
      }
      if (events.length == 1) {
        return occurrence.state == 'taken' && occurrence.stateVersion == 1;
      }
      if (events.length != 2) return false;
      final undo = events.where(_isExactUndo).singleOrNull;
      if (undo == null || !_reverses(undo, take)) return false;
      final undoOperation = await db.pendingOperationsDao.getByMutationId(
        operation.userId,
        undo.commandId,
      );
      return occurrence.state == 'pending' &&
          occurrence.stateVersion == 2 &&
          undoOperation != null &&
          undoOperation.component == 'medication' &&
          undoOperation.state == 'queued' &&
          undoOperation.dependsOnOperationId == operation.id &&
          _operationMatchesEvent(undoOperation, occurrence.id, undo);
    }

    if (event.action != 'undo' || events.length != 2 || !_isExactUndo(event)) {
      return false;
    }
    if (!_reverses(event, take) ||
        occurrence.state != 'pending' ||
        occurrence.stateVersion != 2) {
      return false;
    }
    final dependencyId = operation.dependsOnOperationId;
    if (dependencyId == null) return false;
    final dependency = await db.pendingOperationsDao.getById(dependencyId);
    return dependency != null &&
        dependency.userId == operation.userId &&
        dependency.component == 'medication' &&
        dependency.state == 'committed' &&
        dependency.mutationId == take.commandId &&
        _operationMatchesEvent(dependency, occurrence.id, take);
  }

  bool _isInitialTake(OccurrenceEvent event) =>
      event.action == 'take' &&
      event.fromState == 'pending' &&
      event.toState == 'taken' &&
      event.baseVersion == 0 &&
      event.resultVersion == 1 &&
      event.reversesEventId == null;

  bool _isExactUndo(OccurrenceEvent event) =>
      event.action == 'undo' &&
      event.fromState == 'taken' &&
      event.toState == 'pending' &&
      event.baseVersion == 1 &&
      event.resultVersion == 2 &&
      event.reversesEventId != null;

  bool _reverses(OccurrenceEvent undo, OccurrenceEvent take) =>
      undo.reversesEventId == take.id ||
      (take.serverId != null && undo.reversesEventId == take.serverId);

  bool _operationMatchesEvent(
    PendingOperation operation,
    String occurrenceId,
    OccurrenceEvent event,
  ) {
    try {
      final decoded = jsonDecode(operation.payloadJson);
      if (decoded is! Map<String, dynamic>) return false;
      final command = decoded['command'];
      return command is Map<String, dynamic> &&
          operation.mutationId == event.commandId &&
          decoded['eventId'] == event.id &&
          command['commandId'] == event.commandId &&
          command['occurrenceId'] == occurrenceId &&
          command['action'] == event.action;
    } on FormatException {
      return false;
    }
  }
}
