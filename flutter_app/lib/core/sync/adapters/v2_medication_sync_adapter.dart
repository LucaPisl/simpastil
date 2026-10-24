import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;

import '../../db/database.dart';
import '../../inventory/exact_stock.dart';
import '../../inventory/pill_stock.dart';
import '../../medication/auto_miss_discard.dart';
import '../../workspace/workspace_context.dart';
import '../held_stock.dart';
import '../ledger_mode_hint.dart';
import '../pill_unsent_work.dart';
import '../stable_record_merger.dart'
    show mergeWirePillDetails, wirePillCompanion;
import '../sync_retry_policy.dart';
import '../sync_write_scope.dart';
import '../legacy_split_checkpoint.dart';
import 'medication_sync_adapter.dart';

class V2MedicationSyncAdapter {
  const V2MedicationSyncAdapter({
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
    final rawInventoryCommand = payload?['inventoryCommand'];
    if (rawInventoryCommand is Map<String, dynamic>) {
      return _sendInventory(operation, rawInventoryCommand);
    }
    final rawCommand = payload?['command'];
    if (rawCommand is! Map<String, dynamic>) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'INVALID_MEDICATION_OPERATION',
      );
    }
    // A stock-setting command is a dependency of every later stock effect for
    // the same pill: sent first, a dose would land on a NULL server count and
    // lose its effect. Waiting costs no attempt.
    final projectionForGate = payload?['localProjection'];
    final gatePillId = projectionForGate is Map
        ? projectionForGate['pillId']
        : null;
    if (payload?['resolvedCommand'] == null &&
        gatePillId is String &&
        await _startPrecedes(operation, gatePillId)) {
      return const MedicationMutationResult(
        MedicationMutationStatus.waitingForMapping,
        safeErrorCode: _startPendingCode,
      );
    }
    final dependencyId = operation.dependsOnOperationId;
    if (dependencyId != null) {
      final dependency = await db.pendingOperationsDao.getById(dependencyId);
      if (dependency?.userId != operation.userId ||
          dependency?.state != 'committed') {
        return const MedicationMutationResult(
          MedicationMutationStatus.waitingForMapping,
          safeErrorCode: 'MEDICATION_DEPENDENCY_PENDING',
        );
      }
    }
    final localOccurrenceId = rawCommand['occurrenceId'];
    if (localOccurrenceId is! String) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'MEDICATION_OCCURRENCE_ID_MISSING',
      );
    }
    final occurrence = await db.medicationLedgerDao.getOccurrenceById(
      localOccurrenceId,
    );
    if (occurrence?.serverId == null ||
        occurrence?.occurrenceKey != rawCommand['occurrenceKey']) {
      return const MedicationMutationResult(
        MedicationMutationStatus.waitingForMapping,
        safeErrorCode: 'EXACT_OCCURRENCE_NOT_MAPPED',
      );
    }
    final frozen = payload?['resolvedCommand'];
    final command = frozen is Map<String, dynamic>
        ? Map<String, Object?>.from(frozen)
        : <String, Object?>{
            ...rawCommand,
            'occurrenceId': occurrence!.serverId,
          };
    if (frozen == null) {
      // The existing stored command retains local intent. Only this frozen
      // request uses mapped IDs and the server's action-specific wire fields.
      if (rawCommand['action'] != 'correct') command.remove('targetState');
      // How much was taken, so stock counted in a unit loses exactly that. Only
      // a take or a correction can consume stock, and an unknown amount is not
      // sent: the server then leaves the stock alone or applies the plain
      // whole-dose rule.
      // An older server's strict schema refuses the field, so it goes only to a
      // server that advertised exact stock.
      final amount = payload?['administrationAmount'];
      if (await LedgerModeHint.readFractionalStock() &&
          (rawCommand['action'] == 'take' ||
              rawCommand['action'] == 'correct') &&
          amount is Map &&
          amount['state'] == 'known') {
        command['administrationAmount'] = Map<String, Object?>.from(amount);
      }
      // The name of who gave the dose, only to a server that stores it and
      // never on a miss (the app, not a person, records those).
      final recordedBy = payload?['recordedBy'];
      if (recordedBy is Map &&
          rawCommand['action'] != 'miss' &&
          await LedgerModeHint.readRecordedBy()) {
        command['recordedBy'] = Map<String, Object?>.from(recordedBy);
      }
      if (rawCommand['action'] != 'undo') {
        command.remove('reversesEventId');
      } else {
        final reference = rawCommand['reversesEventId'];
        final events = await db.medicationLedgerDao.getEventsForOccurrence(
          localOccurrenceId,
        );
        final referenced = events
            .where(
              (e) =>
                  e.userId == operation.userId &&
                  (e.id == reference || e.serverId == reference),
            )
            .singleOrNull;
        if (referenced?.serverId == null) {
          return const MedicationMutationResult(
            MedicationMutationStatus.waitingForMapping,
            safeErrorCode: 'REVERSAL_EVENT_NOT_MAPPED',
          );
        }
        final mapped =
            events
                .where(
                  (e) => e.userId == operation.userId && e.serverId != null,
                )
                .toList()
              ..sort((a, b) => a.resultVersion.compareTo(b.resultVersion));
        final remoteHead = mapped.lastOrNull;
        final baseVersion = int.tryParse(
          rawCommand['baseVersion']?.toString() ?? '',
        );
        if (remoteHead?.id != referenced!.id ||
            remoteHead?.resultVersion != baseVersion) {
          await _write(
            operation,
            () => db.pendingOperationsDao.transitionState(
              operationId: operation.id,
              from: operation.state,
              to: 'conflict',
              safeErrorCode: 'REVERSAL_HEAD_CHANGED',
            ),
          );
          return const MedicationMutationResult(
            MedicationMutationStatus.conflict,
            safeErrorCode: 'REVERSAL_HEAD_CHANGED',
          );
        }
        command['reversesEventId'] = referenced.serverId;
      }
    }
    var headChanged = false;
    final claimed = await _write(operation, () async {
      final current = await db.pendingOperationsDao.getById(operation.id);
      if (current == null ||
          current.payloadJson != operation.payloadJson ||
          !const {'queued', 'failedRetryable'}.contains(current.state)) {
        return null;
      }
      if (frozen == null) {
        final currentOccurrence = await db.medicationLedgerDao
            .getOccurrenceById(localOccurrenceId);
        if (currentOccurrence?.serverId != command['occurrenceId'] ||
            currentOccurrence?.occurrenceKey != rawCommand['occurrenceKey']) {
          return null;
        }
        if (rawCommand['action'] == 'undo') {
          final events =
              (await db.medicationLedgerDao.getEventsForOccurrence(
                    localOccurrenceId,
                  ))
                  .where(
                    (e) => e.userId == operation.userId && e.serverId != null,
                  )
                  .toList()
                ..sort((a, b) => a.resultVersion.compareTo(b.resultVersion));
          final head = events.lastOrNull;
          if (head?.serverId != command['reversesEventId'] ||
              head?.resultVersion.toString() != command['baseVersion']) {
            headChanged = true;
            await db.pendingOperationsDao.transitionState(
              operationId: operation.id,
              from: current.state,
              to: 'conflict',
              safeErrorCode: 'REVERSAL_HEAD_CHANGED',
            );
            return null;
          }
        }
        await (db.update(
          db.pendingOperations,
        )..where((o) => o.id.equals(operation.id))).write(
          PendingOperationsCompanion(
            payloadJson: Value(
              jsonEncode({...payload!, 'resolvedCommand': command}),
            ),
          ),
        );
      }
      final resolved = (await db.pendingOperationsDao.getById(operation.id))!;
      return await claimMedicationOperation(db, resolved) ? resolved : null;
    });
    if (claimed == null) {
      if (headChanged) {
        return const MedicationMutationResult(
          MedicationMutationStatus.conflict,
          safeErrorCode: 'REVERSAL_HEAD_CHANGED',
        );
      }
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'MEDICATION_OPERATION_CLAIM_LOST',
      );
    }
    operation = claimed;
    try {
      final response = await dio.post<dynamic>(
        '/medication/commands',
        data: command,
      );
      if (_commandId(response.data) != command['commandId']) {
        await _write(
          operation,
          () => db.pendingOperationsDao.transitionState(
            operationId: operation.id,
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
      final committed = await _write(operation, () async {
        final moved = await db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: 'sending',
          to: 'committed',
        );
        if (moved) {
          final projection = payload?['localProjection'];
          await _adoptPillRevision(
            projection is Map ? projection['pillId'] : null,
            response.data,
            'pillRevision',
          );
        }
        return moved;
      });
      final dosePillId = payload?['localProjection'] is Map
          ? (payload!['localProjection'] as Map)['pillId']
          : null;
      if (committed && dosePillId is String) {
        // A recount mark this dose held back may now be one the server
        // already cleared: take its word now, not at the pill's next change.
        await _takeSettledRecountMark(operation, dosePillId);
      }
      return MedicationMutationResult(
        committed
            ? MedicationMutationStatus.acknowledged
            : MedicationMutationStatus.uncertain,
        commandId: command['commandId'] as String,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        await _write(
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
      return _failed(operation, error, 'MEDICATION_COMMAND_REJECTED');
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object {
      await _write(
        operation,
        () => db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: 'sending',
          to: 'blocked',
          safeErrorCode: 'MEDICATION_COMMAND_RESULT_UNCERTAIN',
        ),
      );
      return const MedicationMutationResult(
        MedicationMutationStatus.uncertain,
        safeErrorCode: 'MEDICATION_COMMAND_RESULT_UNCERTAIN',
      );
    }
  }

  Future<MedicationMutationResult> _sendInventory(
    PendingOperation operation,
    Map<String, dynamic> rawCommand,
  ) async {
    final localPillId = rawCommand['pillId'];
    if (localPillId is! String) {
      return const MedicationMutationResult(
        MedicationMutationStatus.blocked,
        safeErrorCode: 'INVENTORY_PILL_ID_MISSING',
      );
    }
    final pill = await db.pillsDao.getById(localPillId);
    if (pill?.serverId == null || pill!.revision < 1) {
      return const MedicationMutationResult(
        MedicationMutationStatus.waitingForMapping,
        safeErrorCode: 'INVENTORY_PILL_NOT_MAPPED',
      );
    }
    // Frozen at first send, in the claim transaction: a replay after a lost
    // response carries the same baseRevision under the same command id.
    final payload = _decode(operation.payloadJson);
    final retained = payload?['resolvedInventoryRequest'];
    final action = rawCommand['action'];
    if (retained == null && action != 'start') {
      // Ordered after the pill's start: a correction is a delta on a count the
      // start has not set yet.
      if (await _startPrecedes(operation, localPillId)) {
        return const MedicationMutationResult(
          MedicationMutationStatus.waitingForMapping,
          safeErrorCode: _startPendingCode,
        );
      }
    }
    Map<String, Object?> request;
    ({int? targetStock, String? baseRevision})? rebasedCorrection;
    String? signature;
    if (retained is Map<String, dynamic>) {
      request = Map<String, Object?>.from(retained);
    } else {
      request = <String, Object?>{
        ...rawCommand,
        'pillId': pill.serverId,
        'baseRevision': pill.revision.toString(),
      };
      if (action == 'correct') {
        signature = await _stockSignature(pill.id);
        final rebased = await _rebaseHeldCorrection(
          operation,
          pill,
          rawCommand,
        );
        if (rebased.result != null) return rebased.result!;
        if (rebased.targetStock != null) {
          rebasedCorrection = (
            targetStock: rebased.targetStock,
            baseRevision: rebased.baseRevision,
          );
        }
      }
    }
    MedicationMutationResult? waiting;
    var folded = <String>[];
    final claimed = await _write(operation, () async {
      if (retained == null && payload != null) {
        final correction = rebasedCorrection;
        if (correction != null) {
          // The phone's count moved while the server count was being read
          // (a dose recorded from a notification): the delta would be wrong.
          if (await _stockSignature(pill.id) != signature) {
            waiting = const MedicationMutationResult(
              MedicationMutationStatus.waitingForMapping,
              safeErrorCode: 'INVENTORY_STOCK_MOVED',
            );
            return null;
          }
          request['targetStock'] = correction.targetStock;
          request['baseRevision'] = correction.baseRevision;
        }
        if (action == 'start') {
          // Read inside the claim, so a dose recorded meanwhile is counted
          // exactly once: in this count or after it, never both or neither.
          final fresh = await db.pillsDao.getById(pill.id);
          final decision = await _rebaseHeldStart(
            operation,
            fresh ?? pill,
            rawCommand,
          );
          if (decision.waitCode != null) {
            waiting = MedicationMutationResult(
              MedicationMutationStatus.waitingForMapping,
              safeErrorCode: decision.waitCode,
            );
            return null;
          }
          if (decision.initial != null) {
            request['initialStock'] = decision.initial;
          }
          folded = [for (final e in decision.folded) e.id];
        }
        await (db.update(
          db.pendingOperations,
        )..where((row) => row.id.equals(operation.id))).write(
          PendingOperationsCompanion(
            payloadJson: Value(
              jsonEncode({
                ...payload,
                'resolvedInventoryRequest': request,
                // Marked on the local events only once the opening commits.
                if (folded.isNotEmpty) 'foldedEventIds': folded,
              }),
            ),
          ),
        );
      }
      final current = (await db.pendingOperationsDao.getById(operation.id))!;
      return await claimMedicationOperation(db, current) ? current : null;
    });
    if (claimed == null) {
      final stuck = waiting;
      if (stuck != null &&
          stuck.safeErrorCode == 'INVENTORY_START_STOCK_UNKNOWN') {
        // The phone has no count to open with, and nothing will give it one:
        // waiting silently would strand the stock tracking. It becomes a
        // review item (Use server version, or Discard).
        return _sendToReview(operation, 'INVENTORY_START_STOCK_UNKNOWN');
      }
      return waiting ??
          const MedicationMutationResult(
            MedicationMutationStatus.blocked,
            safeErrorCode: 'MEDICATION_OPERATION_CLAIM_LOST',
          );
    }
    operation = claimed;
    return _postAndCommit(
      operation,
      request,
      path: '/medication/inventory/commands',
      localPillId: localPillId,
    );
  }

  static const _startPendingCode = inventoryStartPendingCode;

  /// Whether an unsettled start for this pill, recorded before [operation],
  /// can still apply: later stock effects wait for it. A start in conflict or
  /// blocked for review releases them; see [startCanStillApply].
  Future<bool> _startPrecedes(PendingOperation operation, String localPillId) =>
      startPrecedes(db, operation, localPillId);

  /// What a delta rebase depends on: the phone's count and its local events.
  Future<String> _stockSignature(String localPillId) async {
    final pill = await db.pillsDao.getById(localPillId);
    final events = await db.medicationLedgerDao.getInventoryEventsForPill(
      localPillId,
    );
    return '${pill?.currentStock}:${pill?.stockQuantity}:${events.length}:'
        '${sumExact(events.map(exactDeltaOf))}';
  }

  /// Starting stock tracking is saved as the opening count the person typed
  /// (say 10), but in bridge mode it is held until the ledger is active. Doses
  /// taken meanwhile went through the bridge, which applies no stock delta
  /// while the server count is unset, so the server never saw them. Sent as
  /// the absolute 10 the opening would wipe them out (phone 8, server 10).
  ///
  /// The opening is therefore sent as what the phone's own count implies: the
  /// count the phone shows, minus the effect of every command still unsent
  /// (those are ordered after the start and apply on the server after it).
  /// Bridge-delivered doses are settled, so they are folded into the opening.
  ///
  /// Two cases are not guessed:
  /// - The phone count is unknown, or a command that touches this pill is
  ///   blocked or in conflict (its effect on the server is uncertain): the
  ///   start waits, visibly, until that is settled or discarded.
  /// - An unsent undo of a dose the server holds no inventory event for (a
  ///   folded bridge-era dose) is applied by the server as 0, so its local +1
  ///   is not subtracted: the opening already reflects the undone dose.
  ///   (Known limit: an undo made after the opening committed cannot be
  ///   reversed by the server either; see docs/ARCHITECTURE.md.)
  ///
  /// Runs inside the claim transaction. A null `initial` sends the typed count.
  Future<({int? initial, String? waitCode, List<InventoryEvent> folded})>
  _rebaseHeldStart(
    PendingOperation operation,
    Pill pill,
    Map<String, dynamic> rawCommand,
  ) async {
    const none = (initial: null, waitCode: null, folded: <InventoryEvent>[]);
    final typed = rawCommand['initialStock'];
    final events = await db.medicationLedgerDao.getInventoryEventsForPill(
      pill.id,
    );
    final own = events
        .where(
          (e) => e.commandId == operation.mutationId && e.kind == 'opening',
        )
        .firstOrNull;
    if (typed is! int || own == null) return none;
    final current = pill.currentStock;
    if (current == null) {
      return (
        initial: null,
        waitCode: 'INVENTORY_START_STOCK_UNKNOWN',
        folded: <InventoryEvent>[],
      );
    }
    final all = await db.pendingOperationsDao.getUnsettledForUser(
      operation.userId,
    );
    final others = [
      for (final op in all)
        if (op.component == 'medication' && op.id != operation.id) op,
    ];
    final unsent = {for (final op in others) op.mutationId};
    final touched = events.where((e) => unsent.contains(e.commandId)).toList();
    final uncertain = [
      for (final op in others)
        if ((op.state == 'blocked' || op.state == 'conflict') &&
            touched.any(
              (e) => e.commandId == op.mutationId && !exactDeltaOf(e).isZero,
            ))
          op,
    ];
    if (uncertain.isNotEmpty) {
      return (
        initial: null,
        waitCode: 'INVENTORY_START_WAITS_FOR_REVIEW',
        folded: <InventoryEvent>[],
      );
    }
    bool serverHasNoEventFor(InventoryEvent reversal) {
      final target = reversal.reversesInventoryEventId;
      if (target == null) return false;
      final reversed = events
          .where((e) => e.id == target || e.serverId == target)
          .firstOrNull;
      return reversed != null &&
          reversed.serverId == null &&
          !unsent.contains(reversed.commandId);
    }

    var effect = ExactStock.zero;
    for (final e in touched) {
      if (e.kind == 'dose_reversal' && serverHasNoEventFor(e)) continue;
      effect += exactDeltaOf(e);
    }
    final folded = [
      for (final e in events)
        if (e.id != own.id &&
            !unsent.contains(e.commandId) &&
            e.serverId == null &&
            (e.kind == 'dose' || e.kind == 'dose_reversal') &&
            e.recordedAt.isAfter(own.recordedAt))
          e,
    ];
    // A held start is a plain whole count; a fraction in a held effect is not
    // guessed, the typed count is sent as it is.
    if (!effect.isWhole || pill.stockUnit != null) return none;
    final rebased = current - effect.floor;
    if (rebased < -2147483648 || rebased > 2147483647) return none;
    return (
      initial: rebased == typed ? null : rebased,
      waitCode: null,
      folded: folded,
    );
  }

  /// Marks local dose events that a committed opening includes. The server
  /// holds no event for them; its opening carries their effect. Done at
  /// commit, not at claim: an opening that fails or is discarded folded
  /// nothing, and a later undo of those doses must still move the stock.
  Future<void> _markFolded(
    PendingOperation operation,
    Map<String, Object?> request,
    String localPillId,
  ) async {
    if (request['action'] != 'start') return;
    final payload = _decode(operation.payloadJson);
    final ids = payload?['foldedEventIds'];
    if (ids is! List) return;
    final wanted = ids.whereType<String>().toSet();
    for (final e in await db.medicationLedgerDao.getInventoryEventsForPill(
      localPillId,
    )) {
      if (!wanted.contains(e.id)) continue;
      Map<String, dynamic> existing = {};
      try {
        final decoded = jsonDecode(e.provenanceJson ?? '{}');
        if (decoded is Map<String, dynamic>) existing = decoded;
      } on FormatException {
        existing = {};
      }
      if (existing.containsKey('foldedIntoOpening')) continue;
      await db.medicationLedgerDao.updateInventoryEvent(
        e.id,
        InventoryEventsCompanion(
          provenanceJson: Value(
            jsonEncode({
              ...existing,
              'foldedIntoOpening': operation.mutationId,
            }),
          ),
        ),
      );
    }
  }

  /// A stock correction is saved as the count the person made, but it may be
  /// sent long after (held for the ledger in bridge mode). Doses taken in
  /// between, here or on another device, already moved the stock, so an
  /// absolute target would wipe them out. The correction is therefore always
  /// sent as a delta on the server's own count: `server + (target - stock the
  /// phone had before the edit)`.
  ///
  /// The server count must be the one this phone expects (its own count minus
  /// every local stock effect the server has not received yet). If it moved
  /// some other way, for example by another device, the correction is not
  /// applied: it goes to review as a conflict. If the count cannot be read
  /// (transport failure, unreadable body, pill missing from the list) the
  /// operation is retried with the normal attempt accounting; only a pill the
  /// server no longer has (404, or a tombstone already pulled) goes to review.
  ///
  /// Known limit, erring toward review: the expected count only subtracts
  /// unsent inventory events. An unsent `stable` pill update that carries
  /// `currentStock`, or a discarded command whose pill row stays guarded by
  /// another open operation, moves the phone count without such an event and
  /// forces a review the delta rule could have handled.
  Future<
    ({MedicationMutationResult? result, int? targetStock, String? baseRevision})
  >
  _rebaseHeldCorrection(
    PendingOperation operation,
    Pill pill,
    Map<String, dynamic> rawCommand,
  ) async {
    const unchanged = (result: null, targetStock: null, baseRevision: null);
    final target = rawCommand['targetStock'];
    final events = await db.medicationLedgerDao.getInventoryEventsForPill(
      pill.id,
    );
    final own = events
        .where(
          (e) => e.commandId == operation.mutationId && e.kind == 'correction',
        )
        .firstOrNull;
    if (target is! int || own == null || pill.currentStock == null) {
      return unchanged;
    }
    // Always checked, even with no later local event: another device may have
    // moved the server count, and a device clock stepping backwards can hide
    // this phone's own later events from a timestamp comparison.
    if (pill.isDeleted) {
      // The pill was deleted (the tombstone arrived by pull): the correction
      // has nothing left to correct, so it follows the existing review path.
      return (
        result: await _sendCorrectionToReview(operation),
        targetStock: null,
        baseRevision: null,
      );
    }

    final profile = await db.profilesDao.getById(pill.profileId);
    final profileServerId = profile?.serverId;
    if (profileServerId == null) {
      return (
        result: const MedicationMutationResult(
          MedicationMutationStatus.waitingForMapping,
          safeErrorCode: 'INVENTORY_PILL_NOT_MAPPED',
        ),
        targetStock: null,
        baseRevision: null,
      );
    }
    int? serverStock;
    String? serverRevision;
    try {
      final response = await dio.get<dynamic>(
        '/profiles/$profileServerId/pills',
      );
      final data = response.data;
      final rows = data is Map<String, dynamic> ? data['pills'] : null;
      if (rows is List) {
        for (final row in rows) {
          if (row is Map<String, dynamic> && row['id'] == pill.serverId) {
            serverStock = row['currentStock'] is int
                ? row['currentStock'] as int
                : null;
            serverRevision = row['revision'] is String
                ? row['revision'] as String
                : null;
          }
        }
      }
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) rethrow;
      // The profile or pill is gone on the server: nothing to correct.
      if (error.response?.statusCode == 404) {
        return (
          result: await _sendCorrectionToReview(operation),
          targetStock: null,
          baseRevision: null,
        );
      }
      // Anything else (5xx, timeout, proxy refusal) is retried with the
      // normal attempt accounting and backoff.
      return (
        result: await _deferCorrection(operation),
        targetStock: null,
        baseRevision: null,
      );
    }
    if (serverStock == null || serverRevision == null) {
      // A body that is not a pill list (a captive portal answering 200), or a
      // listed pill without a readable count, or a pill missing from the list
      // are retried a bounded number of times; the cap leaves a review issue.
      // Once the pull delivers the pill's tombstone, the isDeleted check above
      // sends the correction to review.
      return (
        result: await _deferCorrection(operation),
        targetStock: null,
        baseRevision: null,
      );
    }
    // What the server should hold if nothing but this phone's sent commands
    // moved it: the phone's count without the effects still unsent.
    final unsent = <String>{
      for (final op in await db.pendingOperationsDao.getUnsettledForUser(
        operation.userId,
      ))
        if (op.component == 'medication') op.mutationId,
    };
    final unsentEffect = sumExact(
      events.where((e) => unsent.contains(e.commandId)).map(exactDeltaOf),
    );
    final ownEffect = exactDeltaOf(own);
    // Held corrections are whole counts; a fractional effect goes to review.
    if (!unsentEffect.isWhole || !ownEffect.isWhole || pill.stockUnit != null) {
      return (
        result: await _sendCorrectionToReview(operation),
        targetStock: null,
        baseRevision: null,
      );
    }
    final expectedServer = pill.currentStock! - unsentEffect.floor;
    if (serverStock != expectedServer) {
      return (
        result: await _sendCorrectionToReview(operation),
        targetStock: null,
        baseRevision: null,
      );
    }
    // The local event records the correction as `target - stock before it`.
    final rebased = serverStock + ownEffect.floor;
    if (rebased < -2147483648 || rebased > 2147483647) {
      return (
        result: await _sendCorrectionToReview(operation),
        targetStock: null,
        baseRevision: null,
      );
    }
    return (result: null, targetStock: rebased, baseRevision: serverRevision);
  }

  /// The server count could not be read. Uses the same bookkeeping as a failed
  /// POST: the attempt is counted, the backoff applies, and once
  /// [SyncRetryPolicy.maxAttempts] is spent the operation is blocked with a
  /// review issue.
  Future<MedicationMutationResult> _deferCorrection(
    PendingOperation operation,
  ) async {
    const code = 'INVENTORY_SERVER_STOCK_UNAVAILABLE';
    await _write(operation, () async {
      if (!await claimMedicationOperation(db, operation)) return;
      await db.pendingOperationsDao.settleTransientFailure(
        operation: operation,
        safeErrorCode: code,
      );
    });
    final settled = await db.pendingOperationsDao.getById(operation.id);
    final exhausted = settled?.state == 'blocked';
    return MedicationMutationResult(
      exhausted
          ? MedicationMutationStatus.blocked
          : MedicationMutationStatus.retryable,
      safeErrorCode: exhausted ? SyncRetryPolicy.retryExhaustedCode : code,
    );
  }

  Future<MedicationMutationResult> _sendCorrectionToReview(
    PendingOperation operation,
  ) => _sendToReview(operation, 'CONFLICT_STALE_UPDATE');

  Future<MedicationMutationResult> _sendToReview(
    PendingOperation operation,
    String code,
  ) async {
    await _write(
      operation,
      () => db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: operation.state,
        to: 'conflict',
        safeErrorCode: code,
      ),
    );
    return MedicationMutationResult(
      MedicationMutationStatus.conflict,
      safeErrorCode: code,
    );
  }

  Future<MedicationMutationResult> _postAndCommit(
    PendingOperation operation,
    Map<String, Object?> request, {
    required String path,
    required String localPillId,
  }) async {
    try {
      Response<dynamic> response;
      try {
        response = await dio.post<dynamic>(path, data: request);
      } on DioException catch (error) {
        final rebased = await _rebaseRefillOn409(
          operation,
          request,
          localPillId,
          error,
        );
        if (rebased == null) rethrow;
        if (rebased.deferred) return rebased.deferredResult!;
        request = rebased.request!;
        operation = rebased.operation!;
        response = await dio.post<dynamic>(path, data: request);
      }
      if (_commandId(response.data) != request['commandId']) {
        await _write(
          operation,
          () => db.pendingOperationsDao.transitionState(
            operationId: operation.id,
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
      final committed = await _write(operation, () async {
        final moved = await db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: 'sending',
          to: 'committed',
        );
        if (moved) {
          await _adoptPillRevision(localPillId, response.data, 'revision');
          await _markFolded(operation, request, localPillId);
          // An edit saved with this stock change kept the row unsent while
          // this command waited. With nothing else waiting, the flag goes, so
          // the pill takes the server's later changes again.
          await settleIdlePendingPills(db, operation.userId, only: localPillId);
        }
        return moved;
      });
      if (committed) {
        await _refreshAfterRevisionGap(operation, localPillId, response.data);
        await _takeSettledRecountMark(operation, localPillId);
      }
      return MedicationMutationResult(
        committed
            ? MedicationMutationStatus.acknowledged
            : MedicationMutationStatus.uncertain,
        commandId: request['commandId'] as String,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        await _write(
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
      return _failed(operation, error, 'MEDICATION_INVENTORY_REJECTED');
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object {
      await _write(
        operation,
        () => db.pendingOperationsDao.transitionState(
          operationId: operation.id,
          from: 'sending',
          to: 'blocked',
          safeErrorCode: 'MEDICATION_INVENTORY_RESULT_UNCERTAIN',
        ),
      );
      return const MedicationMutationResult(
        MedicationMutationStatus.uncertain,
        safeErrorCode: 'MEDICATION_INVENTORY_RESULT_UNCERTAIN',
      );
    }
  }

  /// A refill is a pure delta, so a stale `baseRevision` (a dose recorded on
  /// another device, an edit not pulled yet) is no reason to ask a person: the
  /// phone reads the server's current revision, freezes it into the same
  /// command and resends it under the same id. An older server that still
  /// answers 409 for a revision mismatch is handled the same way. Returns
  /// null when this is not a revision mismatch of a refill. When the revision
  /// cannot be read the refill is retried later, never sent to review.
  Future<
    ({
      Map<String, Object?>? request,
      PendingOperation? operation,
      bool deferred,
      MedicationMutationResult? deferredResult,
    })?
  >
  _rebaseRefillOn409(
    PendingOperation operation,
    Map<String, Object?> request,
    String localPillId,
    DioException error,
  ) async {
    if (request['action'] != 'refill' || error.response?.statusCode != 409) {
      return null;
    }
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final code = details is Map<String, dynamic> ? details['code'] : null;
    if (code != null && code != 'CONFLICT_STALE_UPDATE') return null;
    final revision = await _readServerRevision(localPillId);
    if (revision == null || revision == request['baseRevision']) {
      await _write(
        operation,
        () => db.pendingOperationsDao.settleTransientFailure(
          operation: operation,
          safeErrorCode: 'INVENTORY_SERVER_REVISION_UNAVAILABLE',
        ),
      );
      final settled = await db.pendingOperationsDao.getById(operation.id);
      final exhausted = settled?.state == 'blocked';
      return (
        request: null,
        operation: null,
        deferred: true,
        deferredResult: MedicationMutationResult(
          exhausted
              ? MedicationMutationStatus.blocked
              : MedicationMutationStatus.retryable,
          safeErrorCode: exhausted
              ? SyncRetryPolicy.retryExhaustedCode
              : 'INVENTORY_SERVER_REVISION_UNAVAILABLE',
        ),
      );
    }
    final rebased = {...request, 'baseRevision': revision};
    await _write(operation, () async {
      final current = await db.pendingOperationsDao.getById(operation.id);
      final payload = current == null ? null : _decode(current.payloadJson);
      if (current == null || payload == null) return;
      await (db.update(
        db.pendingOperations,
      )..where((row) => row.id.equals(operation.id))).write(
        PendingOperationsCompanion(
          payloadJson: Value(
            jsonEncode({...payload, 'resolvedInventoryRequest': rebased}),
          ),
        ),
      );
    });
    final refreshed = await db.pendingOperationsDao.getById(operation.id);
    return (
      request: rebased,
      operation: refreshed ?? operation,
      deferred: false,
      deferredResult: null,
    );
  }

  /// The server's current revision of the pill, or null when unreadable.
  Future<String?> _readServerRevision(String localPillId) async {
    final row = await _readServerPill(localPillId);
    final revision = row?['revision'];
    return revision is String ? revision : null;
  }

  /// The server's row for the pill from the profile's pill list, or null when
  /// it cannot be read (offline, an unreadable body, the pill missing).
  Future<Map<String, dynamic>?> _readServerPill(String localPillId) async {
    final pill = await db.pillsDao.getById(localPillId);
    final profile = pill == null
        ? null
        : await db.profilesDao.getById(pill.profileId);
    final profileServerId = profile?.serverId;
    if (pill?.serverId == null || profileServerId == null) return null;
    try {
      final response = await dio.get<dynamic>(
        '/profiles/$profileServerId/pills',
      );
      final data = response.data;
      final rows = data is Map<String, dynamic> ? data['pills'] : null;
      if (rows is! List) return null;
      for (final row in rows) {
        if (row is Map<String, dynamic> && row['id'] == pill!.serverId) {
          return row;
        }
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) rethrow;
    }
    return null;
  }

  /// An acknowledgement more than one revision ahead of the phone (a refill
  /// rebased onto the server's newer revision, or a frozen one replayed after
  /// it) is not adopted by [_adoptPillRevision], because the steps between
  /// are another device's. A server that writes a stable change for the stock
  /// move delivers them on the next pull, but an older one writes none, so the
  /// phone would keep a stale base, and its next pill edit would be refused
  /// and lost to a server-wins conflict. The server's own row is read instead
  /// and taken exactly as a pull takes it (the same mapper), revision and
  /// content together, so nothing from the other device is hidden. Only a pill
  /// holding no unsent work is touched; best effort, the next pull follows.
  Future<void> _refreshAfterRevisionGap(
    PendingOperation operation,
    String localPillId,
    Object? data,
  ) async {
    try {
      final raw = data is Map<String, dynamic> ? data['revision'] : null;
      final acknowledged = raw is String ? int.tryParse(raw) : null;
      final before = await db.pillsDao.getById(localPillId);
      if (acknowledged == null ||
          before == null ||
          before.revision >= acknowledged) {
        return;
      }
      final server = await _readServerPill(localPillId);
      final revision = server?['revision'] is String
          ? int.tryParse(server!['revision'] as String)
          : null;
      if (server == null ||
          revision == null ||
          revision < acknowledged ||
          server['name'] is! String ||
          server['isPrn'] is! bool ||
          server['deletedAt'] != null) {
        return;
      }
      await _write(operation, () async {
        final pill = await db.pillsDao.getById(localPillId);
        if (pill == null ||
            pill.revision >= revision ||
            pill.syncStatus != 'synced') {
          return;
        }
        final journal = await PillJournal.read(db, operation.userId);
        if (journal.holdsUnsentWork(pill.id)) return;
        final updatedAt = server['updatedAt'] is String
            ? DateTime.tryParse(server['updatedAt'] as String)
            : null;
        await (db.update(db.pills)..where(
              (row) =>
                  row.id.equals(pill.id) & row.revision.equals(pill.revision),
            ))
            .write(
              wirePillCompanion(
                server,
                medicationDetailsExtra: false,
                keepStockOf: journal.keepsLocalStock(pill.id) ? pill : null,
                // An unsent dose may have set the mark before the server
                // heard of it: the server's "no mark" does not clear it yet.
                keepRecountMarkOf: journal.holdsRecountMark(pill.id)
                    ? pill
                    : null,
              ).copyWith(
                revision: Value(revision),
                updatedAt: Value(updatedAt ?? pill.updatedAt),
                syncStatus: const Value('synced'),
              ),
            );
        await mergeWirePillDetails(db, server, pill.id);
      });
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object {
      // The next pull or acknowledgement gets another chance.
    }
  }

  /// While a stock or dose command was unsent, a merge kept this phone's
  /// "needs a recount" mark even if another device's count had cleared it on
  /// the server, and the pull moved on. Once the last such command of the pill
  /// has settled, the server's value is read and a cleared mark is taken. The
  /// phone never clears the mark on its own: only the server's word does, and
  /// a mark the server still holds stays. Best effort; an unreadable answer
  /// leaves the mark for the next settled command.
  Future<void> _takeSettledRecountMark(
    PendingOperation operation,
    String localPillId,
  ) async {
    try {
      final pill = await db.pillsDao.getById(localPillId);
      if (pill == null || !pill.stockNeedsRecount) return;
      if (await recountMarkHeld(db, operation.userId, localPillId)) return;
      final server = await _readServerPill(localPillId);
      if (server == null || server['stockNeedsRecount'] != false) return;
      await _write(operation, () async {
        if (await recountMarkHeld(db, operation.userId, localPillId)) return;
        await (db.update(db.pills)..where(
              (row) =>
                  row.id.equals(localPillId) &
                  row.stockNeedsRecount.equals(true),
            ))
            .write(const PillsCompanion(stockNeedsRecount: Value(false)));
      });
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object {
      // A mark that stays one sync longer is the safe side.
    }
  }

  /// A stock move bumps `pills.revision` without a stable sync change, so the
  /// acknowledgement is the only place the phone learns the new base for its
  /// next pill PATCH or inventory command. Without it that write is rejected
  /// with CONFLICT_REVISION and reads as someone else's edit.
  ///
  /// A row is never rewritten except for this column, and only when the
  /// acknowledged revision is exactly one past the local base: that step is
  /// this command's own bump, so nothing from another device is hidden. A
  /// further-ahead ack is left for the next pull, which delivers the content.
  Future<void> _adoptPillRevision(
    Object? localPillId,
    Object? data,
    String field,
  ) async {
    if (localPillId is! String) return;
    final raw = data is Map<String, dynamic>
        ? (data.containsKey(field)
              ? data[field]
              : (data['data'] is Map<String, dynamic>
                    ? (data['data'] as Map<String, dynamic>)[field]
                    : null))
        : null;
    final revision = raw is String ? int.tryParse(raw) : null;
    if (revision == null) return;
    final pill = await db.pillsDao.getById(localPillId);
    if (pill == null || pill.revision >= revision) return;
    if (revision != pill.revision + 1) return;
    await (db.update(db.pills)..where(
          (row) => row.id.equals(pill.id) & row.revision.equals(pill.revision),
        ))
        .write(PillsCompanion(revision: Value(revision)));
  }

  /// Settles a failed HTTP exchange. Timeouts, 5xx, 408 and 429 leave the
  /// outcome unknown, and the frozen request replays under the same command
  /// id, so they retry with backoff until the attempt cap blocks them.
  Future<MedicationMutationResult> _failed(
    PendingOperation operation,
    DioException error,
    String rejectedCode,
  ) async {
    final status = error.response?.statusCode;
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
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
        operation,
        () => db.pendingOperationsDao.transitionState(
          operationId: operation.id,
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
      await _write(
        operation,
        () => db.pendingOperationsDao.settleTransientFailure(
          operation: operation,
          safeErrorCode: code ?? rejectedCode,
          safeCorrelationId: correlation,
          retryAfter: SyncRetryPolicy.retryAfter(error),
        ),
      );
      final settled = await db.pendingOperationsDao.getById(operation.id);
      final exhausted = settled?.state == 'blocked';
      return MedicationMutationResult(
        exhausted
            ? MedicationMutationStatus.blocked
            : MedicationMutationStatus.retryable,
        safeErrorCode: exhausted ? SyncRetryPolicy.retryExhaustedCode : code,
        safeCorrelationId: correlation,
      );
    }
    if (isAutoMissOperation(operation) &&
        _isDefinitiveMissRefusal(status, code)) {
      // Nobody chose this miss: when the server definitively refuses it
      // (someone already recorded the dose, or it is not a miss it accepts) it
      // is dropped, the dose goes back to the server's record and nothing is
      // raised for review. Any other failure (401, 403, 404, ...) is not a
      // verdict on the miss and takes the ordinary error path below.
      final dropped = await _write(
        operation,
        () => discardAutoMissOperation(
          db,
          operation,
          from: 'sending',
          safeErrorCode: autoMissNotAppliedCode,
          resetPullCheckpoints: true,
        ),
      );
      if (dropped) {
        return MedicationMutationResult(
          MedicationMutationStatus.discarded,
          safeErrorCode: autoMissNotAppliedCode,
          safeCorrelationId: correlation,
        );
      }
    }
    await _write(
      operation,
      () => db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'sending',
        to: status == 409 ? 'conflict' : 'blocked',
        safeErrorCode: code ?? rejectedCode,
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
  }

  /// Only a stale-version conflict, a validation refusal or the miss-specific
  /// code say the miss itself cannot stand. Authentication, permission and
  /// transport statuses say nothing about it and must not erase it.
  static bool _isDefinitiveMissRefusal(int? status, String? code) =>
      status == 409 || status == 422 || code == 'MISS_NOT_ALLOWED';

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
}
