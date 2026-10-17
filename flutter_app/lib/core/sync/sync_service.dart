import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../db/database.dart';
import '../medication/auto_miss_discard.dart';
import '../medication/medication_detail_backfill.dart';
import '../../features/updates/data/update_hint.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';
import 'sync_retry_policy.dart';
import 'sync_write_scope.dart';
import '../utils/app_logger.dart';
import 'adapters/account_sync_adapter.dart';
import 'adapters/bridge_medication_sync_adapter.dart';
import 'adapters/bridge_prn_sync_adapter.dart';
import 'adapters/legacy_medication_sync_adapter.dart';
import 'adapters/legacy_stable_adapter.dart';
import 'adapters/medication_sync_adapter.dart';
import 'adapters/pills_sync_adapter.dart';
import 'adapters/profiles_sync_adapter.dart';
import 'adapters/schedules_sync_adapter.dart';
import 'adapters/stable_record_adapter.dart';
import 'adapters/v2_medication_sync_adapter.dart';
import 'adapters/v2_stable_adapter.dart';
import 'capabilities_client.dart';
import 'held_stock.dart';
import 'ledger_mode_hint.dart';
import 'component_sync_merger.dart';
import 'component_sync_pull_adapter.dart';
import 'legacy_split_checkpoint.dart';
import 'legacy_sync_compat.dart';
import 'sync_coordinator.dart';
import 'sync_error_classifier.dart';
import 'sync_lock.dart';
import 'sync_models.dart';

// ── SyncService ───────────────────────────────────────────────────────────────

/// Replays locally-pending changes to the server whenever the app comes
/// to the foreground and the device is online.
///
/// Conflict resolution: profiles/pills/schedules — server wins on 409 (the
/// local record is treated as synced at its current value). Dose logs —
/// local wins: a 409 carries the existing row's id and we PATCH our status
/// onto it, so the user's most recent explicit action propagates.
///
/// Flush order: profiles → pills → schedules → dose_logs (parent-before-child).
/// A child record is skipped if its parent still has no serverId (parent sync
/// failed earlier in this run), and left pending for the next sync run.
class SyncService {
  SyncService({
    required AppDatabase db,
    required Dio dio,
    Future<bool> Function()? isOnline,
    SyncWriteScope? writeScope,
  }) : _db = db,
       _dio = dio,
       _isOnline = isOnline ?? _defaultIsOnline,
       _writeScope = writeScope;

  final AppDatabase _db;
  final Dio _dio;
  final Future<bool> Function() _isOnline;
  final SyncLock _lock = SyncLock();
  final SyncWriteScope? _writeScope;
  SyncWriteScope? get writeScope => _writeScope;
  Future<T> _write<T>(Future<T> Function() action) =>
      _writeScope?.write(action) ?? _db.transaction(action);

  late final LegacySyncCompat _legacy = LegacySyncCompat(
    db: _db,
    dio: _dio,
    writeScope: _writeScope,
    recordLastSync: _recordLastSync,
  );

  Future<void> _recordLastSync(
    String userId,
    SharedPreferences preferences,
  ) async {
    if (_writeScope == null) {
      await preferences.setString(
        'last_sync_at',
        DateTime.now().toIso8601String(),
      );
      return;
    }
    await _write(() async {
      final previous = await _db.syncStateDao.getState(userId, 'medication');
      await _db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: userId,
          component: 'medication',
          contractVersion: previous?.contractVersion ?? 1,
          lastCompletedCursor: Value(previous?.lastCompletedCursor),
          lastFullSuccessAt: Value(DateTime.now().toUtc()),
          currentState: Value(previous?.currentState ?? 'idle'),
          diagnosticMetadataJson: Value(previous?.diagnosticMetadataJson),
        ),
      );
    });
  }

  /// A push or partially completed component pull cannot establish freshness.
  /// Store this fact only after the full protected care traversal succeeds.
  Future<void> _recordCompletedCarePull(String userId) async {
    final scope = _writeScope;
    if (scope == null) return;
    scope.requireOwner(userId);
    final workspaceId = await scope.workspaceId;
    await _write(() async {
      final completedAt = DateTime.now().toUtc();
      final people = await _db.profilesDao.getByUserId(userId);
      if (people.isNotEmpty) {
        // A fresh sign-in creates the workspace before its first pull, so the
        // people arrive with nobody selected and the medication list stays
        // empty. Same rule as creating a person; never overrides a choice.
        await (_db.update(_db.careWorkspaces)..where(
              (row) =>
                  row.id.equals(workspaceId) &
                  row.selectedProfileId.isNull() &
                  row.viewEveryone.equals(false),
            ))
            .write(
              CareWorkspacesCompanion(
                selectedProfileId: Value(people.first.id),
              ),
            );
      }
      for (final person in people) {
        await _db
            .into(_db.workspaceSyncCheckpoints)
            .insertOnConflictUpdate(
              WorkspaceSyncCheckpointsCompanion.insert(
                workspaceId: workspaceId,
                profileId: person.id,
                channel: 'carePull',
                cursor: '',
                completedAt: completedAt,
              ),
            );
      }
    });
  }

  Future<void> _requireOwner(String ownerId) async {
    _writeScope?.requireOwner(ownerId);
    await _writeScope?.check();
  }

  static Future<bool> _defaultIsOnline() async {
    final results = await Connectivity().checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  bool _isSyncing = false;
  SyncRunResult? _lastFlushOutcome;
  SyncRunResult? _lastPullOutcome;
  CapabilitySnapshot? _capabilitiesForPull;
  String? _flushedUserId;

  /// Whether the device currently has a network path.
  Future<bool> isOnline() => _isOnline();

  /// A flush or pull of this service is running right now.
  bool get isSyncing => _isSyncing;

  SyncRunResult? get lastFlushOutcome => _lastFlushOutcome;
  SyncRunResult? get lastPullOutcome => _lastPullOutcome;

  /// Flushes all locally-pending changes to the server (profiles → pills →
  /// schedules → dose_logs). Returns without pulling server data.
  ///
  /// Throws [SyncBusyException] while another isolate holds the sync lock.
  ///
  /// Must be called before [pullFromServer] to ensure offline-created rows
  /// have their server IDs assigned before the pull runs. Without this
  /// ordering, the pull's duplicate-prevention check (getByServerId) returns
  /// null for pending rows and inserts a second row for the same entity.
  Future<void> flushPending({String? userId}) async {
    _capabilitiesForPull = null;
    _flushedUserId = null;
    _lastFlushOutcome = null;
    final effectiveUserId = userId ?? await _singleLocalUserId();
    if (effectiveUserId != null) await _requireOwner(effectiveUserId);
    if (effectiveUserId == null) {
      _lastFlushOutcome = const SyncRunResult([
        SyncStageResult(
          stageId: 'flush',
          outcome: SyncComponentOutcome.failed(
            safeErrorCode: 'SYNC_USER_UNKNOWN',
          ),
        ),
      ]);
      return;
    }
    if (!await _isOnline()) {
      _lastFlushOutcome = const SyncRunResult([
        SyncStageResult(
          stageId: 'flush',
          outcome: SyncComponentOutcome.failed(safeErrorCode: 'SYNC_OFFLINE'),
        ),
      ]);
      return;
    }

    if (_isSyncing) return;
    _isSyncing = true;
    if (!await _lock.tryAcquire()) {
      _isSyncing = false;
      throw const SyncBusyException();
    }

    try {
      final capabilities = await CapabilitiesClient(_dio).refresh();
      await LedgerModeHint.record(capabilities);
      await UpdateHint.recordFromServer(capabilities);
      _capabilitiesForPull = capabilities;
      _flushedUserId = effectiveUserId;
      final coordinator = SyncCoordinator(_db, writeScope: _writeScope);
      _lastFlushOutcome = await coordinator.run(
        userId: effectiveUserId,
        stages: [
          SyncStage(
            id: 'stable',
            component: SyncComponent.stable,
            contractVersion: 2,
            run: () => _flushStableOperations(effectiveUserId, capabilities),
          ),
          SyncStage(
            id: 'medication',
            component: SyncComponent.medication,
            contractVersion: 2,
            run: () =>
                _flushMedicationOperations(effectiveUserId, capabilities),
          ),
        ],
      );
    } finally {
      _lock.release();
      _isSyncing = false;
    }
  }

  Future<String?> _singleLocalUserId() async {
    final users = await _db.usersDao.getAll();
    return users.length == 1 ? users.single.id : null;
  }

  /// Actionable journal work, counted once. Entity sync flags are projections
  /// of these operations; blocked/conflicting evidence requires review rather
  /// than another transport attempt.
  Future<int> countPending({String? userId}) async {
    final owner =
        userId ??
        _writeScope?.capability?.ownerId ??
        await _singleLocalUserId();
    if (_writeScope != null) {
      if (owner == null) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleGrant,
        );
      }
      await _requireOwner(owner);
    }
    if (owner == null) return 0;
    return _write(() async {
      final operations = await _db.pendingOperationsDao.getUnsettledForUser(
        owner,
      );
      return operations
          .where(
            (op) => const {
              'queued',
              'sending',
              'failedRetryable',
            }.contains(op.state),
          )
          .length;
    });
  }

  /// A person asked to sync: retrying changes skip their backoff once. The
  /// attempt count is untouched, so the retry cap still applies.
  Future<void> makeRetriesEligibleNow({required String userId}) async {
    await _requireOwner(userId);
    await _write(() => _db.pendingOperationsDao.makeRetriesEligibleNow(userId));
  }

  /// Every unsent change, tallied (see [SyncOperationCounts]).
  Future<SyncOperationCounts> countOperations({String? userId}) async {
    final owner =
        userId ??
        _writeScope?.capability?.ownerId ??
        await _singleLocalUserId();
    if (_writeScope != null) {
      if (owner == null) {
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleGrant,
        );
      }
      await _requireOwner(owner);
    }
    if (owner == null) return SyncOperationCounts.none;
    final ledgerActive = await LedgerModeHint.read();
    return _write(() async {
      final operations = await _db.pendingOperationsDao.getUnsettledForUser(
        owner,
      );
      return tallyOperations(operations, ledgerActive: ledgerActive);
    });
  }

  /// Earliest moment a retrying change may be sent again, or null when none
  /// is waiting on a backoff (stuck changes never set it).
  Future<DateTime?> earliestRetryAt({String? userId}) async {
    final owner =
        userId ??
        _writeScope?.capability?.ownerId ??
        await _singleLocalUserId();
    if (owner == null) return null;
    if (_writeScope != null) await _requireOwner(owner);
    return _write(() async {
      final operations = await _db.pendingOperationsDao.getUnsettledForUser(
        owner,
      );
      DateTime? earliest;
      for (final op in operations) {
        if (op.state != 'failedRetryable') continue;
        final at = SyncRetryPolicy.notBefore(op.lastAttemptAt, op.attemptCount);
        if (earliest == null || at.isBefore(earliest)) earliest = at;
      }
      return earliest;
    });
  }

  /// Pure tally used by [countOperations]; stranded means a not-yet-failed
  /// change whose dependency chain reaches a blocked or conflicting change.
  ///
  /// While the server reports an inactive ledger ([ledgerActive] is false),
  /// stock changes that only wait for it are tallied as `awaitingLedger`
  /// instead of queued work; see [deferredStockOperationIds].
  static SyncOperationCounts tallyOperations(
    List<PendingOperation> operations, {
    bool? ledgerActive,
  }) => _tally(operations, ledgerActive: ledgerActive).counts;

  /// Stock changes held back by design: in bridge mode inventory commands wait
  /// for an active ledger, so they stay in the outbox untouched. Empty unless
  /// the server is known to have an inactive ledger. A change stranded behind
  /// a stuck one still needs a person and is not listed.
  static Set<String> deferredStockOperationIds(
    List<PendingOperation> operations, {
    required bool? ledgerActive,
  }) => _tally(operations, ledgerActive: ledgerActive).deferred;

  static ({SyncOperationCounts counts, Set<String> deferred}) _tally(
    List<PendingOperation> operations, {
    required bool? ledgerActive,
  }) {
    final byId = {for (final op in operations) op.id: op};
    bool stuck(PendingOperation op) =>
        op.state == 'blocked' || op.state == 'conflict';
    bool strandedBehindStuck(PendingOperation op) {
      final seen = <String>{op.id};
      var next = op.dependsOnOperationId;
      while (next != null && seen.add(next)) {
        final dependency = byId[next];
        if (dependency == null) return false;
        if (stuck(dependency)) return true;
        next = dependency.dependsOnOperationId;
      }
      return false;
    }

    // Medication operations never depend on the stable create that maps their
    // pill or schedule, so a stuck create is found by the local pill id.
    Map<Object?, Object?>? decode(PendingOperation op) {
      try {
        final payload = jsonDecode(op.payloadJson);
        return payload is Map ? payload : null;
      } on FormatException {
        return null;
      }
    }

    final stuckCreatePillIds = <String>{};
    for (final op in operations) {
      if (!stuck(op) ||
          op.component != 'stable' ||
          !op.operationType.endsWith('.create')) {
        continue;
      }
      final payload = decode(op);
      final pillId = switch (payload?['entityType']) {
        'pill' => payload?['entityLocalId'],
        'schedule' => payload?['parentEntityLocalId'],
        _ => null,
      };
      if (pillId is String) stuckCreatePillIds.add(pillId);
    }
    bool strandedBehindStuckCreate(PendingOperation op) {
      if (op.component != 'medication' || stuckCreatePillIds.isEmpty) {
        return false;
      }
      final projection = decode(op)?['localProjection'];
      final pillId = projection is Map ? projection['pillId'] : null;
      return pillId is String && stuckCreatePillIds.contains(pillId);
    }

    // A stock effect held behind its pill's opening (the mark the sync pass
    // persists) is stranded only when that opening is stuck for review with
    // an uncertain outcome; the ordinary short wait is plain queued work.
    final stuckStartPillIds = <String>{
      for (final op in operations)
        if (blockedMayHaveApplied(op)) ?startPillId(op),
    };
    bool strandedBehindStart(PendingOperation op) {
      if (op.safeErrorCode == inventoryStartReviewWaitCode) return true;
      if (op.safeErrorCode != inventoryStartPendingCode ||
          stuckStartPillIds.isEmpty) {
        return false;
      }
      final payload = decode(op);
      final command = payload?['inventoryCommand'];
      final projection = payload?['localProjection'];
      final pillId = command is Map
          ? command['pillId']
          : projection is Map
          ? projection['pillId']
          : null;
      return pillId is String && stuckStartPillIds.contains(pillId);
    }

    bool waitsForLedger(PendingOperation op) =>
        ledgerActive == false &&
        op.component == 'medication' &&
        decode(op)?['inventoryCommand'] is Map;

    final deferred = <String>{};
    var queued = 0, retrying = 0, blocked = 0, conflict = 0, stranded = 0;
    for (final op in operations) {
      switch (op.state) {
        case 'blocked':
          blocked++;
        case 'conflict':
          conflict++;
        case 'queued' || 'sending' || 'failedRetryable':
          if (strandedBehindStuck(op) ||
              strandedBehindStuckCreate(op) ||
              strandedBehindStart(op)) {
            stranded++;
          } else if (waitsForLedger(op)) {
            deferred.add(op.id);
          } else if (op.state == 'failedRetryable') {
            retrying++;
          } else {
            queued++;
          }
      }
    }
    return (
      counts: SyncOperationCounts(
        queued: queued,
        retrying: retrying,
        blocked: blocked,
        conflict: conflict,
        stranded: stranded,
        awaitingLedger: deferred.length,
      ),
      deferred: deferred,
    );
  }

  Future<SyncComponentOutcome> _flushStableOperations(
    String userId,
    CapabilitySnapshot capabilities,
  ) async {
    if (capabilities.protocol == SyncProtocol.blocked) {
      return SyncComponentOutcome.blocked(
        safeErrorCode: capabilities.blockedStableCode,
      );
    }
    final medicationDetails =
        capabilities.availability == CapabilityAvailability.present &&
        capabilities.capabilities!.medicationDetails;
    // Before the flush, so reviews the account never received go up ahead of
    // the pull that would otherwise answer with its own empty details.
    await MedicationDetailBackfill(
      db: _db,
      writeScope: _writeScope,
    ).run(userId: userId, medicationDetails: medicationDetails);
    final mutationAdapter = StableRecordAdapter.forCapabilities(
      capabilities,
      legacy: LegacyStableAdapter(db: _db, dio: _dio, writeScope: _writeScope),
      versioned: V2StableAdapter(
        db: _db,
        dio: _dio,
        writeScope: _writeScope,
        medicationDetails: medicationDetails,
      ),
    );
    if (mutationAdapter == null) {
      return const SyncComponentOutcome.blocked(
        safeErrorCode: 'STABLE_MUTATION_AUTHORITY_UNAVAILABLE',
      );
    }

    // Bridge mode holds stock commands back; stable edits must not wait on them.
    final ledgerActive =
        capabilities.availability == CapabilityAvailability.present
        ? capabilities.capabilities!.medicationLedgerActive
        : null;
    final outcomes = [
      await AccountSyncAdapter(_db).flush(userId, mutationAdapter),
      await ProfilesSyncAdapter(
        _db,
      ).flush(userId, mutationAdapter, ledgerActive: ledgerActive),
      await PillsSyncAdapter(
        _db,
      ).flush(userId, mutationAdapter, ledgerActive: ledgerActive),
      await SchedulesSyncAdapter(
        _db,
      ).flush(userId, mutationAdapter, ledgerActive: ledgerActive),
    ];
    final deferred = outcomes.where((outcome) => !outcome.allowsDependents);
    final firstDeferred = deferred.isEmpty ? null : deferred.first;
    if (capabilities.protocol == SyncProtocol.legacyCompatibility) {
      await _legacy.flushStable(userId: userId);
    }
    return firstDeferred == null
        ? const SyncComponentOutcome.succeeded()
        : SyncComponentOutcome.partiallySynced(
            safeErrorCode: firstDeferred.safeErrorCode,
            safeCorrelationId: firstDeferred.safeCorrelationId,
          );
  }

  Future<SyncComponentOutcome> _flushMedicationOperations(
    String userId,
    CapabilitySnapshot capabilities,
  ) async {
    await _dropUnsendableAutoMisses(userId, capabilities);
    final allOperations = (await _db.pendingOperationsDao.getUnsettledForUser(
      userId,
    )).where((operation) => operation.component == 'medication').toList();
    if (allOperations.isEmpty) {
      if (capabilities.protocol == SyncProtocol.legacyCompatibility) {
        await _legacy.flushDoseLogs(userId: userId);
      }
      return const SyncComponentOutcome.succeeded();
    }

    final bridgeAdapter = BridgeMedicationSyncAdapter(
      db: _db,
      dio: _dio,
      writeScope: _writeScope,
      bridgeUndo: capabilities.capabilities?.bridgeUndo == true,
    );
    if (capabilities.availability == CapabilityAvailability.present &&
        !capabilities.capabilities!.medicationLedgerActive) {
      for (final operation in allOperations) {
        await bridgeAdapter.captureUnfrozenAttemptForReview(operation);
      }
    }
    final retained = <PendingOperation>[];
    for (final operation in allOperations) {
      final checkpoint = await LegacySplitCheckpoint.load(_db, operation.id);
      if (checkpoint?.hasRetainedProgress == true) retained.add(operation);
    }
    final readySplit = await _db.pendingOperationsDao.getReadySplit(
      userId,
      honorBackoff: true,
    );
    final ready = readySplit.ready
        .where((operation) => operation.component == 'medication')
        .toList();
    final backingOff = readySplit.waiting
        .where((operation) => operation.component == 'medication')
        .length;
    if (retained.isEmpty && ready.isEmpty) {
      // Operations waiting out a retry backoff are not synced yet.
      return backingOff == 0
          ? const SyncComponentOutcome.succeeded()
          : const SyncComponentOutcome.partiallySynced(
              safeErrorCode: 'SYNC_RETRY_SCHEDULED',
            );
    }

    final steps = selectMedicationSyncSteps(
      capabilities,
      hasRetainedSplitCheckpoints: retained.isNotEmpty,
    );
    if (steps.isEmpty) {
      AppLogger.debug(
        'SyncService',
        'Medication operations held because server capabilities are unavailable',
      );
      return SyncComponentOutcome.blocked(
        safeErrorCode:
            capabilities.availability ==
                CapabilityAvailability.localAccessUnavailable
            ? 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE'
            : 'MEDICATION_AUTHORITY_UNAVAILABLE',
      );
    }

    final splitAdapter = LegacyMedicationSyncAdapter(
      db: _db,
      dio: _dio,
      writeScope: _writeScope,
    );
    final reconciliationAdapter = PermanentMedicationReconciliationAdapter(
      db: _db,
      dio: _dio,
      writeScope: _writeScope,
    );

    final prnAdapter = _writeScope == null
        ? null
        : BridgePrnSyncAdapter(db: _db, dio: _dio, writeScope: _writeScope);
    final v2Adapter = V2MedicationSyncAdapter(
      db: _db,
      dio: _dio,
      writeScope: _writeScope,
    );

    var deferred = false;
    String? safeErrorCode;
    String? safeCorrelationId;
    for (final step in steps) {
      switch (step) {
        case MedicationSyncStep.legacySplit:
          for (final operation in ready) {
            final body = jsonDecode(operation.payloadJson);
            final command = body is Map ? body['command'] : null;
            final id = command is Map ? command['occurrenceId'] : null;
            final occurrence = id is String
                ? await _db.medicationLedgerDao.getOccurrenceById(id)
                : null;
            // Native PRN intent must never fall through to split legacy writes.
            final result = occurrence?.source == 'prn'
                ? const MedicationMutationResult(
                    MedicationMutationStatus.waitingForAuthority,
                    safeErrorCode: 'PRN_AUTHORITY_UNAVAILABLE',
                  )
                : await splitAdapter.flush(operation);
            _logMedicationOutcome(operation, result);
            await _persistUnsettledResult(operation, result);
            if (result.status != MedicationMutationStatus.acknowledged) {
              deferred = true;
              safeErrorCode = result.safeErrorCode;
              safeCorrelationId = result.safeCorrelationId;
            }
          }
        case MedicationSyncStep.permanentReconciliation:
          for (final operation in retained) {
            final result = await reconciliationAdapter.reconcile(operation);
            _logMedicationOutcome(operation, result);
            if (result.status != MedicationMutationStatus.acknowledged) {
              deferred = true;
              safeErrorCode = result.safeErrorCode;
              safeCorrelationId = result.safeCorrelationId;
            }
          }
        case MedicationSyncStep.inactiveBridge:
        case MedicationSyncStep.activeLedger:
          final active = step == MedicationSyncStep.activeLedger;
          final candidates = (await _db.pendingOperationsDao.getReady(
            userId,
            honorBackoff: true,
          )).where((operation) => operation.component == 'medication');
          for (final operation in candidates) {
            final checkpoint = await LegacySplitCheckpoint.load(
              _db,
              operation.id,
            );
            if (checkpoint?.hasRetainedProgress == true) continue;
            final operationPayload = jsonDecode(operation.payloadJson);
            final operationCommand = operationPayload is Map
                ? operationPayload['command']
                : null;
            final occurrenceId = operationCommand is Map
                ? operationCommand['occurrenceId']
                : null;
            final occurrence = occurrenceId is String
                ? await _db.medicationLedgerDao.getOccurrenceById(occurrenceId)
                : null;
            // The server never creates PRN occurrences, so on an active ledger
            // a native as-needed dose it has not seen yet goes through the
            // exact PRN command, which creates it. Once mapped, later commands
            // on it are ordinary ledger commands.
            final unmappedLedgerPrn =
                active &&
                occurrence != null &&
                occurrence.source == 'prn' &&
                occurrence.serverId == null &&
                occurrence.occurrenceKey == 'prn:v1:${occurrence.id}';
            final result = unmappedLedgerPrn
                ? capabilities.capabilities?.ledgerPrn == true &&
                          prnAdapter != null
                      ? await prnAdapter.send(operation, ledgerActive: true)
                      : const MedicationMutationResult(
                          MedicationMutationStatus.waitingForAuthority,
                          safeErrorCode: 'PRN_AUTHORITY_UNAVAILABLE',
                        )
                : active
                ? await v2Adapter.send(operation)
                : occurrence?.source == 'prn'
                ? capabilities.capabilities?.medicationBridgePrnCommands ==
                              true &&
                          prnAdapter != null
                      ? await prnAdapter.send(operation)
                      : const MedicationMutationResult(
                          MedicationMutationStatus.waitingForAuthority,
                          safeErrorCode: 'PRN_AUTHORITY_UNAVAILABLE',
                        )
                : await bridgeAdapter.send(operation);
            _logMedicationOutcome(operation, result);
            await _recordStartWait(operation, result);
            // The bridge adapter persists its own transitions.
            if (active || occurrence?.source == 'prn') {
              await _persistUnsettledResult(operation, result);
            }
            // Stock waiting for the server's ledger is by design, not a
            // partial sync: it stays in the outbox and goes out on activation.
            final waitsForLedger =
                !active &&
                result.status == MedicationMutationStatus.waitingForAuthority &&
                result.safeErrorCode ==
                    'INVENTORY_COMMAND_REQUIRES_ACTIVE_LEDGER';
            if (result.status != MedicationMutationStatus.acknowledged &&
                result.status != MedicationMutationStatus.discarded &&
                !waitsForLedger) {
              deferred = true;
              safeErrorCode = result.safeErrorCode;
              safeCorrelationId = result.safeCorrelationId;
            }
          }
      }
    }
    if (capabilities.protocol == SyncProtocol.legacyCompatibility) {
      await _legacy.flushDoseLogs(userId: userId);
    }
    return deferred
        ? SyncComponentOutcome.partiallySynced(
            safeErrorCode: safeErrorCode,
            safeCorrelationId: safeCorrelationId,
          )
        : const SyncComponentOutcome.succeeded();
  }

  /// A miss only exists in the active ledger of a server that records it.
  /// Anywhere else (bridge or legacy delivery, a server that does not know the
  /// action) the app's own automatic misses are dropped before they can reach
  /// an adapter that would turn them into a review item. The dose stays as the
  /// server has it, and the next pull restores it.
  Future<void> _dropUnsendableAutoMisses(
    String userId,
    CapabilitySnapshot capabilities,
  ) async {
    switch (capabilities.availability) {
      case CapabilityAvailability.unavailable:
      case CapabilityAvailability.localAccessUnavailable:
        return;
      case CapabilityAvailability.absent:
      case CapabilityAvailability.present:
        final recorded =
            capabilities.availability == CapabilityAvailability.present &&
            capabilities.capabilities!.medicationLedgerActive &&
            capabilities.capabilities!.recordedMiss;
        if (recorded) return;
    }
    var dropped = false;
    for (final operation in await _db.pendingOperationsDao.getUnsettledForUser(
      userId,
    )) {
      if (!isAutoMissOperation(operation) ||
          (operation.state != 'queued' &&
              operation.state != 'failedRetryable')) {
        continue;
      }
      dropped =
          await _write(
            () => discardAutoMissOperation(
              _db,
              operation,
              from: operation.state,
              safeErrorCode: autoMissNotAppliedCode,
            ),
          ) ||
          dropped;
    }
    if (dropped) await _db.syncStateDao.resetPullCheckpoints(userId);
  }

  /// A stock effect held behind its pill's opening says so in the outbox, so
  /// Fix sync problems can name the wait; the mark is cleared once the
  /// effect is released.
  Future<void> _recordStartWait(
    PendingOperation operation,
    MedicationMutationResult result,
  ) async {
    final waiting =
        result.status == MedicationMutationStatus.waitingForMapping &&
        inventoryWaitCodes.contains(result.safeErrorCode);
    if (waiting) {
      await _write(
        () => _db.pendingOperationsDao.setWaitReason(
          operation.id,
          result.safeErrorCode,
        ),
      );
    } else if (inventoryWaitCodes.contains(operation.safeErrorCode)) {
      await _write(
        () => _db.pendingOperationsDao.setWaitReason(operation.id, null),
      );
    }
  }

  /// An adapter result that is not "sent" must leave a durable trace: a
  /// refusal that kept the row `queued` would be retried and ignored forever.
  /// Waiting for a mapping or for server authority is a real, countable wait
  /// and stays queued; a refusal becomes `blocked` (or `conflict`).
  Future<void> _persistUnsettledResult(
    PendingOperation operation,
    MedicationMutationResult result,
  ) async {
    final to = switch (result.status) {
      MedicationMutationStatus.blocked ||
      MedicationMutationStatus.uncertain => 'blocked',
      MedicationMutationStatus.conflict => 'conflict',
      _ => null,
    };
    if (to == null) return;
    final current = await _db.pendingOperationsDao.getById(operation.id);
    if (current == null ||
        (current.state != 'queued' && current.state != 'failedRetryable')) {
      return;
    }
    await _write(
      () => _db.pendingOperationsDao.transitionState(
        operationId: current.id,
        from: current.state,
        to: to,
        safeErrorCode: result.safeErrorCode ?? 'MEDICATION_REFUSED',
        safeCorrelationId: result.safeCorrelationId,
      ),
    );
  }

  void _logMedicationOutcome(
    PendingOperation operation,
    MedicationMutationResult result,
  ) {
    switch (result.status) {
      case MedicationMutationStatus.acknowledged:
        return;
      case MedicationMutationStatus.discarded:
        AppLogger.debug(
          'SyncService',
          'Automatic miss ${operation.id} dropped: ${result.safeErrorCode ?? result.status.name}',
        );
      case MedicationMutationStatus.waitingForMapping:
      case MedicationMutationStatus.waitingForAuthority:
      case MedicationMutationStatus.retryable:
        AppLogger.debug(
          'SyncService',
          'Medication operation ${operation.id} deferred: ${result.safeErrorCode ?? result.status.name}',
        );
      case MedicationMutationStatus.conflict:
      case MedicationMutationStatus.uncertain:
      case MedicationMutationStatus.blocked:
        AppLogger.warning(
          'SyncService',
          'Medication operation ${operation.id} requires review: ${result.safeErrorCode ?? result.status.name}',
        );
    }
  }

  /// Deletes tombstone rows (isDeleted=true, syncStatus='synced') older than
  /// [maxAge] across all entity types.
  Future<void> purgeSyncedTombstones({
    Duration maxAge = const Duration(days: 90),
  }) async {
    final before = DateTime.now().subtract(maxAge);
    final scope = _writeScope;
    if (scope == null) {
      await _db.doseLogsDao.purgeSyncedTombstones(before);
      await _db.schedulesDao.purgeSyncedTombstones(before);
      await _db.pillsDao.purgeSyncedTombstones(before);
      await _db.profilesDao.purgeSyncedTombstones(before);
      return;
    }
    await scope.check();
    final owner = scope.capability!.ownerId;
    await _write(() async {
      final parameters = [Variable<DateTime>(before), Variable<String>(owner)];
      const tombstone =
          'is_deleted=1 AND sync_status=\'synced\' AND updated_at<=?';
      await _db.customUpdate(
        'DELETE FROM dose_logs WHERE $tombstone AND schedule_id IN (SELECT s.id FROM schedules s JOIN pills p ON p.id=s.pill_id JOIN profiles r ON r.id=p.profile_id WHERE r.user_id=?)',
        variables: parameters,
        updates: {_db.doseLogs},
      );
      await _db.customUpdate(
        'DELETE FROM schedules WHERE $tombstone AND pill_id IN (SELECT p.id FROM pills p JOIN profiles r ON r.id=p.profile_id WHERE r.user_id=?) AND NOT EXISTS (SELECT 1 FROM dose_logs d WHERE d.schedule_id=schedules.id) AND NOT EXISTS (SELECT 1 FROM medication_occurrences o WHERE o.schedule_id=schedules.id)',
        variables: parameters,
        updates: {_db.schedules},
      );
      await _db.customUpdate(
        'DELETE FROM pills WHERE $tombstone AND profile_id IN (SELECT id FROM profiles WHERE user_id=?) AND NOT EXISTS (SELECT 1 FROM schedules s WHERE s.pill_id=pills.id) AND NOT EXISTS (SELECT 1 FROM medication_occurrences o WHERE o.pill_id=pills.id)',
        variables: parameters,
        updates: {_db.pills},
      );
      await _db.customUpdate(
        'DELETE FROM profiles WHERE $tombstone AND user_id=? AND NOT EXISTS (SELECT 1 FROM pills p WHERE p.profile_id=profiles.id)',
        variables: parameters,
        updates: {_db.profiles},
      );
    });
  }

  // ── Pull from server ───────────────────────────────────────────────────────

  /// Pulls all server data for [userId] into the local Drift DB.
  ///
  /// Pull order: profiles → pills (per profile) → schedules (per pill) →
  /// dose_logs (per profile).
  ///
  /// **Duplicate-prevention:** Before upserting an entity, [getByServerId] is
  /// called. If a local record already tracks the same server UUID under a
  /// *different* local UUID (i.e. the entity was created offline and later
  /// flushed), the upsert is skipped and the existing local UUID is used as the
  /// parent key for child entities. This prevents the UI from showing the same
  /// profile or pill twice.
  ///
  /// Throws [DioException] with status 401 so the caller can handle
  /// session expiry, and [SyncBusyException] while another isolate holds the
  /// sync lock. All other per-resource errors are logged and skipped.
  ///
  /// Returns `true` if profiles were pulled successfully, `false` on total
  /// failure (e.g. network is unreachable before the first request completes).
  Future<bool> pullFromServer({required String userId}) async {
    await _requireOwner(userId);
    if (_isSyncing) return false;
    // Direct callers receive the same invariant as AutoSync: every pull is
    // preceded by a flush under the same freshly-read capability authority.
    if (_flushedUserId != userId) {
      await flushPending(userId: userId);
    }
    if (_isSyncing) return false;
    var capabilities = _capabilitiesForPull;
    _capabilitiesForPull = null;
    _flushedUserId = null;
    if (capabilities == null) {
      if (!await _isOnline()) return false;
      capabilities = await CapabilitiesClient(_dio).refresh();
      await LedgerModeHint.record(capabilities);
      await UpdateHint.recordFromServer(capabilities);
    }
    if (_isSyncing) return false;
    _isSyncing = true;
    if (!await _lock.tryAcquire()) {
      _isSyncing = false;
      throw const SyncBusyException();
    }

    try {
      return await _pullFromServerInner(
        userId: userId,
        capabilities: capabilities,
      );
    } finally {
      _lock.release();
      _isSyncing = false;
    }
  }

  Future<bool> _pullFromServerInner({
    required String userId,
    required CapabilitySnapshot capabilities,
  }) async {
    if (capabilities.protocol == SyncProtocol.legacyCompatibility) {
      final succeeded = await _legacy.pull(userId: userId);
      _lastPullOutcome = SyncRunResult([
        SyncStageResult(
          stageId: 'legacy',
          outcome: succeeded
              ? const SyncComponentOutcome.succeeded()
              : const SyncComponentOutcome.failed(
                  safeErrorCode: 'LEGACY_PULL_FAILED',
                ),
        ),
      ]);
      return succeeded;
    }
    if (capabilities.protocol == SyncProtocol.blocked) {
      _lastPullOutcome = SyncRunResult([
        SyncStageResult(
          stageId: 'pull',
          outcome: SyncComponentOutcome.failed(
            safeErrorCode: capabilities.blockedStableCode,
          ),
        ),
      ]);
      return false;
    }

    final pullAdapter = ComponentSyncPullAdapter(
      db: _db,
      dio: _dio,
      writeScope: _writeScope,
    );
    final merger = ComponentSyncMerger(_db, writeScope: _writeScope);
    final medicationComponent =
        capabilities.capabilities!.medicationLedgerActive
        ? SyncComponent.medication
        : SyncComponent.medicationBridge;
    final medicationContract = medicationComponent == SyncComponent.medication
        ? 2
        : capabilities.capabilities!.medicationBridgeContractVersion;
    final stages = [
      SyncStage(
        id: 'account',
        component: SyncComponent.account,
        contractVersion: 2,
        run: () async {
          await pullAdapter.pull(
            userId: userId,
            component: SyncComponent.account,
            contractVersion: 2,
            // Reproject already-acknowledged settlements from older clients.
            // Cursor and projection revision publish together after merge.
            projectionRevision: accountSettlementProjectionRevision,
            merge: (component, changes) =>
                merger.merge(userId, component, changes),
          );
          return const SyncComponentOutcome.succeeded();
        },
      ),
      SyncStage(
        id: 'stable',
        component: SyncComponent.stable,
        contractVersion: 2,
        run: () async {
          await pullAdapter.pull(
            userId: userId,
            component: SyncComponent.stable,
            contractVersion: 2,
            projectionRevision: 'schedule-zone-v1',
            merge: (component, changes) =>
                merger.merge(userId, component, changes),
          );
          return const SyncComponentOutcome.succeeded();
        },
      ),
      SyncStage(
        id: medicationComponent.name,
        component: medicationComponent,
        contractVersion: medicationContract,
        dependsOn: const ['stable'],
        run: () async {
          try {
            await pullAdapter.pull(
              userId: userId,
              component: medicationComponent,
              contractVersion: medicationContract,
              projectionRevision:
                  medicationComponent == SyncComponent.medicationBridge &&
                      medicationContract >= 4
                  ? 'recorded-occurrence-link-v1'
                  : null,
              merge: (component, changes) => merger.merge(
                userId,
                component,
                changes,
                contractVersion: medicationContract,
              ),
            );
          } on DioException catch (error) {
            if (medicationComponent != SyncComponent.medicationBridge ||
                error.response?.statusCode != 409 ||
                !_isContractTransition(error)) {
              rethrow;
            }
            final refreshed = await CapabilitiesClient(_dio).refresh();
            if (refreshed.availability != CapabilityAvailability.present ||
                !refreshed.capabilities!.medicationLedgerActive) {
              rethrow;
            }
            await pullAdapter.pull(
              userId: userId,
              component: SyncComponent.medication,
              contractVersion: 2,
              merge: (component, changes) =>
                  merger.merge(userId, component, changes),
            );
          }
          return const SyncComponentOutcome.succeeded();
        },
      ),
    ];
    _lastPullOutcome = await SyncCoordinator(
      _db,
      writeScope: _writeScope,
    ).run(userId: userId, stages: stages);
    if (_lastPullOutcome!.status == SyncRunStatus.succeeded) {
      try {
        await _recordCompletedCarePull(userId);
        final prefs = await SharedPreferences.getInstance();
        await _recordLastSync(userId, prefs);
      } on WorkspaceAccessFailure {
        rethrow;
      } on Object {
        // Component checkpoints remain authoritative if this display marker fails.
      }
    }
    return _lastPullOutcome!.status != SyncRunStatus.failed;
  }

  bool _isContractTransition(DioException error) {
    final body = error.response?.data;
    if (body is! Map<String, dynamic>) return false;
    final details = body['error'];
    return details is Map<String, dynamic> &&
        details['code'] == 'CONTRACT_NOT_ACTIVE';
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final syncServiceProvider = Provider<SyncService>((ref) {
  final client = ref.watch(apiClientProvider);
  return SyncService(
    db: ref.watch(databaseProvider),
    dio: client.dio,
    writeScope: SyncWriteScope(
      access: ref.watch(workspaceAccessRepositoryProvider),
      capability: client.networkCapability,
    ),
  );
});
