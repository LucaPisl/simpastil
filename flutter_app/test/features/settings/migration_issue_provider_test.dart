import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/retired_schedule_review.dart';
import 'package:simpastil/core/sync/schedule_review_target.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'received historical information is distinct from unresolved intent',
    () {
      final historical =
          _issue(
            snapshotJson: jsonEncode({
              'kind': 'legacyEstimatedHistory',
              'entityType': 'legacy_medication_history',
              'entityId': 'historical-id',
            }),
          ).copyWith(
            entityType: 'legacy_medication_history',
            entityId: 'historical-id',
            issueCode: 'sync_item_needs_review',
            serverId: const Value(null),
          );
      expect(
        MigrationIssueSummary.fromRow(historical).isHistoricalInformation,
        isTrue,
      );
      expect(
        MigrationIssueSummary.fromRow(
          historical.copyWith(snapshotJson: '{"kind":"tombstone"}'),
        ).isHistoricalInformation,
        isFalse,
      );
      expect(
        MigrationIssueSummary.fromRow(
          historical.copyWith(issueCode: 'legacy_delivery_uncertain'),
        ).isHistoricalInformation,
        isFalse,
      );
    },
  );
  test(
    'projects only bounded source-missing stock fields for explicit review',
    () {
      final issue = MigrationIssueSummary.fromRow(
        _issue(
          snapshotJson: jsonEncode({
            'version': 1,
            'reason': 'source_missing',
            'legacySourceKind': 'pill_stock',
            'legacySourceId': '11111111-1111-4111-8111-111111111111',
            'sourceFingerprint': 'a' * 64,
            'observedBaseRevision': '7',
            'observedBaseStock': 4,
            'targetStock': 2,
            'privateCanary': 'must-not-be-returned',
          }),
        ),
      );

      expect(issue.kind, MigrationIssueKind.medication);
      expect(issue.canKeepServerState, isTrue);
      expect(issue.canApplySavedChange, isTrue);
      expect(issue.observedBaseStock, 4);
      expect(issue.savedTargetStock, 2);
      expect(issue.sourcePillId, '11111111-1111-4111-8111-111111111111');
      expect(issue.toString(), isNot(contains('must-not-be-returned')));
    },
  );

  test('malformed snapshots stay review-only and never enable replay', () {
    final issue = MigrationIssueSummary.fromRow(
      _issue(snapshotJson: '{"privateCanary":"must-not-render"}'),
    );

    expect(issue.canKeepServerState, isTrue);
    expect(issue.canApplySavedChange, isFalse);
    expect(issue.checkpointReason, isNull);
    expect(issue.toString(), isNot(contains('must-not-render')));
  });

  test('revision 2 cannot present stale resolution actions', () {
    final issue = MigrationIssueSummary.fromRow(
      _issue(
        revision: 2,
        resolutionState: 'resolved',
        resolvedAt: DateTime.utc(2026, 9, 1),
        snapshotJson: '{}',
      ),
    );

    expect(issue.canKeepServerState, isFalse);
    expect(issue.canApplySavedChange, isFalse);
  });

  test(
    'a proven synced schedule tombstone is historical and offers no repair action',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _seedTimezoneReview(
        f,
        suffix: 'retired-valid',
        deleted: true,
        syncStatus: 'synced',
      );

      expect(await isRetiredScheduleReview(f.db, issue), isTrue);
      final summaries = await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        [issue],
        medicationProjectionSettled: true,
        stableProjectionSettled: true,
      );
      expect(summaries, hasLength(1));
      expect(summaries.single.isHistoricalInformation, isTrue);
      expect(summaries.single.canRepairSchedule, isFalse);
      expect(
        (await f.db.migrationIssuesDao.getById(issue.id))!.resolutionState,
        'unresolved',
      );
      expect(
        (await f.db.schedulesDao.getById(issue.entityId))!.isDeleted,
        isTrue,
      );
    },
  );

  test(
    'schedule review identity, revision, live/pending row, and snapshot must agree',
    () async {
      final cases =
          <
            ({
              String label,
              bool deleted,
              String syncStatus,
              String? snapshotScheduleId,
              String? sourceScheduleRevision,
              String? snapshot,
            })
          >[
            (
              label: 'snapshot identity mismatch',
              deleted: true,
              syncStatus: 'synced',
              snapshotScheduleId: '10000000-0000-4000-8000-000000000099',
              sourceScheduleRevision: '1',
              snapshot: null,
            ),
            (
              label: 'source revision mismatch',
              deleted: true,
              syncStatus: 'synced',
              snapshotScheduleId: null,
              sourceScheduleRevision: '2',
              snapshot: null,
            ),
            (
              label: 'still live',
              deleted: false,
              syncStatus: 'synced',
              snapshotScheduleId: null,
              sourceScheduleRevision: '1',
              snapshot: null,
            ),
            (
              label: 'tombstone still pending sync',
              deleted: true,
              syncStatus: 'pending',
              snapshotScheduleId: null,
              sourceScheduleRevision: '1',
              snapshot: null,
            ),
            (
              label: 'snapshot missing required fields',
              deleted: true,
              syncStatus: 'synced',
              snapshotScheduleId: null,
              sourceScheduleRevision: null,
              snapshot: '{}',
            ),
            (
              label: 'snapshot is invalid JSON',
              deleted: true,
              syncStatus: 'synced',
              snapshotScheduleId: null,
              sourceScheduleRevision: null,
              snapshot: '{',
            ),
          ];

      for (final entry in cases) {
        final f = await CareRecordingFixture.create(connected: true);
        try {
          final issue = await _seedTimezoneReview(
            f,
            suffix: entry.label,
            deleted: entry.deleted,
            syncStatus: entry.syncStatus,
            snapshotScheduleId: entry.snapshotScheduleId,
            sourceScheduleRevision: entry.sourceScheduleRevision,
            snapshot: entry.snapshot,
          );
          expect(
            await isRetiredScheduleReview(f.db, issue),
            isFalse,
            reason: entry.label,
          );
          final summaries = await projectMigrationIssues(
            f.db,
            f.workspace.context.ownerUserId,
            [issue],
            medicationProjectionSettled: true,
            stableProjectionSettled: true,
          );
          expect(
            summaries.single.isHistoricalInformation,
            isFalse,
            reason: entry.label,
          );
          expect(
            summaries.single.canRepairSchedule,
            isTrue,
            reason: entry.label,
          );
        } finally {
          await f.db.close();
        }
      }
    },
  );

  test(
    'an unsettled stable schedule operation prevents tombstone classification',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _seedTimezoneReview(
        f,
        suffix: 'retired-pending-operation',
        deleted: true,
        syncStatus: 'synced',
      );
      await PendingOperationRepository(f.db).record(
        operation: PendingOperationDraft(
          userId: f.workspace.context.ownerUserId,
          operationType: 'schedule.update',
          entityType: 'schedule',
          entityLocalId: issue.entityId,
          payload: {
            'action': 'update',
            'data': {'minute': 15},
          },
        ),
        applyProjection: () async {},
      );

      expect(await isRetiredScheduleReview(f.db, issue), isFalse);
      final summary = (await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        [issue],
        medicationProjectionSettled: true,
        stableProjectionSettled: true,
      )).single;
      expect(summary.isHistoricalInformation, isFalse);
      expect(summary.canRepairSchedule, isTrue);
    },
  );

  test(
    'a mismatched owner chain cannot prove a retired schedule issue',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _seedTimezoneReview(
        f,
        suffix: 'retired-wrong-owner',
        deleted: true,
        syncStatus: 'synced',
      );
      const otherOwner = '10000000-0000-4000-8000-000000000099';
      await f.db
          .into(f.db.users)
          .insert(
            UsersCompanion.insert(
              id: otherOwner,
              email: 'fictional-other-owner@example.test',
              createdAt: DateTime.utc(2026, 10, 8),
              updatedAt: DateTime.utc(2026, 10, 8),
            ),
          );
      await (f.db.update(f.db.profiles)
            ..where((row) => row.id.equals(f.person.id)))
          .write(const ProfilesCompanion(userId: Value(otherOwner)));

      expect(await isRetiredScheduleReview(f.db, issue), isFalse);
    },
  );

  test(
    'a review whose routine this device cannot reach stops asking for review',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _seedUnreachableTimezoneReview(f);
      final schedulesBefore = await f.db.select(f.db.schedules).get();

      // A well-formed server review whose target is absent cannot be proven
      // retired, which is why it used to be offered as something to open.
      expect(await isRetiredScheduleReview(f.db, issue), isFalse);
      expect(
        await isMissingScheduleReview(
          f.db,
          issue,
          stableProjectionSettled: true,
        ),
        isTrue,
      );
      expect(
        await scheduleReviewTarget(
          f.db,
          issue.entityId,
          f.workspace.context.ownerUserId,
        ),
        isNull,
        reason: 'the repair sheet must refuse exactly what the list hides',
      );

      final summary = (await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        [issue],
        medicationProjectionSettled: true,
        stableProjectionSettled: true,
      )).single;
      expect(summary.isHistoricalInformation, isTrue);
      expect(summary.canRepairSchedule, isFalse);
      expect(summary.asksForReview, isFalse);
      expect(await f.db.migrationIssuesDao.getById(issue.id), issue);
      expect(await f.db.select(f.db.schedules).get(), schedulesBefore);
    },
  );

  test(
    'an unsettled stable operation keeps an absent routine review answerable',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _seedUnreachableTimezoneReview(f);
      await PendingOperationRepository(f.db).record(
        operation: PendingOperationDraft(
          userId: f.workspace.context.ownerUserId,
          component: 'stable',
          operationType: 'schedule.create',
          entityType: 'schedule',
          entityLocalId: issue.entityId,
          payload: const {'action': 'create'},
        ),
        applyProjection: () async {},
      );

      // The routine may simply not have landed yet, so absence proves nothing.
      expect(
        await isMissingScheduleReview(
          f.db,
          issue,
          stableProjectionSettled: false,
        ),
        isFalse,
      );
      final summary = (await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        [issue],
        medicationProjectionSettled: true,
        stableProjectionSettled: false,
      )).single;
      expect(summary.isHistoricalInformation, isFalse);
      expect(summary.canRepairSchedule, isTrue);
    },
  );

  test(
    'exact server review coalesces linked local dose uncertainty without changing evidence',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final evidence = await _seedReviewEvidence(f, 'exact');
      final rows = await f.db.select(f.db.migrationIssues).get();
      final summaries = await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        rows,
        medicationProjectionSettled: false,
        stableProjectionSettled: false,
      );

      expect(summaries, hasLength(1));
      final summary = summaries.single;
      expect(summary.id, evidence.issueId);
      expect(summary.canKeepServerState, isTrue);
      expect(summary.localDose, isNotNull);
      expect(summary.localDose!.medicationName, f.pill.name);
      expect(summary.localDose!.scheduledAt.toUtc(), evidence.scheduledAt);
      expect(summary.localDose!.localState, 'taken');

      expect(
        (await f.db.migrationIssuesDao.getById(
          evidence.localIssueId,
        ))!.resolutionState,
        'unresolved',
        reason: 'coalescing is a display projection, not evidence deletion',
      );
      expect(
        (await f.db.pendingOperationsDao.getById(evidence.operation.id))!.state,
        'blocked',
      );
      final retainedEffect = (await f.db.pendingOperationsDao.getEffects(
        evidence.operation.id,
      )).single;
      expect(retainedEffect.state, 'uncertain');
      expect(retainedEffect.requestFingerprint, evidence.fingerprint);
      expect(
        retainedEffect.safeResultFingerprint,
        'reconciliation-recorded:${evidence.issueId}',
      );
      expect(await f.db.select(f.db.migrationIssues).get(), hasLength(2));
    },
  );

  test(
    'mismatched marker or wrong-owner issue leaves local uncertainty visible',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      await f.db
          .into(f.db.users)
          .insert(
            UsersCompanion.insert(
              id: '10000000-0000-4000-8000-000000000099',
              email: 'fictional-other-owner@example.test',
              createdAt: DateTime.utc(2026, 10, 8),
              updatedAt: DateTime.utc(2026, 10, 8),
            ),
          );

      final mismatched = await _seedReviewEvidence(
        f,
        'mismatched-marker',
        markerMatches: false,
      );
      final wrongOwner = await _seedReviewEvidence(
        f,
        'wrong-owner',
        issueOwnerId: '10000000-0000-4000-8000-000000000099',
      );
      final substitutedCommand = await _seedReviewEvidence(
        f,
        'substituted-command',
        issueCommandMatches: false,
      );
      final rows = await f.db.select(f.db.migrationIssues).get();
      final summaries = await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        rows,
        medicationProjectionSettled: false,
        stableProjectionSettled: false,
      );

      final visibleIds = summaries.map((summary) => summary.id).toSet();
      expect(visibleIds, contains(mismatched.localIssueId));
      expect(visibleIds, contains(mismatched.issueId));
      expect(visibleIds, contains(wrongOwner.localIssueId));
      expect(visibleIds, isNot(contains(wrongOwner.issueId)));
      expect(visibleIds, contains(substitutedCommand.localIssueId));
      expect(await f.db.select(f.db.migrationIssues).get(), hasLength(6));
    },
  );
}

/// A server review whose routine this device holds no row for, with a snapshot
/// that passes every retirement check so only the missing row distinguishes it.
Future<MigrationIssue> _seedUnreachableTimezoneReview(
  CareRecordingFixture f,
) async {
  const entityId = '10000000-0000-4000-8000-000000000077';
  expect(await f.db.schedulesDao.getByMappedOrLocalId(entityId), isNull);
  final issueId = projectionCommandIdForKey('unreachable-schedule-review');
  final now = DateTime.utc(2026, 10, 8, 10);
  await f.db.migrationIssuesDao.record(
    MigrationIssuesCompanion.insert(
      id: issueId,
      userId: f.workspace.context.ownerUserId,
      entityType: 'schedules',
      entityId: entityId,
      issueCode: 'schedule_timezone_review_required',
      snapshotJson: jsonEncode({
        'scheduleId': entityId,
        'sourceScheduleRevision': '1',
        'frequency': 'daily',
        'frequencyDays': null,
        'isActive': true,
        'deletedAt': now.toIso8601String(),
        'timeZoneStatus': 'legacy_unknown',
        'timeZone': null,
      }),
      serverId: Value(issueId),
      revision: const Value(1),
      resolutionState: const Value('unresolved'),
      createdAt: now,
      updatedAt: now,
    ),
  );
  return (await f.db.migrationIssuesDao.getById(issueId))!;
}

Future<MigrationIssue> _seedTimezoneReview(
  CareRecordingFixture f, {
  required String suffix,
  required bool deleted,
  required String syncStatus,
  String? snapshotScheduleId,
  String? sourceScheduleRevision,
  String? snapshot,
}) async {
  final schedule = (await f.db.schedulesDao.getById(f.occurrence.scheduleId!))!;
  await (f.db.update(
    f.db.schedules,
  )..where((row) => row.id.equals(schedule.id))).write(
    SchedulesCompanion(
      serverId: Value(schedule.id),
      revision: const Value(1),
      syncStatus: Value(syncStatus),
      isDeleted: Value(deleted),
      timeZoneStatus: const Value('legacy_unknown'),
    ),
  );
  final issueId = projectionCommandIdForKey('retired-schedule-review:$suffix');
  final now = DateTime.utc(2026, 10, 8, 10);
  final snapshotJson =
      snapshot ??
      jsonEncode({
        'scheduleId': snapshotScheduleId ?? schedule.id,
        'sourceScheduleRevision': sourceScheduleRevision ?? '1',
        'frequency': schedule.frequency,
        'frequencyDays': null,
        'isActive': schedule.isActive,
        'deletedAt': deleted ? now.toIso8601String() : null,
        'timeZoneStatus': 'legacy_unknown',
        'timeZone': null,
      });
  await f.db.migrationIssuesDao.record(
    MigrationIssuesCompanion.insert(
      id: issueId,
      userId: f.workspace.context.ownerUserId,
      entityType: 'schedules',
      entityId: schedule.id,
      issueCode: 'schedule_timezone_review_required',
      snapshotJson: snapshotJson,
      serverId: Value(issueId),
      revision: const Value(1),
      resolutionState: const Value('unresolved'),
      createdAt: now,
      updatedAt: now,
    ),
  );
  return (await f.db.migrationIssuesDao.getById(issueId))!;
}

Future<
  ({
    String issueId,
    String localIssueId,
    String fingerprint,
    DateTime scheduledAt,
    PendingOperation operation,
  })
>
_seedReviewEvidence(
  CareRecordingFixture f,
  String suffix, {
  bool markerMatches = true,
  bool issueCommandMatches = true,
  String? issueOwnerId,
}) async {
  final mutationId = projectionCommandIdForKey('review-operation:$suffix');
  final doseId = projectionCommandIdForKey('review-dose:$suffix');
  final issueId = projectionCommandIdForKey(
    'legacy-split-issue-v1:$mutationId:0',
  );
  final expectedEntityId = projectionCommandIdForKey(
    'legacy-split-command-v1:$mutationId:0',
  );
  final fingerprint = 'fictional-request-fingerprint-$suffix';
  final scheduledAt = DateTime.utc(2026, 10, 8, 8, 30);
  await f.db.doseLogsDao.upsert(
    DoseLogsCompanion.insert(
      id: doseId,
      scheduleId: f.occurrence.scheduleId!,
      scheduledAt: scheduledAt,
      status: 'taken',
      takenAt: Value(scheduledAt),
      createdAt: scheduledAt,
      updatedAt: scheduledAt,
    ),
  );
  final recorded = await PendingOperationRepository(f.db).record(
    operation: PendingOperationDraft(
      userId: f.workspace.context.ownerUserId,
      mutationId: mutationId,
      component: 'medication',
      operationType: 'legacy.dose',
      entityType: 'doseLog',
      entityLocalId: doseId,
      payload: {
        'command': {'commandId': mutationId},
      },
      effects: [
        PendingOperationEffectDraft(
          kind: 'dose',
          legacySourceId: doseId,
          requestFingerprint: fingerprint,
        ),
      ],
    ),
    applyProjection: () async {},
  );
  final operation = (await f.db.pendingOperationsDao.getById(
    recorded.operationId,
  ))!;
  final effect = (await f.db.pendingOperationsDao.getEffects(
    operation.id,
  )).single;
  final markerIssueId = markerMatches
      ? issueId
      : projectionCommandIdForKey('unrelated-review:$suffix');
  final now = DateTime.utc(2026, 10, 8, 9);
  await f.db.transaction(() async {
    await (f.db.update(f.db.pendingOperations)
          ..where((row) => row.id.equals(operation.id)))
        .write(const PendingOperationsCompanion(state: Value('blocked')));
    await (f.db.update(
      f.db.pendingOperationEffects,
    )..where((row) => row.id.equals(effect.id))).write(
      PendingOperationEffectsCompanion(
        state: const Value('uncertain'),
        attemptedAt: Value(now),
        safeResultFingerprint: Value('reconciliation-recorded:$markerIssueId'),
      ),
    );
    await f.db.migrationIssuesDao.record(
      MigrationIssuesCompanion.insert(
        id: issueId,
        userId: issueOwnerId ?? f.workspace.context.ownerUserId,
        entityType: 'medication_split',
        entityId: issueCommandMatches
            ? expectedEntityId
            : projectionCommandIdForKey('unrelated-command:$suffix'),
        issueCode: 'legacy_split_checkpoint',
        snapshotJson: '{"version":1,"reason":"evidence_ambiguous"}',
        serverId: Value(issueId),
        revision: const Value(1),
        resolutionState: const Value('unresolved'),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await f.db.migrationIssuesDao.record(
      MigrationIssuesCompanion.insert(
        id: 'local-uncertainty-$suffix',
        userId: f.workspace.context.ownerUserId,
        entityType: 'dose_log',
        entityId: doseId,
        issueCode: 'legacy_delivery_uncertain',
        snapshotJson: fingerprint,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });
  return (
    issueId: issueId,
    localIssueId: 'local-uncertainty-$suffix',
    fingerprint: fingerprint,
    scheduledAt: scheduledAt,
    operation: operation,
  );
}

MigrationIssue _issue({
  int revision = 1,
  String resolutionState = 'unresolved',
  DateTime? resolvedAt,
  required String snapshotJson,
}) => MigrationIssue(
  id: '22222222-2222-4222-8222-222222222222',
  userId: '33333333-3333-4333-8333-333333333333',
  entityType: 'medication_split',
  entityId: '44444444-4444-4444-8444-444444444444',
  issueCode: 'legacy_split_checkpoint',
  snapshotJson: snapshotJson,
  serverId: '22222222-2222-4222-8222-222222222222',
  revision: revision,
  resolutionState: resolutionState,
  resolvedByUserId: resolvedAt == null
      ? null
      : '33333333-3333-4333-8333-333333333333',
  resolvedAt: resolvedAt,
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: resolvedAt ?? DateTime.utc(2026, 9, 1),
);
