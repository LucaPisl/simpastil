import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

CareSharingStatusRepository _reader(CareRecordingFixture f) =>
    CareSharingStatusRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test('local care never inherits global connected sync success', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    await f.workspace.preferences.setString(
      'last_sync_at',
      '2026-10-01T11:00:00Z',
    );
    final status = await _reader(f).load();
    expect(status.isLocalOnly, isTrue);
    expect(status.lastCarePullAt, isNull);
    expect(status.pendingCount, 0);
    expect(status.needsReviewCount, 0);
    expect(status.uncertainCount, 0);
  });

  test(
    'freshness requires completed care evidence for every current person in this workspace',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final now = DateTime.utc(2026, 10, 1, 11);
      await f.workspace.preferences.setString(
        'last_sync_at',
        now.toIso8601String(),
      );
      await f.db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: f.workspace.context.ownerUserId,
          component: 'medication',
          contractVersion: 2,
          lastFullSuccessAt: Value(now),
        ),
      );
      expect(
        (await _reader(f).load()).lastCarePullAt,
        isNull,
        reason: 'A global or push-success timestamp is not a care pull',
      );
      await f.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'fictional-freshness-person',
          userId: f.workspace.context.ownerUserId,
          name: 'Fictional second person',
          createdAt: now,
          updatedAt: now,
        ),
      );
      Future<void> checkpoint(String person, DateTime at, String workspace) => f
          .db
          .into(f.db.workspaceSyncCheckpoints)
          .insertOnConflictUpdate(
            WorkspaceSyncCheckpointsCompanion.insert(
              workspaceId: workspace,
              profileId: person,
              channel: 'carePull',
              cursor: '',
              completedAt: at,
            ),
          );
      await checkpoint(f.person.id, now, f.workspace.context.workspaceId);
      final localWorkspace = await f.workspace.access.workspaces.ensureLocal();
      await checkpoint('fictional-freshness-person', now, localWorkspace.id);
      expect(
        (await _reader(f).load()).lastCarePullAt,
        isNull,
        reason: 'A different workspace cannot complete this care collection',
      );
      await checkpoint(
        'fictional-freshness-person',
        DateTime.utc(2026, 10, 1, 10),
        f.workspace.context.workspaceId,
      );
      expect(
        (await _reader(f).load()).lastCarePullAt!.toUtc(),
        DateTime.utc(2026, 10, 1, 10),
      );
    },
  );

  test(
    'pending, review and uncertain outcomes stay separate after durable care',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final saved = await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      expect((await _reader(f).load()).pendingCount, 3);
      final operation = (await f.db.pendingOperationsDao.getByMutationId(
        f.workspace.context.ownerUserId,
        saved.event.commandId,
      ))!;
      await (f.db.update(f.db.pendingOperations)
            ..where((p) => p.id.equals(operation.id)))
          .write(const PendingOperationsCompanion(state: Value('conflict')));
      final stable = (await f.db.pendingOperationsDao.getForUser(
        f.workspace.context.ownerUserId,
      )).firstWhere((p) => p.component == 'stable');
      await (f.db.update(f.db.pendingOperations)
            ..where((p) => p.id.equals(stable.id)))
          .write(const PendingOperationsCompanion(state: Value('blocked')));
      final status = await _reader(f).load();
      expect(status.isLocalOnly, isFalse);
      expect(status.pendingCount, 1);
      expect(status.needsReviewCount, 1);
      expect(status.uncertainCount, 1);
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'taken',
      );
    },
  );

  test('stock held for the ledger is not counted as sharing work', () async {
    final f = await CareRecordingFixture.create(connected: true);
    addTearDown(f.db.close);
    final owner = f.workspace.context.ownerUserId;
    final base = (await f.db.pendingOperationsDao.getForUser(owner)).length;
    await f.db
        .into(f.db.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            id: 'fictional-held-stock',
            userId: owner,
            mutationId: 'm-fictional-held-stock',
            component: 'medication',
            operationType: 'medication.command',
            contractVersion: 2,
            payloadJson:
                '{"inventoryCommand":{"commandId":"c","pillId":"p"},'
                '"localProjection":{"pillId":"p"}}',
            createdAt: DateTime.utc(2026, 10, 14, 8),
          ),
        );
    SharedPreferences.setMockInitialValues({LedgerModeHint.key: true});
    final active = await _reader(f).load();
    SharedPreferences.setMockInitialValues({LedgerModeHint.key: false});
    final bridge = await _reader(f).load();
    expect(
      active.pendingCount - bridge.pendingCount,
      1,
      reason: 'ledger on: counted; bridge mode: held, not waiting ($base)',
    );
  });

  test('sharing watch refuses revoked authority', () async {
    final f = await CareRecordingFixture.create(connected: true);
    addTearDown(f.db.close);
    final iterator = StreamIterator(_reader(f).watch());
    addTearDown(iterator.cancel);
    expect(await iterator.moveNext(), isTrue);
    await f.workspace.access.revokeNetwork();
    await expectLater(
      iterator.moveNext(),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
  });
}
