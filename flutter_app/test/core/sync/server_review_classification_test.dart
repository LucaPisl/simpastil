import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/medication/care_recording.dart'
    show CareSharingOutcome;
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/sync_review_repository.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000001';
const _otherOwnerId = '10000000-0000-4000-8000-000000000002';

Future<({PendingOperation operation, List<PendingOperationEffect> effects})>
_blockedOperation(
  ProtectedWorkspaceFixture fixture,
  String suffix, {
  int effectCount = 1,
}) async {
  final mutationId = 'fictional-review-mutation-$suffix';
  final recorded = await PendingOperationRepository(fixture.db).record(
    operation: PendingOperationDraft(
      userId: fixture.context.ownerUserId,
      mutationId: mutationId,
      component: 'medication',
      operationType: 'legacy.dose',
      entityType: 'doseLog',
      entityLocalId: 'fictional-dose-$suffix',
      payload: {
        'command': {'commandId': mutationId},
      },
      effects: [
        for (var ordinal = 0; ordinal < effectCount; ordinal++)
          PendingOperationEffectDraft(
            kind: 'dose',
            legacySourceId: 'fictional-dose-$suffix',
            requestFingerprint: 'fictional-request-$suffix-$ordinal',
          ),
      ],
    ),
    applyProjection: () async {},
  );
  await (fixture.db.update(fixture.db.pendingOperations)
        ..where((row) => row.id.equals(recorded.operationId)))
      .write(const PendingOperationsCompanion(state: Value('blocked')));
  return (
    operation: (await fixture.db.pendingOperationsDao.getById(
      recorded.operationId,
    ))!,
    effects: await fixture.db.pendingOperationsDao.getEffects(
      recorded.operationId,
    ),
  );
}

String _issueId(String mutationId, int ordinal) =>
    projectionCommandIdForKey('legacy-split-issue-v1:$mutationId:$ordinal');

String _issueCommandId(String mutationId, int ordinal) =>
    projectionCommandIdForKey('legacy-split-command-v1:$mutationId:$ordinal');

Future<void> _markUncertain(
  AppDatabase db,
  PendingOperationEffect effect, {
  String? marker,
}) async {
  await (db.update(
    db.pendingOperationEffects,
  )..where((row) => row.id.equals(effect.id))).write(
    PendingOperationEffectsCompanion(
      state: const Value('uncertain'),
      attemptedAt: Value(DateTime.utc(2026, 10, 8)),
      safeResultFingerprint: Value(marker),
    ),
  );
}

Future<void> _recordServerReview(
  ProtectedWorkspaceFixture fixture,
  PendingOperation operation,
  PendingOperationEffect effect, {
  String? linkedIssueId,
  String? issueOwnerId,
  String entityType = 'medication_split',
  String issueCode = 'legacy_split_checkpoint',
  bool serverBacked = true,
}) async {
  final issueId =
      linkedIssueId ?? _issueId(operation.mutationId, effect.ordinal);
  final now = DateTime.utc(2026, 10, 8);
  await _markUncertain(
    fixture.db,
    effect,
    marker: 'reconciliation-recorded:$issueId',
  );
  await fixture.db.migrationIssuesDao.record(
    MigrationIssuesCompanion.insert(
      id: issueId,
      userId: issueOwnerId ?? operation.userId,
      entityType: entityType,
      entityId: _issueCommandId(operation.mutationId, effect.ordinal),
      issueCode: issueCode,
      snapshotJson: '{"fictional":"server review evidence"}',
      serverId: serverBacked ? Value(issueId) : const Value.absent(),
      revision: const Value(1),
      resolutionState: const Value('unresolved'),
      createdAt: now,
      updatedAt: now,
    ),
  );
}

CareSharingStatusRepository _statusReader(ProtectedWorkspaceFixture fixture) =>
    CareSharingStatusRepository(
      database: fixture.db,
      access: fixture.access,
      context: fixture.context,
    );

Future<CareSharingStatus> _nextStatusWhere(
  StreamIterator<CareSharingStatus> iterator,
  bool Function(CareSharingStatus) predicate,
) async {
  for (var attempt = 0; attempt < 6; attempt++) {
    if (!await iterator.moveNext().timeout(const Duration(seconds: 5))) break;
    final value = iterator.current;
    if (predicate(value)) return value;
  }
  throw StateError('Care sharing status did not reach the expected state.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'review snapshot, care status and per-operation outcomes agree',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create(ownerId: _ownerId);
      addTearDown(fixture.db.close);
      final reviewed = await _blockedOperation(fixture, 'agree-reviewed');
      await _recordServerReview(
        fixture,
        reviewed.operation,
        reviewed.effects.single,
      );
      final uncertain = await _blockedOperation(fixture, 'agree-uncertain');
      await _markUncertain(fixture.db, uncertain.effects.single);
      final queued = await _blockedOperation(fixture, 'agree-queued');
      await (fixture.db.update(fixture.db.pendingOperations)
            ..where((row) => row.id.equals(queued.operation.id)))
          .write(const PendingOperationsCompanion(state: Value('queued')));

      final outcomes = await fixture.access.withGrant(
        fixture.context,
        () async => [
          for (final id in [
            reviewed.operation.id,
            uncertain.operation.id,
            queued.operation.id,
          ])
            await operationSharingOutcome(
              fixture.db,
              fixture.context,
              (await fixture.db.pendingOperationsDao.getById(id))!,
            ),
        ],
      );
      expect(outcomes, [
        CareSharingOutcome.needsReview,
        CareSharingOutcome.uncertain,
        CareSharingOutcome.pending,
      ]);

      final snapshot = await SyncReviewRepository(
        database: fixture.db,
        access: fixture.access,
        context: fixture.context,
      ).load();
      expect(
        (
          snapshot.pendingCount,
          snapshot.needsReviewCount,
          snapshot.uncertainCount,
        ),
        (1, 1, 1),
      );
      expect(snapshot.actionableIssues.map((issue) => issue.id), [
        _issueId(reviewed.operation.mutationId, 0),
      ]);
      expect(snapshot.retainedInformation, isEmpty);

      final status = await _statusReader(fixture).load();
      expect(
        (status.pendingCount, status.needsReviewCount, status.uncertainCount),
        (1, 1, 1),
      );
    },
  );

  test(
    'blocked effects count as review only with a matching same-owner server issue',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create(ownerId: _ownerId);
      addTearDown(fixture.db.close);

      await fixture.db
          .into(fixture.db.users)
          .insert(
            UsersCompanion.insert(
              id: _otherOwnerId,
              email: 'fictional-other-owner@example.test',
              createdAt: DateTime.utc(2026, 10, 8),
              updatedAt: DateTime.utc(2026, 10, 8),
            ),
          );

      final unlinked = await _blockedOperation(fixture, 'unlinked');
      await _markUncertain(fixture.db, unlinked.effects.single);
      expect(
        await fixture.db.pendingOperationsDao.awaitsServerReview(
          unlinked.operation,
          workspaceId: fixture.context.workspaceId,
        ),
        isFalse,
      );

      final mixed = await _blockedOperation(fixture, 'mixed', effectCount: 2);
      await _recordServerReview(fixture, mixed.operation, mixed.effects.first);
      await _markUncertain(fixture.db, mixed.effects.last);
      expect(
        await fixture.db.pendingOperationsDao.awaitsServerReview(
          mixed.operation,
          workspaceId: fixture.context.workspaceId,
        ),
        isFalse,
        reason:
            'one unlinked outstanding effect keeps the whole operation uncertain',
      );

      final wrongOwner = await _blockedOperation(fixture, 'wrong-owner');
      await _recordServerReview(
        fixture,
        wrongOwner.operation,
        wrongOwner.effects.single,
        issueOwnerId: _otherOwnerId,
      );
      expect(
        await fixture.db.pendingOperationsDao.awaitsServerReview(
          wrongOwner.operation,
          workspaceId: fixture.context.workspaceId,
        ),
        isFalse,
      );

      final substitutedMarker = await _blockedOperation(
        fixture,
        'substituted-marker',
      );
      await _recordServerReview(
        fixture,
        substitutedMarker.operation,
        substitutedMarker.effects.single,
        linkedIssueId: 'fictional-unrelated-server-issue',
      );
      expect(
        await fixture.db.pendingOperationsDao.awaitsServerReview(
          substitutedMarker.operation,
          workspaceId: fixture.context.workspaceId,
        ),
        isFalse,
        reason: 'the marker must identify this effect’s deterministic issue',
      );

      final localIssue = await _blockedOperation(fixture, 'local-issue');
      await _recordServerReview(
        fixture,
        localIssue.operation,
        localIssue.effects.single,
        serverBacked: false,
      );
      expect(
        await fixture.db.pendingOperationsDao.awaitsServerReview(
          localIssue.operation,
          workspaceId: fixture.context.workspaceId,
        ),
        isFalse,
      );

      final review = await _blockedOperation(fixture, 'valid-review');
      await _recordServerReview(
        fixture,
        review.operation,
        review.effects.single,
      );
      expect(
        await fixture.db.pendingOperationsDao.awaitsServerReview(
          review.operation,
          workspaceId: fixture.context.workspaceId,
        ),
        isTrue,
      );
    },
  );

  test(
    'sharing status watches review evidence and exact workspace settlement',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create(ownerId: _ownerId);
      addTearDown(fixture.db.close);
      final blocked = await _blockedOperation(fixture, 'watched');
      final effect = blocked.effects.single;
      await _markUncertain(fixture.db, effect);

      final iterator = StreamIterator(_statusReader(fixture).watch());
      addTearDown(iterator.cancel);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.uncertainCount, 1);
      expect(iterator.current.needsReviewCount, 0);

      await _recordServerReview(fixture, blocked.operation, effect);
      final reviewed = await _nextStatusWhere(
        iterator,
        (status) => status.needsReviewCount == 1,
      );
      expect(reviewed.uncertainCount, 0);

      final now = DateTime.utc(2026, 10, 8, 12);
      await fixture.db.transaction(() async {
        await (fixture.db.update(fixture.db.migrationIssues)..where(
              (row) => row.id.equals(
                _issueId(blocked.operation.mutationId, effect.ordinal),
              ),
            ))
            .write(
              MigrationIssuesCompanion(
                resolutionState: const Value('resolved'),
                resolvedByUserId: Value(fixture.context.ownerUserId),
                resolvedAt: Value(now),
                updatedAt: Value(now),
              ),
            );
        await fixture.db
            .into(fixture.db.effectSettlements)
            .insert(
              EffectSettlementsCompanion.insert(
                effectId: effect.id,
                workspaceId: fixture.context.workspaceId,
                userId: fixture.context.ownerUserId,
                issueId: _issueId(blocked.operation.mutationId, effect.ordinal),
                resolutionCommandId: 'fictional-review-resolution',
                resolution: 'keep_server_state',
                disposition: 'kept_server_state',
                requestFingerprint: effect.requestFingerprint,
                resolvedAt: now,
              ),
            );
      });
      final settled = await _nextStatusWhere(
        iterator,
        (status) => status.needsReviewCount == 0 && status.uncertainCount == 0,
      );
      expect(settled.needsReviewCount, 0);
      expect(settled.uncertainCount, 0);
      expect(
        (await fixture.db.pendingOperationsDao.getById(
          blocked.operation.id,
        ))!.state,
        'blocked',
        reason: 'classification retains the original operation state',
      );
      expect(
        (await fixture.db.pendingOperationsDao.getEffects(
          blocked.operation.id,
        )).single.state,
        'uncertain',
        reason: 'classification retains the original delivery evidence',
      );
    },
  );

  test(
    'unsettled care status ignores settlements from another workspace',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create(ownerId: _ownerId);
      addTearDown(fixture.db.close);
      final blocked = await _blockedOperation(fixture, 'wrong-workspace');
      final effect = blocked.effects.single;
      await _recordServerReview(fixture, blocked.operation, effect);
      final issueId = _issueId(blocked.operation.mutationId, effect.ordinal);
      await (fixture.db.update(
        fixture.db.migrationIssues,
      )..where((row) => row.id.equals(issueId))).write(
        MigrationIssuesCompanion(
          resolutionState: const Value('resolved'),
          resolvedByUserId: Value(fixture.context.ownerUserId),
          resolvedAt: Value(DateTime.utc(2026, 10, 8)),
          updatedAt: Value(DateTime.utc(2026, 10, 8)),
        ),
      );
      final localWorkspace = await fixture.access.workspaces.ensureLocal();
      await fixture.db
          .into(fixture.db.effectSettlements)
          .insert(
            EffectSettlementsCompanion.insert(
              effectId: effect.id,
              workspaceId: localWorkspace.id,
              userId: fixture.context.ownerUserId,
              issueId: issueId,
              resolutionCommandId: 'fictional-other-workspace-resolution',
              resolution: 'keep_server_state',
              disposition: 'kept_server_state',
              requestFingerprint: effect.requestFingerprint,
              resolvedAt: DateTime.utc(2026, 10, 8),
            ),
          );

      final status = await _statusReader(fixture).load();
      expect(status.needsReviewCount, 0);
      expect(status.uncertainCount, 1);
    },
  );
}
