import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../workspace/workspace_context.dart';
import 'component_merge_values.dart';
import 'legacy_split_identity.dart';
import 'sync_write_scope.dart';

/// Account identity, migration issues and reviewed-effect settlement.
///
/// Runs inside the transaction opened by the caller of
/// `ComponentSyncMerger.merge`; it never opens its own and shares the same
/// [writeScope] as its siblings.
class AccountSettlementMerger {
  static const _ids = Uuid();

  AccountSettlementMerger(this.db, {this.writeScope});

  final AppDatabase db;
  final SyncWriteScope? writeScope;
  Future<void> mergeAccount(String userId, Map<String, dynamic> item) async {
    if (writeScope != null && item['id'] != userId) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final user = await db.usersDao.getById(userId);
    if (user == null || user.syncStatus != 'synced') return;
    await db.usersDao.upsert(
      UsersCompanion(
        id: Value(userId),
        email: Value(item['email'] as String),
        createdAt: Value(syncDate(item['createdAt'])),
        updatedAt: Value(syncDate(item['updatedAt'])),
        serverId: Value(item['id'] as String),
        syncStatus: const Value('synced'),
        isDeleted: const Value(false),
      ),
    );
  }

  Future<void> mergeMigrationIssue(
    String userId,
    Map<String, dynamic> item,
  ) async {
    final id = item['id'] as String;
    final revision = int.parse(item['revision'] as String);
    final existing = await db.migrationIssuesDao.getById(id);
    if (existing != null) writeScope?.requireOwner(existing.userId);
    if (existing != null && existing.revision > revision) return;
    final state = item['state'] as String;
    final resolvedAt = syncNullableDate(item['resolvedAt']);
    if ((state == 'unresolved' && (revision != 1 || resolvedAt != null)) ||
        (state == 'resolved' && (revision != 2 || resolvedAt == null)) ||
        (state != 'unresolved' && state != 'resolved')) {
      throw const FormatException('Migration issue revision is inconsistent.');
    }
    await db
        .into(db.migrationIssues)
        .insertOnConflictUpdate(
          MigrationIssuesCompanion(
            id: Value(id),
            userId: Value(userId),
            entityType: Value(item['entityType'] as String),
            entityId: Value(item['entityId'] as String),
            issueCode: Value(item['issueCode'] as String),
            snapshotJson: Value(jsonEncode(item['safeSnapshot'])),
            serverId: Value(id),
            revision: Value(revision),
            resolutionState: Value(state),
            resolvedAt: Value(resolvedAt),
            resolvedByUserId: Value(state == 'resolved' ? userId : null),
            createdAt: Value(syncDate(item['createdAt'])),
            updatedAt: Value(resolvedAt ?? syncDate(item['createdAt'])),
          ),
        );
    if (state == 'resolved' &&
        item['entityType'] == 'medication_split' &&
        item['issueCode'] == 'legacy_split_checkpoint') {
      await _settleReviewedEffect(
        userId,
        id,
        item['safeSnapshot'],
        resolvedAt!,
      );
    }
  }

  Future<void> _settleReviewedEffect(
    String userId,
    String issueId,
    Object? snapshot,
    DateTime resolvedAt,
  ) async {
    final scope = writeScope;
    if (scope == null || snapshot is! Map) return;
    final settlement = snapshot['settlement'];
    if (settlement is! Map) {
      return; // Old server dispositions cannot be guessed.
    }
    const dispositions = {
      'adopt': 'adopted',
      'apply_residual': 'residual_applied',
      'keep_server_state': 'kept_server_state',
    };
    final commandId = settlement['commandId'];
    if (settlement['version'] != 1 ||
        settlement['issueId'] != issueId ||
        !dispositions.containsKey(settlement['resolution']) ||
        dispositions[settlement['resolution']] != settlement['disposition'] ||
        commandId is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(commandId)) {
      throw const FormatException('Legacy settlement identity is invalid.');
    }
    final effects =
        await (db.select(db.pendingOperationEffects)..where(
              (e) => e.safeResultFingerprint.equals(
                '${LegacySplitIdentity.recordedMarkerPrefix}$issueId',
              ),
            ))
            .get();
    if (effects.isEmpty) {
      return; // Another device may own the original checkpoint.
    }
    if (effects.length != 1) {
      throw const FormatException('Legacy settlement link is ambiguous.');
    }
    final effect = effects.single;
    final operation = await db.pendingOperationsDao.getById(effect.operationId);
    if (operation == null || operation.userId != userId) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );
    }
    final original = jsonDecode(operation.payloadJson);
    final mutation = original is Map
        ? LegacySplitIdentity.sourceCommandId(original, operation.mutationId)
        : operation.mutationId;
    if (mutation is! String ||
        LegacySplitIdentity(mutation, effect.ordinal).issueId != issueId) {
      throw const FormatException(
        'Legacy settlement checkpoint identity changed.',
      );
    }
    final workspace = await scope.workspaceId;
    final prior = await (db.select(
      db.effectSettlements,
    )..where((s) => s.effectId.equals(effect.id))).getSingleOrNull();
    if (prior != null &&
        (prior.workspaceId != workspace ||
            prior.userId != userId ||
            prior.issueId != issueId ||
            prior.resolutionCommandId != commandId ||
            prior.resolution != settlement['resolution'] ||
            prior.disposition != settlement['disposition'] ||
            prior.requestFingerprint != effect.requestFingerprint)) {
      throw const FormatException('Legacy settlement receipt changed.');
    }
    if (prior == null) {
      await db
          .into(db.effectSettlements)
          .insert(
            EffectSettlementsCompanion.insert(
              effectId: effect.id,
              workspaceId: workspace,
              userId: userId,
              issueId: issueId,
              resolutionCommandId: commandId,
              resolution: settlement['resolution'] as String,
              disposition: settlement['disposition'] as String,
              requestFingerprint: effect.requestFingerprint,
              resolvedAt: resolvedAt,
            ),
          );
    }
    final localIssues =
        await (db.select(db.migrationIssues)..where(
              (i) =>
                  i.userId.equals(userId) &
                  i.resolutionState.equals('unresolved'),
            ))
            .get();
    for (final issue in localIssues) {
      var exact =
          issue.issueCode == 'legacy_delivery_uncertain' &&
          issue.entityId == effect.legacySourceId &&
          issue.snapshotJson == effect.requestFingerprint;
      if (issue.issueCode == 'legacy_effect_delivery_uncertain') {
        final value = jsonDecode(issue.snapshotJson);
        exact =
            value is Map &&
            value['operationId'] == operation.id &&
            value['effectOrdinal'] == effect.ordinal &&
            value['requestFingerprint'] == effect.requestFingerprint;
      }
      if (exact) {
        await (db.update(
          db.migrationIssues,
        )..where((i) => i.id.equals(issue.id))).write(
          MigrationIssuesCompanion(
            resolutionState: const Value('resolved'),
            resolvedAt: Value(resolvedAt),
            resolvedByUserId: Value(userId),
            updatedAt: Value(resolvedAt),
          ),
        );
      }
    }
  }

  /// An `identityMapping` item ties a bridge-era row (a dose log or a pill's
  /// stock, by its legacy id) to the identity the ledger gave it at
  /// activation. The phone keeps no table for the tie itself, so applying it
  /// means recognising it: the legacy row, or the entity it maps to, is known
  /// here. That needs no note, and closes a note an older build wrote for it.
  /// Only a mapping with neither side known (and so nothing to attach it to)
  /// is kept as a note, flagged `unmapped`.
  Future<void> mergeIdentityMapping(
    String userId,
    Map<String, dynamic> change,
    Map<String, dynamic> payload,
  ) async {
    if (await _mappingIsKnown(payload)) {
      await _resolveMappingNote(userId, change, payload);
      return;
    }
    await recordReviewIssue(userId, change, payload, unmapped: true);
  }

  Future<bool> _mappingIsKnown(Map<String, dynamic> payload) async {
    final source = payload['legacySourceId'];
    if (source is String) {
      switch (payload['legacySourceKind']) {
        case 'dose_log':
          if (await db.doseLogsDao.getById(source) != null ||
              await db.doseLogsDao.getByServerId(source) != null) {
            return true;
          }
        case 'pill_stock':
          if (await db.pillsDao.getById(source) != null ||
              await db.pillsDao.getByServerId(source) != null) {
            return true;
          }
      }
    }
    final target = payload['targetEntityId'];
    if (target is! String) return false;
    return switch (payload['targetEntityType']) {
      'medication_occurrence' =>
        await db.medicationLedgerDao.getOccurrenceByServerId(target) != null,
      'occurrence_event' =>
        await db.medicationLedgerDao.getOccurrenceEventByServerId(target) !=
            null,
      'inventory_event' =>
        await db.medicationLedgerDao.getInventoryEventByServerId(target) !=
            null,
      _ => false,
    };
  }

  String _noteId(String userId, Map<String, dynamic> change, String kind) {
    final component = change['component'] as String? ?? 'sync';
    final entityType = change['entityType'] as String? ?? 'sync_item';
    final entityId = change['entityId'] as String? ?? 'unknown';
    return _ids.v5(
      Namespace.url.value,
      'simpastil:sync-review:$userId:$component:$entityType:$entityId:$kind',
    );
  }

  Future<void> _resolveMappingNote(
    String userId,
    Map<String, dynamic> change,
    Map<String, dynamic> payload,
  ) async {
    final id = _noteId(userId, change, 'identityMapping');
    final prior = await db.migrationIssuesDao.getById(id);
    if (prior == null) return;
    writeScope?.requireOwner(prior.userId);
    await db.migrationIssuesDao.markResolved(
      [id],
      resolvedByUserId: userId,
      at: DateTime.now().toUtc(),
    );
  }

  /// Closes the identity-mapping notes earlier builds wrote for every
  /// bridge-era row at activation. Notes this build keeps for a mapping that
  /// cannot be applied carry `unmapped` and stay. Idempotent.
  Future<int> clearAppliedMappingNotes(String userId) async {
    final ids = <String>[];
    for (final issue in await db.migrationIssuesDao.getUnresolved(userId)) {
      if (issue.issueCode != 'sync_item_needs_review') continue;
      try {
        final snapshot = jsonDecode(issue.snapshotJson);
        if (snapshot is Map &&
            snapshot['kind'] == 'identityMapping' &&
            snapshot['unmapped'] != true) {
          ids.add(issue.id);
        }
      } on FormatException {
        continue;
      }
    }
    if (ids.isEmpty) return 0;
    writeScope?.requireOwner(userId);
    return db.migrationIssuesDao.markResolved(
      ids,
      resolvedByUserId: userId,
      at: DateTime.now().toUtc(),
    );
  }

  Future<void> recordReviewIssue(
    String userId,
    Map<String, dynamic> change,
    Map<String, dynamic> payload, {
    bool unmapped = false,
  }) async {
    final component = change['component'] as String? ?? 'sync';
    final entityType = change['entityType'] as String? ?? 'sync_item';
    final entityId =
        change['entityId'] as String? ??
        payload['id'] as String? ??
        payload['targetEntityId'] as String? ??
        'unknown';
    final kind = payload['kind'];
    final entityKey = '$userId:$component:$entityType:$entityId';
    // The id carries the item's kind: a later, different server item for the
    // same entity (a tombstone after an identity-mapping note) is its own
    // note. A note without a kind keeps the original entity-only id.
    final kindKey = kind is String && kind.isNotEmpty ? kind : null;
    final issueId = _ids.v5(
      Namespace.url.value,
      kindKey == null
          ? 'simpastil:sync-review:$entityKey'
          : 'simpastil:sync-review:$entityKey:$kindKey',
    );
    // A replay (reset checkpoints, re-download) delivers the same server item
    // again. The note keeps whatever state the person left it in: rewriting
    // 'unresolved' over a dismissed row would break the resolved_at check and
    // fail the whole pull transaction for good.
    final prior = await db.migrationIssuesDao.getById(issueId);
    if (prior != null) {
      writeScope?.requireOwner(prior.userId);
      return;
    }
    if (kindKey != null) {
      // Notes written before the kind joined the id live under the
      // entity-only id; the same kind there is the same server item.
      final legacyId = _ids.v5(
        Namespace.url.value,
        'simpastil:sync-review:$entityKey',
      );
      final legacy = await db.migrationIssuesDao.getById(legacyId);
      if (legacy != null) {
        writeScope?.requireOwner(legacy.userId);
        if (_snapshotKind(legacy.snapshotJson) == kindKey) return;
      }
    }
    final now = DateTime.now().toUtc();
    await db
        .into(db.migrationIssues)
        .insert(
          MigrationIssuesCompanion.insert(
            id: issueId,
            userId: userId,
            entityType: entityType,
            entityId: entityId,
            issueCode: 'sync_item_needs_review',
            snapshotJson: jsonEncode({
              'component': component,
              'entityType': entityType,
              'entityId': entityId,
              'kind': payload['kind'],
              if (unmapped) 'unmapped': true,
            }),
            serverId: const Value(null),
            revision: const Value(1),
            resolutionState: const Value('unresolved'),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  static String? _snapshotKind(String snapshotJson) {
    try {
      final value = jsonDecode(snapshotJson);
      final kind = value is Map ? value['kind'] : null;
      return kind is String ? kind : null;
    } on FormatException {
      return null;
    }
  }
}
