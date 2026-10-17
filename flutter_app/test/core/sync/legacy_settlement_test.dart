import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/sync/component_sync_pull_adapter.dart';
import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import '../../helpers/protected_workspace_fixture.dart';

class _Dio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (metadata, extraEffect) in [
    (true, false),
    (false, false),
    (true, true),
  ]) {
    test(
      'authenticated resolved issue ${metadata ? 'settles exact effect' : 'without disposition retains uncertainty'} without acknowledging old delivery (remaining effect: $extraEffect)',
      () async {
        final f = await ProtectedWorkspaceFixture.create(
          ownerId: '10000000-0000-4000-8000-000000000001',
        );
        addTearDown(f.db.close);
        const mutation = '10000000-0000-4000-8000-000000000021';
        const source = '10000000-0000-4000-8000-000000000022';
        const resolution = '10000000-0000-4000-8000-000000000023';
        const snapshot = '{"fictional":"original uncertain care"}';
        final date = DateTime.utc(2026, 10, 6, 10);
        const profile = '10000000-0000-4000-8000-000000000031';
        const pill = '10000000-0000-4000-8000-000000000032';
        const schedule = '10000000-0000-4000-8000-000000000033';
        await f.db.profilesDao.upsert(
          ProfilesCompanion.insert(
            id: profile,
            userId: f.context.ownerUserId,
            name: 'Fictional person',
            createdAt: date,
            updatedAt: date,
            serverId: const Value(profile),
            syncStatus: const Value('synced'),
          ),
        );
        await f.db.pillsDao.upsert(
          PillsCompanion.insert(
            id: pill,
            profileId: profile,
            name: 'Fictional medication',
            createdAt: date,
            updatedAt: date,
            serverId: const Value(pill),
            syncStatus: const Value('synced'),
          ),
        );
        await f.db.schedulesDao.upsert(
          SchedulesCompanion.insert(
            id: schedule,
            pillId: pill,
            hour: 13,
            minute: 0,
            frequency: 'daily',
            createdAt: date,
            updatedAt: date,
            serverId: const Value(schedule),
            syncStatus: const Value('synced'),
          ),
        );
        await f.db.doseLogsDao.upsert(
          DoseLogsCompanion.insert(
            id: source,
            scheduleId: schedule,
            scheduledAt: date,
            status: 'taken',
            takenAt: Value(date),
            createdAt: date,
            updatedAt: date,
            serverId: const Value(source),
            note: const Value('original saved evidence'),
          ),
        );
        final recorded = await PendingOperationRepository(f.db).record(
          operation: PendingOperationDraft(
            userId: '10000000-0000-4000-8000-000000000001',
            mutationId: mutation,
            component: 'medication',
            operationType: 'legacy.dose',
            entityType: 'doseLog',
            entityLocalId: source,
            payload: {'fictional': 'original uncertain care'},
            effects: [
              const PendingOperationEffectDraft(
                kind: 'dose',
                legacySourceId: source,
                requestFingerprint: snapshot,
              ),
              if (extraEffect)
                const PendingOperationEffectDraft(
                  kind: 'inventory',
                  legacySourceId: source,
                  requestFingerprint: 'fictional-unresolved-stock',
                ),
            ],
          ),
          applyProjection: () async {},
        );
        final effect = (await f.db.pendingOperationsDao.getEffects(
          recorded.operationId,
        )).first;
        final issueId = projectionCommandIdForKey(
          'legacy-split-issue-v1:$mutation:0',
        );
        final now = DateTime.utc(2026, 10, 6);
        await (f.db.update(f.db.pendingOperations)
              ..where((p) => p.id.equals(recorded.operationId)))
            .write(const PendingOperationsCompanion(state: Value('blocked')));
        await (f.db.update(
          f.db.pendingOperationEffects,
        )..where((e) => e.id.equals(effect.id))).write(
          PendingOperationEffectsCompanion(
            state: const Value('uncertain'),
            attemptedAt: Value(now),
            safeResultFingerprint: Value('reconciliation-recorded:$issueId'),
          ),
        );
        await f.db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: 'original-local-issue',
            userId: f.context.ownerUserId,
            entityType: 'doseLog',
            entityId: source,
            issueCode: 'legacy_delivery_uncertain',
            snapshotJson: snapshot,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await f.db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: 'unrelated-original-issue',
            userId: f.context.ownerUserId,
            entityType: 'doseLog',
            entityId: source,
            issueCode: 'legacy_delivery_uncertain',
            snapshotJson: 'different exact request',
            createdAt: now,
            updatedAt: now,
          ),
        );
        final c = f.context;
        final scope = SyncWriteScope(
          access: f.access,
          capability: NetworkCapability(
            ownerId: c.ownerUserId,
            endpoint: c.endpoint!,
            epoch: c.networkEpoch!,
            generation: c.sessionGeneration!,
          ),
        );
        final merger = ComponentSyncMerger(f.db, writeScope: scope);
        final change = {
          'component': 'account',
          'entityType': 'migration_issue',
          'entityId': issueId,
          'payload': {
            'kind': 'migrationIssue',
            'id': issueId,
            'entityType': 'medication_split',
            'entityId': source,
            'issueCode': 'legacy_split_checkpoint',
            'state': 'resolved',
            'revision': '2',
            'createdAt': now.toIso8601String(),
            'resolvedAt': now.toIso8601String(),
            'safeSnapshot': {
              'version': 1,
              'reason': 'evidence_ambiguous',
              if (metadata)
                'settlement': {
                  'version': 1,
                  'commandId': resolution,
                  'resolution': 'keep_server_state',
                  'disposition': 'kept_server_state',
                  'issueId': issueId,
                },
            },
          },
        };
        // An older client already stored the acknowledgement and advanced its
        // account cursor, but did not project a settlement because of its typo.
        await ComponentSyncMerger(
          f.db,
        ).merge(c.ownerUserId, SyncComponent.account, [change]);
        await f.db.syncStateDao.saveState(
          SyncComponentStatesCompanion.insert(
            userId: c.ownerUserId,
            component: 'account',
            contractVersion: 2,
            lastCompletedCursor: const Value('10'),
            lastFullSuccessAt: Value(DateTime.now().toUtc()),
          ),
        );
        expect(await f.db.select(f.db.effectSettlements).get(), isEmpty);
        final dio = _Dio();
        final afterSequences = <Object?>[];
        when(
          () => dio.get<Map<String, dynamic>>(
            any(),
            queryParameters: any(named: 'queryParameters'),
          ),
        ).thenAnswer((invocation) async {
          final query = invocation.namedArguments[#queryParameters] as Map;
          final after = query['afterSequence'];
          afterSequences.add(after);
          return Response(
            requestOptions: RequestOptions(path: '/sync/account'),
            data: {
              'component': 'account',
              'contractVersion': 2,
              'afterSequence': after ?? '0',
              'throughSequence': '10',
              'items': after == null
                  ? [
                      {'serverSequence': '10', 'change': change},
                    ]
                  : [],
              'hasMore': false,
              'nextCursor': null,
            },
          );
        });
        final adapter = ComponentSyncPullAdapter(
          db: f.db,
          dio: dio,
          writeScope: scope,
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          await adapter.pull(
            userId: c.ownerUserId,
            component: SyncComponent.account,
            contractVersion: 2,
            projectionRevision: accountSettlementProjectionRevision,
            merge: (component, changes) =>
                merger.merge(c.ownerUserId, component, changes),
          );
        }
        expect(afterSequences, [null, '10']);
        expect(
          await f.db.select(f.db.effectSettlements).get(),
          hasLength(metadata ? 1 : 0),
        );
        final retained = (await f.db.pendingOperationsDao.getEffects(
          recorded.operationId,
        )).first;
        expect(retained.state, 'uncertain');
        expect(retained.acknowledgedAt, isNull);
        expect(retained.requestFingerprint, snapshot);
        expect(
          (await f.db.pendingOperationsDao.getById(
            recorded.operationId,
          ))!.state,
          'blocked',
        );
        expect(
          (await f.db.migrationIssuesDao.getById(
            'original-local-issue',
          ))!.resolutionState,
          metadata ? 'resolved' : 'unresolved',
        );
        expect(
          (await CareSharingStatusRepository(
            database: f.db,
            access: f.access,
            context: c,
          ).load()).uncertainCount,
          metadata && !extraEffect ? 0 : 1,
        );
        expect(
          (await f.db.migrationIssuesDao.getById(
            'unrelated-original-issue',
          ))!.resolutionState,
          'unresolved',
        );
        final operation = (await f.db.pendingOperationsDao.getById(
          recorded.operationId,
        ))!;
        expect(
          await f.db.pendingOperationsDao.isSettled(
            operation,
            workspaceId: 'another-workspace',
          ),
          isFalse,
        );
        if (metadata) {
          final payload = Map<String, dynamic>.from(change['payload'] as Map);
          final safeSnapshot = Map<String, dynamic>.from(
            payload['safeSnapshot'] as Map,
          );
          final disposition = Map<String, dynamic>.from(
            safeSnapshot['settlement'] as Map,
          );
          disposition['commandId'] = '10000000-0000-4000-8000-000000000024';
          safeSnapshot['settlement'] = disposition;
          payload['safeSnapshot'] = safeSnapshot;
          await expectLater(
            scope.write(
              () => merger.merge(c.ownerUserId, SyncComponent.account, [
                {'component': 'account', 'payload': payload},
              ]),
            ),
            throwsFormatException,
          );
          expect(
            (await f.db.select(f.db.effectSettlements).get())
                .single
                .resolutionCommandId,
            resolution,
          );
        }
        final bridge = {
          'component': 'medicationBridge',
          'payload': {
            'kind': 'bridgeDose',
            'id': source,
            'scheduleId': schedule,
            'scheduledAt': date.toIso8601String(),
            'takenAt': null,
            'status': 'skipped',
            'sourceRevision': '2',
            'deletedAt': null,
          },
        };
        await scope.write(
          () => merger.merge(c.ownerUserId, SyncComponent.medicationBridge, [
            bridge,
          ], contractVersion: 1),
        );
        final projected = (await f.db.doseLogsDao.getById(source))!;
        expect(
          projected.status,
          metadata && !extraEffect ? 'skipped' : 'taken',
        );
        expect(
          projected.syncStatus,
          metadata && !extraEffect ? 'synced' : 'pending',
        );
        expect(projected.note, 'original saved evidence');
        if (metadata && !extraEffect) {
          await PendingOperationRepository(f.db).record(
            operation: const PendingOperationDraft(
              userId: '10000000-0000-4000-8000-000000000001',
              mutationId: '10000000-0000-4000-8000-000000000041',
              component: 'medication',
              operationType: 'legacy.dose',
              entityType: 'doseLog',
              entityLocalId: source,
              payload: {'newer': 'fictional pending care'},
              effects: [
                PendingOperationEffectDraft(
                  kind: 'dose',
                  legacySourceId: source,
                  requestFingerprint: 'newer fictional care',
                ),
              ],
            ),
            applyProjection: () async {
              await (f.db.update(
                f.db.doseLogs,
              )..where((d) => d.id.equals(source))).write(
                const DoseLogsCompanion(
                  status: Value('taken'),
                  syncStatus: Value('pending'),
                ),
              );
            },
          );
          await scope.write(
            () => merger.merge(c.ownerUserId, SyncComponent.medicationBridge, [
              bridge,
            ], contractVersion: 1),
          );
          expect((await f.db.doseLogsDao.getById(source))!.status, 'taken');
        }
        expect(
          (await f.db.pendingOperationsDao.getReady(
            c.ownerUserId,
          )).where((op) => op.id == recorded.operationId),
          isEmpty,
        );
        expect(
          jsonDecode(
            (await f.db.pendingOperationsDao.getById(
              recorded.operationId,
            ))!.payloadJson,
          )['fictional'],
          'original uncertain care',
        );
      },
    );
  }
}
