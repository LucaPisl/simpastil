import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../sync/legacy_split_identity.dart';
import '../../sync/schedule_repair_intent.dart';
import '../../sync/sync_retry_policy.dart';
import '../database.dart';
import '../tables/pending_operation_effects_table.dart';
import '../tables/pending_operations_table.dart';

part 'pending_operations_dao.g.dart';

@DriftAccessor(tables: [PendingOperations, PendingOperationEffects])
class PendingOperationsDao extends DatabaseAccessor<AppDatabase>
    with _$PendingOperationsDaoMixin {
  PendingOperationsDao(super.db);

  static const _ids = Uuid();

  Future<void> enqueue(
    PendingOperationsCompanion operation, {
    List<PendingOperationEffectsCompanion> effects = const [],
  }) async {
    await db.transaction(() async {
      await into(pendingOperations).insert(operation);
      if (effects.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(pendingOperationEffects, effects);
        });
      }
    });
  }

  Future<PendingOperation?> getByMutationId(String userId, String mutationId) =>
      (select(pendingOperations)..where(
            (row) =>
                row.userId.equals(userId) & row.mutationId.equals(mutationId),
          ))
          .getSingleOrNull();

  Future<PendingOperation?> getById(String id) => (select(
    pendingOperations,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<List<PendingOperation>> getForUser(String userId) =>
      (select(pendingOperations)
            ..where((row) => row.userId.equals(userId))
            ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
          .get();

  /// True only when a blocked operation is fully accounted for by either
  /// acknowledged/exactly settled effects or unresolved server-backed split
  /// review evidence. Local markers and partial evidence remain uncertain.
  Future<bool> awaitsServerReview(
    PendingOperation operation, {
    required String workspaceId,
  }) async {
    if (operation.state != 'blocked') return false;
    final workspace =
        await (db.select(db.careWorkspaces)..where(
              (row) =>
                  row.id.equals(workspaceId) &
                  row.ownerUserId.equals(operation.userId),
            ))
            .getSingleOrNull();
    if (workspace == null) return false;

    final effects = await getEffects(operation.id);
    if (effects.isEmpty) return false;
    final settlements =
        await (db.select(db.effectSettlements)..where(
              (row) =>
                  row.userId.equals(operation.userId) &
                  row.workspaceId.equals(workspaceId),
            ))
            .get();
    final settlementsByEffect = {
      for (final row in settlements) row.effectId: row,
    };
    Object? mutationId;
    try {
      final payload = jsonDecode(operation.payloadJson);
      if (payload is! Map) return false;
      mutationId = LegacySplitIdentity.sourceCommandId(
        payload,
        operation.mutationId,
      );
    } on FormatException {
      return false;
    }
    if (mutationId is! String || mutationId.isEmpty) return false;
    var hasUnresolvedServerReview = false;

    for (final effect in effects) {
      if (effect.state == 'acknowledged') continue;
      final settlement = settlementsByEffect[effect.id];
      if (settlement != null &&
          settlement.requestFingerprint == effect.requestFingerprint) {
        continue;
      }
      if (effect.state != 'uncertain' && effect.state != 'sending') {
        return false;
      }
      const prefix = LegacySplitIdentity.recordedMarkerPrefix;
      final marker = effect.safeResultFingerprint;
      if (marker == null || !marker.startsWith(prefix)) return false;
      final issueId = marker.substring(prefix.length);
      final identity = LegacySplitIdentity(mutationId, effect.ordinal);
      if (issueId.isEmpty ||
          issueId.length > 128 ||
          identity.issueId != issueId) {
        return false;
      }
      final issue = await (db.select(
        db.migrationIssues,
      )..where((row) => row.id.equals(issueId))).getSingleOrNull();
      if (issue == null ||
          issue.userId != operation.userId ||
          issue.serverId != issue.id ||
          issue.revision < 1 ||
          issue.resolutionState != 'unresolved' ||
          issue.entityType != 'medication_split' ||
          issue.issueCode != 'legacy_split_checkpoint' ||
          issue.entityId != identity.resolutionCommandId) {
        return false;
      }
      hasUnresolvedServerReview = true;
    }
    return hasUnresolvedServerReview;
  }

  Future<bool> isSettled(
    PendingOperation operation, {
    String? workspaceId,
  }) async {
    final effects = await getEffects(operation.id);
    if (effects.isEmpty) return false;
    final settlements =
        await (db.select(db.effectSettlements)..where(
              (s) =>
                  s.userId.equals(operation.userId) &
                  (workspaceId == null
                      ? const Constant(true)
                      : s.workspaceId.equals(workspaceId)),
            ))
            .get();
    final byEffect = {for (final s in settlements) s.effectId: s};
    return effects.any((e) => byEffect.containsKey(e.id)) &&
        effects.every(
          (e) =>
              e.state == 'acknowledged' ||
              byEffect[e.id]?.requestFingerprint == e.requestFingerprint,
        );
  }

  Future<List<PendingOperation>> getUnsettledForUser(
    String userId, {
    String? workspaceId,
  }) async {
    final result = <PendingOperation>[];
    for (final op in await getForUser(userId)) {
      if (op.state != 'committed' &&
          op.state != 'discarded' &&
          !await isSettled(op, workspaceId: workspaceId)) {
        result.add(op);
      }
    }
    return result;
  }

  /// An authoritative pull may replace an optimistic legacy projection only
  /// after every intent associated with that exact source has been settled.
  /// Unrelated or later edits continue to protect the local projection.
  Future<bool> isLegacySourceSettled(
    String userId,
    String sourceId, {
    required String kind,
  }) async {
    final linked =
        await (select(pendingOperationEffects)..where(
              (e) => e.legacySourceId.equals(sourceId) & e.kind.equals(kind),
            ))
            .get();
    if (linked.isEmpty) return false;
    final operationIds = linked.map((e) => e.operationId).toSet();
    for (final id in operationIds) {
      final operation = await getById(id);
      if (operation == null ||
          operation.userId != userId ||
          (operation.state != 'committed' && !await isSettled(operation))) {
        return false;
      }
    }
    return true;
  }

  Future<DateTime?> getLatestCreatedAt(String userId) async =>
      (await (select(pendingOperations)
                ..where((row) => row.userId.equals(userId))
                ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
                ..limit(1))
              .getSingleOrNull())
          ?.createdAt;

  /// While the server reports an inactive ledger (bridge mode), a stock
  /// command is held untouched in the outbox until the ledger is activated.
  /// A stable edit queued behind it must not wait for that: the edit does not
  /// need the stock event, and the stock command freezes its base revision at
  /// first send, after the edit has committed and adopted its revision. An
  /// edit that itself carries stock fields keeps its ordering.
  bool _isDeferredStockHold(PendingOperation child, PendingOperation parent) {
    if (child.component != 'stable' ||
        parent.component != 'medication' ||
        (parent.state != 'queued' && parent.state != 'failedRetryable') ||
        parent.attemptCount != 0) {
      return false;
    }
    try {
      final held = jsonDecode(parent.payloadJson);
      final payload = jsonDecode(child.payloadJson);
      if (held is! Map ||
          held['inventoryCommand'] is! Map ||
          held.containsKey('resolvedInventoryRequest') ||
          payload is! Map) {
        return false;
      }
      // A delete must not overtake the held stock command: released, it
      // would commit first and the stock command would then target a deleted
      // pill.
      if (payload['action'] == 'delete') return false;
      final data = payload['data'];
      return data is! Map ||
          !const {
            'currentStock',
            'initialStock',
            'targetStock',
            'resultingStock',
          }.any(data.containsKey);
    } on FormatException {
      return false;
    }
  }

  /// A settled inventory review closes that stock intent, not its original
  /// delivery. Independent metadata may continue; medical commands must still
  /// prove their causal event/version through the existing adapters.
  Future<bool> _settledInventoryAllowsStableChild(
    PendingOperation child,
    PendingOperation parent,
    String workspaceId,
  ) async {
    if (child.component != 'stable' || parent.component != 'medication') {
      return false;
    }
    final workspace =
        await (db.select(db.careWorkspaces)..where(
              (w) =>
                  w.id.equals(workspaceId) & w.ownerUserId.equals(child.userId),
            ))
            .getSingleOrNull();
    if (workspace == null) return false;
    try {
      final payload = jsonDecode(child.payloadJson);
      final original = jsonDecode(parent.payloadJson);
      if (payload is! Map || original is! Map) return false;
      final inventory = original['inventoryCommand'];
      final pillId = original['entityLocalId'];
      if (original['entityType'] != 'pill' ||
          pillId is! String ||
          inventory is! Map ||
          inventory['pillId'] != pillId ||
          payload.containsKey('command') ||
          payload.containsKey('inventoryCommand')) {
        return false;
      }
      final type = payload['entityType'];
      final action = payload['action'];
      if (child.operationType != '$type.$action' ||
          !const {
            'pill.update',
            'pill.delete',
            'schedule.create',
            'schedule.update',
            'schedule.delete',
            'schedule.repair',
          }.contains(child.operationType)) {
        return false;
      }
      final repair = action == 'repair'
          ? ScheduleRepairIntent.fromOperation(child)
          : null;
      if (action == 'repair' &&
          (repair == null || (await getEffects(child.id)).isNotEmpty)) {
        return false;
      }
      final data = repair?.request['schedule'] ?? payload['data'];
      if ((action != 'delete' && data is! Map) ||
          (data is Map &&
              const {
                'currentStock',
                'initialStock',
                'targetStock',
                'resultingStock',
              }.any(data.containsKey))) {
        return false;
      }
      final pill = await db.pillsDao.getById(pillId);
      final person = pill == null
          ? null
          : await db.profilesDao.getById(pill.profileId);
      if (pill?.serverId == null ||
          person?.serverId == null ||
          person?.userId != child.userId) {
        return false;
      }
      if (type == 'pill') {
        if (payload['entityLocalId'] != pillId ||
            payload['parentEntityType'] != 'profile' ||
            payload['parentEntityLocalId'] != person!.id) {
          return false;
        }
      } else {
        final scheduleId = payload['entityLocalId'];
        if (scheduleId is! String ||
            payload['parentEntityType'] != 'pill' ||
            payload['parentEntityLocalId'] != pillId) {
          return false;
        }
        final schedule = await db.schedulesDao.getById(scheduleId);
        if (schedule?.pillId != pillId ||
            (action != 'create' && schedule?.serverId == null) ||
            (repair != null &&
                (repair.scheduleId != schedule?.serverId ||
                    repair.pillId != pill!.serverId))) {
          return false;
        }
      }
      final effects = await getEffects(parent.id);
      if (effects.isEmpty ||
          effects.any(
            (e) => e.kind != 'inventory' || e.legacySourceId != pillId,
          )) {
        return false;
      }
      return isSettled(parent, workspaceId: workspaceId);
    } on FormatException {
      return false;
    }
  }

  /// Operations that may be sent now. With [honorBackoff], a
  /// `failedRetryable` operation waits until its backoff has elapsed (see
  /// [SyncRetryPolicy]); AUTH_REQUIRED retries are never delayed.
  Future<List<PendingOperation>> getReady(
    String userId, {
    String? workspaceId,
    bool honorBackoff = false,
    DateTime? now,
    bool? ledgerActive,
  }) async => (await getReadySplit(
    userId,
    workspaceId: workspaceId,
    ledgerActive: ledgerActive,
    honorBackoff: honorBackoff,
    now: now,
  )).ready;

  /// Like [getReady], also returning operations that are sendable but still
  /// inside their retry backoff, so callers can report "retrying".
  Future<({List<PendingOperation> ready, List<PendingOperation> waiting})>
  getReadySplit(
    String userId, {
    String? workspaceId,
    bool honorBackoff = false,
    DateTime? now,
    bool? ledgerActive,
  }) async {
    final clock = (now ?? DateTime.now()).toUtc();
    final waiting = <PendingOperation>[];
    final queued =
        await (select(pendingOperations)
              ..where(
                (row) =>
                    row.userId.equals(userId) &
                    row.state.isIn(const ['queued', 'failedRetryable']),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    final ready = <PendingOperation>[];
    for (final operation in queued) {
      if (await isSettled(operation)) continue;
      final dependencyId = operation.dependsOnOperationId;
      final backingOff =
          honorBackoff &&
          operation.state == 'failedRetryable' &&
          operation.safeErrorCode != 'AUTH_REQUIRED' &&
          clock.isBefore(
            SyncRetryPolicy.notBefore(
              operation.lastAttemptAt,
              operation.attemptCount,
            ),
          );
      if (backingOff) {
        waiting.add(operation);
        continue;
      }
      if (dependencyId == null) {
        ready.add(operation);
        continue;
      }
      final dependency =
          await (select(pendingOperations)..where(
                (row) =>
                    row.id.equals(dependencyId) & row.userId.equals(userId),
              ))
              .getSingleOrNull();
      if (dependency?.state == 'committed' ||
          (ledgerActive == false &&
              dependency != null &&
              _isDeferredStockHold(operation, dependency)) ||
          (dependency != null &&
              workspaceId != null &&
              await _settledInventoryAllowsStableChild(
                operation,
                dependency,
                workspaceId,
              ))) {
        ready.add(operation);
      }
    }
    return (ready: ready, waiting: waiting);
  }

  /// A person asked to sync now: every retrying operation may be sent on the
  /// next flush instead of waiting out its backoff. The attempt count is kept,
  /// so the cap of [SyncRetryPolicy.maxAttempts] still applies.
  Future<int> makeRetriesEligibleNow(String userId) =>
      (update(pendingOperations)..where(
            (row) =>
                row.userId.equals(userId) &
                row.state.equals('failedRetryable') &
                row.lastAttemptAt.isNotNull(),
          ))
          .write(
            PendingOperationsCompanion(
              lastAttemptAt: Value(
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              ),
            ),
          );

  /// Settles a transient transport failure of a `sending` operation: back to
  /// `failedRetryable` (attempt count is kept, never reset) or, once
  /// [SyncRetryPolicy.maxAttempts] is spent, `blocked` with a review issue.
  /// A server `Retry-After` is folded into the stored attempt time so the
  /// effective not-before is never earlier than the server asked.
  Future<bool> settleTransientFailure({
    required PendingOperation operation,
    String? safeErrorCode,
    String? safeCorrelationId,
    Duration? retryAfter,
    int maxAttempts = SyncRetryPolicy.maxAttempts,
  }) => db.transaction(() async {
    final current = await getById(operation.id);
    if (current == null || current.state != 'sending') return false;
    if (current.attemptCount >= maxAttempts) {
      final changed = await transitionState(
        operationId: current.id,
        from: 'sending',
        to: 'blocked',
        safeErrorCode: SyncRetryPolicy.retryExhaustedCode,
        safeCorrelationId: safeCorrelationId,
      );
      if (changed) {
        final now = DateTime.now().toUtc();
        await db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: _ids.v4(),
            userId: current.userId,
            entityType: 'stable_record',
            entityId: current.id,
            issueCode: SyncRetryPolicy.retryExhaustedIssueCode,
            snapshotJson: jsonEncode({
              'operationId': current.id,
              'mutationId': current.mutationId,
              'operationType': current.operationType,
              'attempts': current.attemptCount,
              'lastCode': safeErrorCode,
            }),
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      return changed;
    }
    final now = DateTime.now().toUtc();
    final backoff = SyncRetryPolicy.backoffAfter(current.attemptCount);
    final attemptedAt = retryAfter != null && retryAfter > backoff
        ? now.add(retryAfter - backoff)
        : now;
    return transitionState(
      operationId: current.id,
      from: 'sending',
      to: 'failedRetryable',
      attemptedAt: attemptedAt,
      safeErrorCode: safeErrorCode,
      safeCorrelationId: safeCorrelationId,
    );
  });

  /// Records why a waiting operation has not gone out, or clears it: only the
  /// error code changes, never the state or the attempt count. Applies to
  /// queued and retrying operations whose code differs from [code].
  Future<bool> setWaitReason(String operationId, String? code) async {
    final changed =
        await (update(pendingOperations)..where(
              (row) =>
                  row.id.equals(operationId) &
                  row.state.isIn(const ['queued', 'failedRetryable']) &
                  (code == null
                      ? row.safeErrorCode.isIn(const [
                          'INVENTORY_START_PENDING',
                          'INVENTORY_START_WAITS_FOR_REVIEW',
                        ])
                      : row.safeErrorCode.isNull() |
                            row.safeErrorCode.equals(code).not()),
            ))
            .write(PendingOperationsCompanion(safeErrorCode: Value(code)));
    return changed == 1;
  }

  Future<bool> transitionState({
    required String operationId,
    required String from,
    required String to,
    DateTime? attemptedAt,
    String? safeErrorCode,
    String? safeCorrelationId,
  }) async {
    final current =
        await (select(pendingOperations)..where(
              (row) => row.id.equals(operationId) & row.state.equals(from),
            ))
            .getSingleOrNull();
    if (current == null) return false;
    final changed =
        await (update(pendingOperations)..where(
              (row) => row.id.equals(operationId) & row.state.equals(from),
            ))
            .write(
              PendingOperationsCompanion(
                state: Value(to),
                lastAttemptAt: attemptedAt == null
                    ? const Value.absent()
                    : Value(attemptedAt),
                attemptCount: to == 'sending'
                    ? Value(current.attemptCount + 1)
                    : const Value.absent(),
                safeErrorCode: safeErrorCode == null
                    ? const Value.absent()
                    : Value(safeErrorCode),
                safeCorrelationId: safeCorrelationId == null
                    ? const Value.absent()
                    : Value(safeCorrelationId),
              ),
            );
    return changed == 1;
  }

  /// A process restart after a stable request entered `sending` has no durable
  /// response receipt. Keep the payload, block automatic replay, and leave an
  /// auditable issue for later authenticated reconciliation.
  Future<int> recoverInterruptedOperations({String? userId}) async {
    return db.transaction(() async {
      final interrupted =
          await (select(pendingOperations)..where(
                (row) =>
                    row.state.equals('sending') &
                    (userId == null
                        ? const Constant<bool>(true)
                        : row.userId.equals(userId)),
              ))
              .get();
      if (interrupted.isEmpty) return 0;
      final now = DateTime.now().toUtc();
      var recovered = 0;
      for (final operation in interrupted) {
        final effects = await getEffects(operation.id);
        if (effects.isNotEmpty) {
          // A durable acknowledgement makes earlier subeffects permanent. If
          // the next one was never marked sending, resume at that checkpoint;
          // an in-flight one was made uncertain and blocked above.
          if (effects.any(
            (effect) =>
                effect.state == 'sending' || effect.state == 'uncertain',
          )) {
            continue;
          }
          final nextState =
              effects.every((effect) => effect.state == 'acknowledged')
              ? 'committed'
              : 'queued';
          final changed =
              await (update(pendingOperations)..where(
                    (row) =>
                        row.id.equals(operation.id) &
                        row.state.equals('sending'),
                  ))
                  .write(PendingOperationsCompanion(state: Value(nextState)));
          if (changed == 1) recovered++;
          continue;
        }
        if (ScheduleRepairIntent.fromOperation(operation) != null) {
          recovered +=
              await (update(pendingOperations)..where(
                    (row) =>
                        row.id.equals(operation.id) &
                        row.state.equals('sending'),
                  ))
                  .write(
                    const PendingOperationsCompanion(
                      state: Value('queued'),
                      safeErrorCode: Value(
                        'SCHEDULE_REPAIR_OUTCOME_UNCONFIRMED',
                      ),
                    ),
                  );
          continue;
        }
        if (_hasFrozenRequest(operation)) {
          // The body was frozen in the same transaction as the claim, so a
          // replay carries the identical body under the same mutation id and
          // the server answers from its receipt. attemptCount is kept.
          recovered +=
              await (update(pendingOperations)..where(
                    (row) =>
                        row.id.equals(operation.id) &
                        row.state.equals('sending'),
                  ))
                  .write(
                    const PendingOperationsCompanion(state: Value('queued')),
                  );
          continue;
        }
        final changed =
            await (update(pendingOperations)..where(
                  (row) =>
                      row.id.equals(operation.id) & row.state.equals('sending'),
                ))
                .write(
                  const PendingOperationsCompanion(state: Value('blocked')),
                );
        if (changed != 1) continue;
        recovered++;
        await db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: _ids.v4(),
            userId: operation.userId,
            entityType: 'stable_record',
            entityId: operation.id,
            issueCode: 'interrupted_stable_mutation_uncertain',
            snapshotJson: jsonEncode({
              'operationId': operation.id,
              'mutationId': operation.mutationId,
              'operationType': operation.operationType,
            }),
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      return recovered;
    });
  }

  static const _frozenRequestKeys = [
    'frozenRequest',
    'resolvedCommand',
    'resolvedInventoryRequest',
    // Bridge commands freeze their body before the claim; the command id is a
    // permanent server receipt, so a crash-recovered replay is idempotent.
    'medicationBridgeRequest',
  ];

  /// Stable and v2 medication operations freeze their exact request when they
  /// are first claimed. Without that marker a `sending` row may predate the
  /// freeze and its delivery cannot be proven either way.
  bool _hasFrozenRequest(PendingOperation operation) {
    if (operation.component != 'stable' &&
        operation.component != 'medication') {
      return false;
    }
    try {
      final payload = jsonDecode(operation.payloadJson);
      return payload is Map &&
          _frozenRequestKeys.any((key) => payload[key] is Map);
    } on FormatException {
      return false;
    }
  }

  Future<List<PendingOperationEffect>> getEffects(String operationId) =>
      (select(pendingOperationEffects)
            ..where((row) => row.operationId.equals(operationId))
            ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
          .get();

  Future<bool> hasEffectForLegacySource(String sourceId) async {
    final rows =
        await (select(pendingOperationEffects)
              ..where((row) => row.legacySourceId.equals(sourceId))
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }

  Future<bool> hasUncommittedEntity({
    required String userId,
    required String component,
    required String entityType,
    required String entityLocalId,
  }) async {
    final rows =
        await (select(pendingOperations)..where(
              (row) =>
                  row.userId.equals(userId) &
                  row.component.equals(component) &
                  row.state.isNotIn(const ['committed', 'discarded']),
            ))
            .get();
    for (final row in rows) {
      if (await isSettled(row)) continue;
      try {
        final payload = jsonDecode(row.payloadJson);
        if (payload is Map<String, dynamic> &&
            payload['entityType'] == entityType &&
            payload['entityLocalId'] == entityLocalId) {
          return true;
        }
      } on FormatException {
        // Corrupt intent cannot be treated as a matching entity.
      }
    }
    return false;
  }

  Future<bool> markEffectSending(String effectId, DateTime attemptedAt) async {
    return db.transaction(() async {
      final effect =
          await (select(pendingOperationEffects)..where(
                (row) => row.id.equals(effectId) & row.state.equals('queued'),
              ))
              .getSingleOrNull();
      if (effect == null) return false;
      final operation = await (select(
        pendingOperations,
      )..where((row) => row.id.equals(effect.operationId))).getSingleOrNull();
      if (operation == null ||
          !const {
            'queued',
            'sending',
            'failedRetryable',
          }.contains(operation.state)) {
        return false;
      }
      final earlier =
          await (select(pendingOperationEffects)..where(
                (row) =>
                    row.operationId.equals(effect.operationId) &
                    row.ordinal.isSmallerThanValue(effect.ordinal),
              ))
              .get();
      if (earlier.any((row) => row.state != 'acknowledged')) return false;
      final changed =
          await (update(pendingOperationEffects)..where(
                (row) => row.id.equals(effectId) & row.state.equals('queued'),
              ))
              .write(
                PendingOperationEffectsCompanion(
                  state: const Value('sending'),
                  attemptedAt: Value(attemptedAt),
                ),
              );
      if (changed != 1) return false;
      await (update(
        pendingOperations,
      )..where((row) => row.id.equals(operation.id))).write(
        PendingOperationsCompanion(
          state: const Value('sending'),
          attemptCount: Value(operation.attemptCount + 1),
          lastAttemptAt: Value(attemptedAt),
        ),
      );
      return true;
    });
  }

  Future<bool> markEffectUncertain(
    String effectId, {
    String? safeErrorCode,
    String? safeCorrelationId,
  }) async {
    return db.transaction(() async {
      final effect =
          await (select(pendingOperationEffects)..where(
                (row) => row.id.equals(effectId) & row.state.equals('sending'),
              ))
              .getSingleOrNull();
      if (effect == null) return false;
      final operation = await getById(effect.operationId);
      if (operation == null) return false;
      final now = DateTime.now().toUtc();
      final updated =
          await (update(pendingOperationEffects)..where(
                (row) => row.id.equals(effect.id) & row.state.equals('sending'),
              ))
              .write(
                PendingOperationEffectsCompanion(
                  state: const Value('uncertain'),
                  attemptedAt: Value(effect.attemptedAt ?? now),
                ),
              );
      if (updated != 1) return false;
      await (update(
        pendingOperations,
      )..where((row) => row.id.equals(operation.id))).write(
        PendingOperationsCompanion(
          state: const Value('blocked'),
          safeErrorCode: safeErrorCode == null
              ? const Value.absent()
              : Value(safeErrorCode),
          safeCorrelationId: safeCorrelationId == null
              ? const Value.absent()
              : Value(safeCorrelationId),
        ),
      );
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: _ids.v4(),
          userId: operation.userId,
          entityType: effect.kind == 'dose' ? 'dose_log' : 'pill',
          entityId: effect.legacySourceId ?? operation.id,
          issueCode: 'legacy_effect_delivery_uncertain',
          snapshotJson: jsonEncode({
            'operationId': operation.id,
            'effectOrdinal': effect.ordinal,
            'kind': effect.kind,
            'requestFingerprint': effect.requestFingerprint,
            'errorCode': safeErrorCode,
            'correlationId': safeCorrelationId,
          }),
          createdAt: now,
          updatedAt: now,
        ),
      );
      return true;
    });
  }

  Future<bool> markEffectRetryable(
    String effectId, {
    String safeErrorCode = 'AUTH_REQUIRED',
  }) async {
    return db.transaction(() async {
      final effect =
          await (select(pendingOperationEffects)..where(
                (row) => row.id.equals(effectId) & row.state.equals('sending'),
              ))
              .getSingleOrNull();
      if (effect == null) return false;
      final operation = await getById(effect.operationId);
      if (operation == null || operation.state != 'sending') return false;
      final updated =
          await (update(pendingOperationEffects)..where(
                (row) => row.id.equals(effect.id) & row.state.equals('sending'),
              ))
              .write(
                const PendingOperationEffectsCompanion(state: Value('queued')),
              );
      if (updated != 1) return false;
      await (update(pendingOperations)..where(
            (row) => row.id.equals(operation.id) & row.state.equals('sending'),
          ))
          .write(
            PendingOperationsCompanion(
              state: const Value('failedRetryable'),
              safeErrorCode: Value(safeErrorCode),
            ),
          );
      return true;
    });
  }

  Future<bool> acknowledgeEffect({
    required String effectId,
    required String safeServerId,
    required String safeResultFingerprint,
    required DateTime acknowledgedAt,
  }) async {
    return db.transaction(() async {
      final effect =
          await (select(pendingOperationEffects)..where(
                (row) => row.id.equals(effectId) & row.state.equals('sending'),
              ))
              .getSingleOrNull();
      if (effect == null) return false;
      await (update(
        pendingOperationEffects,
      )..where((row) => row.id.equals(effectId))).write(
        PendingOperationEffectsCompanion(
          state: const Value('acknowledged'),
          safeServerId: Value(safeServerId),
          safeResultFingerprint: Value(safeResultFingerprint),
          acknowledgedAt: Value(acknowledgedAt),
        ),
      );
      final remaining = await (select(
        pendingOperationEffects,
      )..where((row) => row.operationId.equals(effect.operationId))).get();
      if (remaining.every((row) => row.state == 'acknowledged')) {
        await (update(pendingOperations)
              ..where((row) => row.id.equals(effect.operationId)))
            .write(const PendingOperationsCompanion(state: Value('committed')));
      }
      return true;
    });
  }

  Future<bool> markEffectCheckpointRecorded({
    required String effectId,
    required String receiptId,
  }) async {
    if (receiptId.isEmpty || receiptId.length > 128) return false;
    final changed =
        await (update(pendingOperationEffects)..where(
              (row) =>
                  row.id.equals(effectId) &
                  row.state.isIn(const [
                    'acknowledged',
                    'uncertain',
                    'sending',
                  ]),
            ))
            .write(
              PendingOperationEffectsCompanion(
                safeResultFingerprint: Value(
                  '${LegacySplitIdentity.recordedMarkerPrefix}$receiptId',
                ),
              ),
            );
    return changed == 1;
  }

  Future<bool> markEffectLocalReviewRequired({
    required String effectId,
    required String issueId,
  }) async {
    if (issueId.isEmpty || issueId.length > 128) return false;
    final changed =
        await (update(pendingOperationEffects)..where(
              (row) =>
                  row.id.equals(effectId) &
                  row.state.isIn(const ['acknowledged', 'uncertain']),
            ))
            .write(
              PendingOperationEffectsCompanion(
                safeResultFingerprint: Value('local-review-required:$issueId'),
              ),
            );
    return changed == 1;
  }

  Future<bool> blockForReview({
    required String operationId,
    required String safeErrorCode,
    String? safeCorrelationId,
  }) async {
    final changed =
        await (update(
          pendingOperations,
        )..where((row) => row.id.equals(operationId))).write(
          PendingOperationsCompanion(
            state: const Value('blocked'),
            safeErrorCode: Value(safeErrorCode),
            safeCorrelationId: Value(safeCorrelationId),
          ),
        );
    return changed == 1;
  }

  /// Any crash after persisting `sending` is uncertain, never silently replayed.
  Future<int> recoverInterruptedEffects({String? userId}) async {
    return db.transaction(() async {
      final interrupted =
          await (select(pendingOperationEffects)..where(
                (row) =>
                    row.state.equals('sending') &
                    (userId == null
                        ? const Constant<bool>(true)
                        : row.operationId.isInQuery(
                            selectOnly(pendingOperations)
                              ..addColumns([pendingOperations.id])
                              ..where(pendingOperations.userId.equals(userId)),
                          )),
              ))
              .get();
      if (interrupted.isEmpty) return 0;
      final now = DateTime.now().toUtc();
      await batch((batch) {
        for (final effect in interrupted) {
          batch.update(
            pendingOperationEffects,
            PendingOperationEffectsCompanion(
              state: const Value('uncertain'),
              attemptedAt: Value(effect.attemptedAt ?? now),
            ),
            where: (row) => row.id.equals(effect.id),
          );
          batch.update(
            pendingOperations,
            const PendingOperationsCompanion(state: Value('blocked')),
            where: (row) => row.id.equals(effect.operationId),
          );
        }
      });
      for (final effect in interrupted) {
        final operation = await (select(
          pendingOperations,
        )..where((row) => row.id.equals(effect.operationId))).getSingleOrNull();
        if (operation == null) continue;
        await db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: _ids.v4(),
            userId: operation.userId,
            entityType: effect.kind == 'dose' ? 'dose_log' : 'pill',
            entityId: effect.legacySourceId ?? operation.id,
            issueCode: 'interrupted_legacy_effect_uncertain',
            snapshotJson: jsonEncode({
              'operationId': operation.id,
              'effectOrdinal': effect.ordinal,
              'kind': effect.kind,
            }),
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      return interrupted.length;
    });
  }
}
