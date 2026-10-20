import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simpastil/core/sync/retired_stock_review.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';

import '../../helpers/care_recording_fixture.dart';

const _serverPill = '20000000-0000-4000-8000-000000000001';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'received retired stock notice becomes information without changing care',
    () async {
      final f = await CareRecordingFixture.create(
        connected: true,
        legacyStock: 17,
      );
      addTearDown(f.db.close);
      final issue = await _receiveRetiredStock(f);
      final pillBefore = await f.db.pillsDao.getById(f.pill.id);
      final operationsBefore = await f.db.select(f.db.pendingOperations).get();
      final eventsBefore = await f.db.select(f.db.occurrenceEvents).get();
      final summaries = await projectMigrationIssues(
        f.db,
        f.workspace.context.ownerUserId,
        [issue],
        medicationProjectionSettled: true,
        stableProjectionSettled: true,
      );
      expect(summaries.single.isHistoricalInformation, isTrue);
      expect(await f.db.migrationIssuesDao.getById(issue.id), issue);
      expect(await f.db.pillsDao.getById(f.pill.id), pillBefore);
      expect(await f.db.select(f.db.pendingOperations).get(), operationsBefore);
      expect(await f.db.select(f.db.occurrenceEvents).get(), eventsBefore);
    },
  );
  test('ambiguous identity and unproven metadata remain actionable', () async {
    final f = await CareRecordingFixture.create(connected: true);
    addTearDown(f.db.close);
    final issue = await _receiveRetiredStock(f);
    for (final invalid in [
      issue.copyWith(id: 'unrelated'),
      issue.copyWith(serverId: const Value('server-review')),
      issue.copyWith(revision: 2),
      issue.copyWith(resolutionState: 'resolved'),
      issue.copyWith(snapshotJson: '{}'),
      issue.copyWith(snapshotJson: '{'),
      issue.copyWith(
        snapshotJson: jsonEncode({
          ...jsonDecode(issue.snapshotJson) as Map<String, dynamic>,
          'pendingIntent': true,
        }),
      ),
    ]) {
      expect(await isRetiredStockReview(f.db, invalid), isFalse);
    }
    for (final fields in [
      const PillsCompanion(isDeleted: Value(false)),
      const PillsCompanion(syncStatus: Value('pending')),
      const PillsCompanion(revision: Value(0)),
      const PillsCompanion(serverId: Value(null)),
    ]) {
      await (f.db.update(
        f.db.pills,
      )..where((p) => p.id.equals(f.pill.id))).write(fields);
      expect(await isRetiredStockReview(f.db, issue), isFalse);
      await _receiveRetiredStock(f);
    }
    await (f.db.update(f.db.profiles)..where((p) => p.id.equals(f.person.id)))
        .write(const ProfilesCompanion(userId: Value('different-owner')));
    expect(await isRetiredStockReview(f.db, issue), isFalse);
    await (f.db.update(f.db.profiles)..where((p) => p.id.equals(f.person.id)))
        .write(ProfilesCompanion(userId: Value(issue.userId)));
    // A different row's local id collides with the original server alias.
    final pill = (await f.db.pillsDao.getById(f.pill.id))!;
    await f.db
        .into(f.db.pills)
        .insert(
          pill
              .copyWith(id: _serverPill, serverId: const Value(null))
              .toCompanion(false),
        );
    expect(await isRetiredStockReview(f.db, issue), isFalse);
  });

  test(
    'live projection restores review on revival and unsettled intent',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _receiveRetiredStock(f);
      final container = ProviderContainer(
        overrides: [
          ...f.workspace.overrides,
          workspaceContextProvider.overrideWith(
            (ref) => Stream.value(f.workspace.context),
          ),
        ],
      );
      addTearDown(container.dispose);
      final updates = StreamController<List<MigrationIssueSummary>>();
      final subscription = container.listen(migrationIssuesProvider, (
        _,
        value,
      ) {
        final data = value.value;
        if (value.hasError) updates.addError(value.error!, value.stackTrace!);
        if (data != null) updates.add(data);
      }, fireImmediately: true);
      addTearDown(subscription.close);
      addTearDown(updates.close);
      final iterator = StreamIterator(updates.stream);
      addTearDown(iterator.cancel);
      Future<void> expectInformation(bool expected) async {
        Future<void> deadline() async {
          while (await iterator.moveNext()) {
            if (iterator.current.single.isHistoricalInformation == expected) {
              return;
            }
          }
          fail('Projection stream ended before the expected classification');
        }

        await deadline().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('Expected information=$expected'),
        );
      }

      await expectInformation(true);
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(isDeleted: Value(false)));
      await expectInformation(false);
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(isDeleted: Value(true)));
      await expectInformation(true);
      final recorded = await PendingOperationRepository(f.db).record(
        operation: PendingOperationDraft(
          userId: issue.userId,
          operationType: 'unknown.intent',
          entityType: 'unknown',
          entityLocalId: 'unrelated',
          payload: const {},
        ),
        applyProjection: () async {},
      );
      await expectInformation(false);
      expect(await f.db.migrationIssuesDao.getById(issue.id), issue);
      expect(
        (await f.db.pendingOperationsDao.getById(recorded.operationId))!.state,
        isNot('committed'),
      );
    },
  );

  test(
    'only matching server settlement permits retained stock information',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final issue = await _receiveRetiredStock(f);
      final recorded = await PendingOperationRepository(f.db).record(
        operation: PendingOperationDraft(
          userId: issue.userId,
          component: 'medication',
          operationType: 'legacy.stock',
          entityType: 'pill',
          entityLocalId: f.pill.id,
          payload: const {},
          effects: const [
            PendingOperationEffectDraft(
              kind: 'inventory',
              requestFingerprint: 'fictional-fingerprint',
            ),
          ],
        ),
        applyProjection: () async {},
      );
      final effect = (await f.db.pendingOperationsDao.getEffects(
        recorded.operationId,
      )).single;
      expect(await isRetiredStockReview(f.db, issue), isFalse);
      await f.db
          .into(f.db.effectSettlements)
          .insert(
            EffectSettlementsCompanion.insert(
              effectId: effect.id,
              workspaceId: f.workspace.context.workspaceId,
              userId: issue.userId,
              issueId: 'fictional-server-review',
              resolutionCommandId: 'fictional-resolution',
              resolution: 'keep_server_state',
              disposition: 'kept_server_state',
              requestFingerprint: 'mismatch',
              resolvedAt: DateTime.utc(2026, 10, 9),
            ),
          );
      expect(await isRetiredStockReview(f.db, issue), isFalse);
      await f.db
          .update(f.db.effectSettlements)
          .write(
            EffectSettlementsCompanion(
              requestFingerprint: Value(effect.requestFingerprint),
            ),
          );
      expect(await isRetiredStockReview(f.db, issue), isTrue);
      expect(
        (await f.db.pendingOperationsDao.getById(recorded.operationId))!.state,
        isNot('committed'),
        reason: 'Classification must not rewrite queue evidence',
      );
    },
  );
}

Future<MigrationIssue> _receiveRetiredStock(CareRecordingFixture f) async {
  // Synthetic setup mutations have already been acknowledged by this server.
  await f.db
      .update(f.db.pendingOperations)
      .write(const PendingOperationsCompanion(state: Value('committed')));
  await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
    const PillsCompanion(
      serverId: Value(_serverPill),
      revision: Value(1),
      isDeleted: Value(true),
      syncStatus: Value('synced'),
    ),
  );
  await ComponentSyncMerger(f.db).merge(
    f.workspace.context.ownerUserId,
    SyncComponent.medicationBridge,
    [
      {
        'component': 'medicationBridge',
        'payload': <String, dynamic>{
          'kind': 'tombstone',
          'entityType': 'bridge_stock',
          'id': _serverPill,
          'revision': '1',
          'deletedAt': '2026-10-07T00:00:00Z',
        },
      },
    ],
  );
  return (await f.db.select(f.db.migrationIssues).get()).single;
}
