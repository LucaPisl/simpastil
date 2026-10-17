import 'dart:convert';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Table, TableInfo;

import '../db/database.dart';
import '../medication/care_recording.dart' show CareSharingOutcome;
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'legacy_split_identity.dart';
import 'ledger_mode_hint.dart';
import 'retired_schedule_review.dart';
import 'retired_stock_review.dart';
import 'sync_service.dart' show SyncService;

// Shared read model for durable sync review: the sharing outcome of one local
// operation, how many unsettled operations wait in each outcome, and which
// stored migration issues are actionable tasks or retained information.
// Transport state (an attempt running now, its last error) stays in
// SyncStatusNotifier; care-pull freshness stays with its checkpoints.

/// The sharing outcome of one local [operation] in [context].
///
/// The caller decides what an untracked change (no operation) means, because
/// that depends on whether the server already returned its own record.
Future<CareSharingOutcome> operationSharingOutcome(
  AppDatabase db,
  WorkspaceContext context,
  PendingOperation operation,
) async {
  if (context.isLocal) return CareSharingOutcome.localOnly;
  final dao = db.pendingOperationsDao;
  if (await dao.isSettled(operation, workspaceId: context.workspaceId)) {
    return CareSharingOutcome.reconciled;
  }
  return switch (operation.state) {
    'committed' => CareSharingOutcome.acknowledged,
    'conflict' => CareSharingOutcome.needsReview,
    'blocked' =>
      await dao.awaitsServerReview(operation, workspaceId: context.workspaceId)
          ? CareSharingOutcome.needsReview
          : CareSharingOutcome.uncertain,
    _ => CareSharingOutcome.pending,
  };
}

/// One immutable review read for a captured workspace context.
class SyncReviewSnapshot {
  SyncReviewSnapshot({
    required List<MigrationIssueSummary> issues,
    required this.pendingCount,
    required this.needsReviewCount,
    required this.uncertainCount,
  }) : issues = List.unmodifiable(issues);

  /// Every unresolved stored issue owned by the account, in storage order.
  final List<MigrationIssueSummary> issues;

  /// Unsettled care operations of the workspace, by [operationSharingOutcome].
  final int pendingCount;
  final int needsReviewCount;
  final int uncertainCount;

  Iterable<MigrationIssueSummary> get actionableIssues =>
      issues.where((issue) => !issue.isHistoricalInformation);

  Iterable<MigrationIssueSummary> get retainedInformation =>
      issues.where((issue) => issue.isHistoricalInformation);
}

/// Unsettled care operations of a workspace, by [operationSharingOutcome].
class SyncQueueCounts {
  const SyncQueueCounts({
    required this.pendingCount,
    required this.needsReviewCount,
    required this.uncertainCount,
  });

  final int pendingCount;
  final int needsReviewCount;
  final int uncertainCount;
}

class SyncReviewRepository {
  const SyncReviewRepository({
    required this.database,
    required this.access,
    required this.context,
  });

  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;

  /// Tables the issue projection reads.
  Set<TableInfo<Table, Object?>> get issueDependencies => {
    database.migrationIssues,
    database.pendingOperations,
    database.pendingOperationEffects,
    database.effectSettlements,
    database.doseLogs,
    database.schedules,
    database.pills,
    database.profiles,
    database.careWorkspaces,
    database.workspaceGrants,
    database.workspaceAuthors,
    database.workspaceDeviceStates,
  };

  /// Tables the operation counts read.
  Set<TableInfo<Table, Object?>> get queueDependencies => {
    database.pendingOperations,
    database.pendingOperationEffects,
    database.effectSettlements,
    database.careWorkspaces,
    database.workspaceGrants,
    database.workspaceAuthors,
    database.workspaceDeviceStates,
  };

  /// Every table a snapshot reads, for change-driven reloads.
  Set<TableInfo<Table, Object?>> get dependencies => {
    ...issueDependencies,
    ...queueDependencies,
  };

  Future<SyncReviewSnapshot> load() =>
      access.withGrant(context, readUnderGrant);

  /// Reads a snapshot inside a grant the caller already holds for [context].
  Future<SyncReviewSnapshot> readUnderGrant() async {
    final issues = await readIssuesUnderGrant();
    final queue = await readQueueUnderGrant();
    return SyncReviewSnapshot(
      issues: issues,
      pendingCount: queue.pendingCount,
      needsReviewCount: queue.needsReviewCount,
      uncertainCount: queue.uncertainCount,
    );
  }

  /// Reads only the issues inside a grant the caller already holds.
  Future<List<MigrationIssueSummary>> readIssuesUnderGrant() async {
    final userId = context.ownerUserId;
    // Review evidence is account-wide; capture its stock proof in the same
    // authorized read instead of racing a second subscription.
    final accountUnsettled = await database.pendingOperationsDao
        .getUnsettledForUser(userId);
    final medicationProjectionSettled = !accountUnsettled.any(
      (operation) => const {
        'medication',
        'medicationBridge',
      }.contains(operation.component),
    );
    final stableProjectionSettled = !accountUnsettled.any(
      (operation) => operation.component == 'stable',
    );
    final rows =
        await (database.select(database.migrationIssues)..where(
              (i) =>
                  i.userId.equals(userId) &
                  i.resolutionState.equals('unresolved'),
            ))
            .get();
    return projectMigrationIssues(
      database,
      userId,
      rows,
      medicationProjectionSettled: medicationProjectionSettled,
      stableProjectionSettled: stableProjectionSettled,
    );
  }

  /// Reads only the operation counts inside a grant the caller already holds.
  Future<SyncQueueCounts> readQueueUnderGrant() async {
    final userId = context.ownerUserId;
    var pending = 0, needsReview = 0, uncertain = 0;
    if (!context.isLocal) {
      final operations = await database.pendingOperationsDao
          .getUnsettledForUser(userId, workspaceId: context.workspaceId);
      // Stock held for the server's ledger (bridge mode) is not waiting work;
      // it is shown as the calm "stock stays on this phone" note instead.
      final held = SyncService.deferredStockOperationIds(
        operations,
        ledgerActive: await LedgerModeHint.read(),
      );
      for (final operation in operations) {
        if (operation.component == 'account') continue;
        if (held.contains(operation.id)) continue;
        switch (await operationSharingOutcome(database, context, operation)) {
          case CareSharingOutcome.pending:
            pending++;
          case CareSharingOutcome.needsReview:
            needsReview++;
          case CareSharingOutcome.uncertain:
            uncertain++;
          case CareSharingOutcome.reconciled ||
              CareSharingOutcome.acknowledged ||
              CareSharingOutcome.localOnly:
            break;
        }
      }
    }
    return SyncQueueCounts(
      pendingCount: pending,
      needsReviewCount: needsReview,
      uncertainCount: uncertain,
    );
  }

  Stream<List<MigrationIssueSummary>> watchIssues() => database
      .customSelect(
        // Drift shares identical SQL streams; keep this dependency set distinct.
        'SELECT 1 AS sync_review_issue_changes',
        readsFrom: issueDependencies,
      )
      .watch()
      .asyncMap((_) => access.withGrant(context, readIssuesUnderGrant));

  Stream<SyncReviewSnapshot> watch() => database
      .customSelect(
        // Drift shares identical SQL streams; keep this dependency set distinct.
        'SELECT 1 AS sync_review_changes',
        readsFrom: dependencies,
      )
      .watch()
      .asyncMap((_) => load());
}

enum MigrationIssueKind { schedule, medication, other }

enum RetainedSyncInformation {
  legacyHistory,
  retiredRoutine,
  retiredStock,
  missingRoutine,
}

/// A linked local history entry provides context, never proof of delivery.
class LocalDoseReviewContext {
  const LocalDoseReviewContext({
    required this.medicationName,
    required this.scheduledAt,
    required this.localState,
  });
  final String medicationName;
  final DateTime scheduledAt;
  final String localState;
}

/// A bounded, display-safe projection of a locally stored migration issue.
/// The original snapshot JSON is intentionally never exposed to presentation.
class MigrationIssueSummary {
  const MigrationIssueSummary({
    required this.id,
    required this.entityId,
    required this.issueCode,
    required this.revision,
    required this.resolutionState,
    required this.kind,
    required this.createdAt,
    required this.isServerIssue,
    this.checkpointReason,
    this.sourceKind,
    this.sourcePillId,
    this.observedBaseStock,
    this.observedBaseRevision,
    this.savedTargetStock,
    this.verifiedCurrentStock,
    this.retainedInformation,
    this.localDose,
  });

  final String id;
  final String entityId;
  final String issueCode;
  final int revision;
  final String resolutionState;
  final MigrationIssueKind kind;
  final DateTime createdAt;
  final bool isServerIssue;

  /// Informational evidence remains stored and separate from unresolved intent.
  final RetainedSyncInformation? retainedInformation;
  bool get isHistoricalInformation => retainedInformation != null;

  // Only known, bounded checkpoint fields leave this model. The raw payload,
  // fingerprints, operation IDs, and medical notes remain private in storage.
  final String? checkpointReason;
  final String? sourceKind;
  final String? sourcePillId;
  final int? observedBaseStock;
  final String? observedBaseRevision;
  final int? savedTargetStock;
  final int? verifiedCurrentStock;
  final LocalDoseReviewContext? localDose;

  /// Whether this issue can still ask something of a person: it has its own
  /// choices on the Sync page, or it came from this phone and Fix sync
  /// problems lists it as a note to dismiss. A server-sent issue with neither
  /// is kept for reference and must not hold the headline on "Review needed".
  bool get asksForReview =>
      !isHistoricalInformation &&
      (!isServerIssue || canRepairSchedule || canKeepServerState);

  bool get canKeepServerState =>
      isServerIssue &&
      resolutionState == 'unresolved' &&
      revision == 1 &&
      kind == MigrationIssueKind.medication &&
      issueCode == 'legacy_split_checkpoint';

  bool get canRepairSchedule =>
      !isHistoricalInformation &&
      isServerIssue &&
      resolutionState == 'unresolved' &&
      revision == 1 &&
      kind == MigrationIssueKind.schedule &&
      const {
        'invalid_schedule_frequency_days',
        'schedule_timezone_review_required',
      }.contains(issueCode);

  bool get canApplySavedChange =>
      canKeepServerState &&
      checkpointReason == 'source_missing' &&
      sourceKind == 'pill_stock' &&
      sourcePillId != null &&
      observedBaseStock != null &&
      observedBaseRevision != null &&
      savedTargetStock != null;

  MigrationIssueSummary withReviewContext({
    int? stock,
    LocalDoseReviewContext? dose,
    RetainedSyncInformation? retainedInformation,
  }) => MigrationIssueSummary(
    id: id,
    entityId: entityId,
    issueCode: issueCode,
    revision: revision,
    resolutionState: resolutionState,
    kind: kind,
    createdAt: createdAt,
    isServerIssue: isServerIssue,
    checkpointReason: checkpointReason,
    sourceKind: sourceKind,
    sourcePillId: sourcePillId,
    observedBaseStock: observedBaseStock,
    observedBaseRevision: observedBaseRevision,
    savedTargetStock: savedTargetStock,
    verifiedCurrentStock: stock ?? verifiedCurrentStock,
    localDose: dose ?? localDose,
    retainedInformation: retainedInformation ?? this.retainedInformation,
  );

  factory MigrationIssueSummary.fromRow(MigrationIssue row) {
    final isServerIssue = row.serverId != null;
    final issueCode = RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(row.issueCode)
        ? row.issueCode
        : 'unrecognized_issue';
    final kind = switch ((row.entityType, row.issueCode)) {
      ('schedule', _) ||
      (_, 'invalid_schedule_frequency_days') ||
      (_, 'schedule_timezone_review_required') => MigrationIssueKind.schedule,
      ('medication_split', _) ||
      (_, 'legacy_split_checkpoint') => MigrationIssueKind.medication,
      _ => MigrationIssueKind.other,
    };
    final checkpoint = _safeCheckpoint(row.snapshotJson);
    return MigrationIssueSummary(
      id: row.id,
      entityId: row.entityId,
      issueCode: issueCode,
      revision: row.revision,
      resolutionState: row.resolutionState,
      kind: kind,
      createdAt: row.createdAt,
      isServerIssue: isServerIssue,
      retainedInformation: _historicalInformation(row)
          ? RetainedSyncInformation.legacyHistory
          : null,
      checkpointReason: checkpoint?['reason'] as String?,
      sourceKind: checkpoint?['sourceKind'] as String?,
      sourcePillId: checkpoint?['sourcePillId'] as String?,
      observedBaseStock: checkpoint?['observedBaseStock'] as int?,
      observedBaseRevision: checkpoint?['observedBaseRevision'] as String?,
      savedTargetStock: checkpoint?['savedTargetStock'] as int?,
    );
  }

  static bool _historicalInformation(MigrationIssue row) {
    if (row.serverId != null ||
        row.issueCode != 'sync_item_needs_review' ||
        row.entityType != 'legacy_medication_history') {
      return false;
    }
    try {
      final snapshot = jsonDecode(row.snapshotJson);
      return snapshot is Map &&
          snapshot['kind'] == 'legacyEstimatedHistory' &&
          snapshot['entityType'] == row.entityType &&
          snapshot['entityId'] == row.entityId;
    } on FormatException {
      return false;
    }
  }

  static Map<String, Object?>? _safeCheckpoint(String json) {
    if (json.length > 8192) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        return null;
      }
      final reason = decoded['reason'];
      final sourceKind = decoded['legacySourceKind'];
      final sourceId = decoded['legacySourceId'];
      final baseStock = decoded['observedBaseStock'];
      final targetStock = decoded['targetStock'];
      final baseRevision = decoded['observedBaseRevision'];
      final fingerprint = decoded['sourceFingerprint'];
      if (reason is! String ||
          !const {
            'source_missing',
            'base_changed',
            'evidence_ambiguous',
            'evidence_conflict',
          }.contains(reason)) {
        return null;
      }
      if (sourceKind == null && sourceId == null) return {'reason': reason};
      if (sourceKind is! String ||
          !const {'dose_log', 'pill_stock'}.contains(sourceKind)) {
        return null;
      }
      if (sourceId is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            caseSensitive: false,
          ).hasMatch(sourceId)) {
        return null;
      }
      if (sourceKind == 'dose_log') {
        return {'reason': reason, 'sourceKind': sourceKind};
      }
      if (baseStock is! int ||
          targetStock is! int ||
          baseStock < -2147483648 ||
          baseStock > 2147483647 ||
          targetStock < -2147483648 ||
          targetStock > 2147483647) {
        return null;
      }
      if (baseRevision is! String ||
          !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(baseRevision) ||
          BigInt.tryParse(baseRevision) == null ||
          BigInt.parse(baseRevision) > BigInt.from(9223372036854775807)) {
        return null;
      }
      if (fingerprint is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
        return null;
      }
      return {
        'reason': reason,
        'sourceKind': sourceKind,
        'sourcePillId': sourceKind == 'pill_stock' ? sourceId : null,
        'observedBaseStock': baseStock,
        'observedBaseRevision': baseRevision,
        'savedTargetStock': targetStock,
      };
    } on FormatException {
      return null;
    }
  }
}

/// One visible review owns its exact retained local evidence. Neither evidence
/// rows nor operation/effect states are changed by this display projection.
Future<List<MigrationIssueSummary>> projectMigrationIssues(
  AppDatabase db,
  String userId,
  List<MigrationIssue> rows, {
  required bool medicationProjectionSettled,
  required bool stableProjectionSettled,
}) async {
  final owned = rows.where((row) => row.userId == userId).toList();
  final serverReviews = {
    for (final row in owned)
      if (row.serverId == row.id &&
          row.entityType == 'medication_split' &&
          MigrationIssueSummary.fromRow(row).canKeepServerState)
        row.id: row,
  };
  final operations = {
    for (final operation in await db.pendingOperationsDao.getForUser(userId))
      operation.id: operation,
  };
  final linked = <String, List<PendingOperationEffect>>{};
  if (serverReviews.isNotEmpty && operations.isNotEmpty) {
    final effects = await (db.select(
      db.pendingOperationEffects,
    )..where((e) => e.operationId.isIn(operations.keys))).get();
    for (final effect in effects) {
      final operation = operations[effect.operationId]!;
      try {
        final payload = jsonDecode(operation.payloadJson);
        final mutation = payload is Map
            ? LegacySplitIdentity.sourceCommandId(payload, operation.mutationId)
            : operation.mutationId;
        if (mutation is! String || mutation.isEmpty) continue;
        final identity = LegacySplitIdentity(mutation, effect.ordinal);
        final issueId = identity.issueId;
        if (effect.safeResultFingerprint != identity.recordedMarker ||
            !serverReviews.containsKey(issueId) ||
            serverReviews[issueId]!.entityId != identity.resolutionCommandId) {
          continue;
        }
        linked.putIfAbsent(issueId, () => []).add(effect);
      } on FormatException {
        // Malformed intent cannot associate a different record by guesswork.
      }
    }
  }
  final exactLinks = {
    for (final entry in linked.entries)
      if (entry.value.length == 1) entry.key: entry.value.single,
  };
  bool retainedUnderReview(MigrationIssue issue) {
    if (issue.serverId != null) return false;
    for (final effect in exactLinks.values) {
      if (issue.issueCode == 'legacy_delivery_uncertain' &&
          issue.entityId == effect.legacySourceId &&
          issue.snapshotJson == effect.requestFingerprint) {
        return true;
      }
      if (issue.issueCode == 'legacy_effect_delivery_uncertain') {
        try {
          final snapshot = jsonDecode(issue.snapshotJson);
          if (snapshot is Map &&
              snapshot['operationId'] == effect.operationId &&
              snapshot['effectOrdinal'] == effect.ordinal &&
              snapshot['requestFingerprint'] == effect.requestFingerprint) {
            return true;
          }
        } on FormatException {
          // Unmatched evidence stays independently visible.
        }
      }
    }
    return false;
  }

  final summaries = <MigrationIssueSummary>[];
  for (final row in owned) {
    if (retainedUnderReview(row)) continue;
    var summary = MigrationIssueSummary.fromRow(row);
    if (await isRetiredScheduleReview(db, row)) {
      summary = summary.withReviewContext(
        retainedInformation: RetainedSyncInformation.retiredRoutine,
      );
    } else if (await isRetiredStockReview(db, row)) {
      summary = summary.withReviewContext(
        retainedInformation: RetainedSyncInformation.retiredStock,
      );
    } else if (await isMissingScheduleReview(
      db,
      row,
      stableProjectionSettled: stableProjectionSettled,
    )) {
      summary = summary.withReviewContext(
        retainedInformation: RetainedSyncInformation.missingRoutine,
      );
    }
    final effect = exactLinks[row.id];
    if (effect?.kind == 'dose' && effect?.legacySourceId != null) {
      final dose = await db.doseLogsDao.getById(effect!.legacySourceId!);
      final schedule = dose == null
          ? null
          : await db.schedulesDao.getById(dose.scheduleId);
      final pill = schedule == null
          ? null
          : await db.pillsDao.getById(schedule.pillId);
      final person = pill == null
          ? null
          : await db.profilesDao.getById(pill.profileId);
      if (dose != null && pill != null && person?.userId == userId) {
        summary = summary.withReviewContext(
          dose: LocalDoseReviewContext(
            medicationName: pill.name,
            scheduledAt: dose.scheduledAt,
            localState: dose.status,
          ),
        );
      }
    }
    final pillId = summary.sourcePillId;
    if (pillId != null && medicationProjectionSettled) {
      final pill = await db.pillsDao.getByMappedOrLocalId(pillId);
      if (pill != null && pill.syncStatus == 'synced') {
        final profile = await db.profilesDao.getById(pill.profileId);
        if (profile?.userId == userId) {
          summary = summary.withReviewContext(stock: pill.currentStock);
        }
      }
    }
    summaries.add(summary);
  }
  return List.unmodifiable(summaries);
}
