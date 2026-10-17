import 'package:dio/dio.dart';
import 'package:simpastil/core/sync/adapters/pills_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000001';
const _otherOwnerId = '10000000-0000-4000-8000-000000000002';
final _createdAt = DateTime.utc(2026, 10, 7, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'validated frozen repair crosses only its exactly settled inventory dependency',
    () async {
      final f = await _workspace();
      addTearDown(f.db.close);
      final parent = await _inventoryParent(f, 'repair');
      const pillServer = '10000000-0000-4000-8000-000000000010';
      const scheduleServer = '10000000-0000-4000-8000-000000000011';
      const mutation = '10000000-0000-4000-8000-000000000012';
      await f.db.pillsDao.markSynced(parent.pillId, pillServer, revision: 1);
      await f.db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: 'repair-schedule',
          pillId: parent.pillId,
          hour: 8,
          minute: 0,
          frequency: 'daily',
          createdAt: _createdAt,
          updatedAt: _createdAt,
          serverId: const Value(scheduleServer),
        ),
      );
      final recorded =
          await PendingOperationRepository(
            f.db,
            access: f.access,
            context: f.context,
          ).record(
            operation: PendingOperationDraft(
              userId: _ownerId,
              operationType: 'schedule.repair',
              entityType: 'schedule',
              entityLocalId: 'repair-schedule',
              parentEntityType: 'pill',
              parentEntityLocalId: parent.pillId,
              mutationId: mutation,
              dependsOnOperationId: parent.operation.id,
              payload: {
                'action': 'repair',
                'reviewedRepair': {
                  'version': 1,
                  'pillServerId': pillServer,
                  'scheduleServerId': scheduleServer,
                  'issueId': '10000000-0000-4000-8000-000000000013',
                  'issueRevision': 1,
                  'request': {
                    'mutationId': mutation,
                    'baseRevision': '1',
                    'effectiveFromLocalDate': '2026-10-08',
                    'schedule': {
                      'hour': 8,
                      'minute': 0,
                      'frequency': 'daily',
                      'frequencyDays': null,
                      'isActive': true,
                      'timeZone': 'Europe/Bucharest',
                    },
                  },
                },
              },
            ),
            applyProjection: () async {},
          );
      Future<List<PendingOperation>> ready() => f.db.pendingOperationsDao
          .getReady(_ownerId, workspaceId: f.context.workspaceId);
      expect(await ready(), isEmpty);
      await _settle(parent, resolution: 'keep_server_state');
      expect((await ready()).map((op) => op.id), [recorded.operationId]);
      expect(await f.db.pendingOperationsDao.getReady(_ownerId), isEmpty);
      await f.db.schedulesDao.markSynced(
        'repair-schedule',
        '10000000-0000-4000-8000-000000000099',
      );
      expect(await ready(), isEmpty);
    },
  );

  for (final (resolution, disposition) in const [
    ('adopt', 'adopted'),
    ('apply_residual', 'residual_applied'),
    ('keep_server_state', 'kept_server_state'),
  ]) {
    test(
      '$resolution settlement releases only mapped stable pill and schedule children',
      () async {
        final workspace = await _workspace();
        addTearDown(workspace.db.close);
        final parent = await _inventoryParent(workspace, resolution);
        final pillUpdate = await _pillChild(
          parent,
          suffix: 'metadata',
          action: 'update',
          data: const {'name': 'Updated fictional medication'},
        );
        final scheduleCreate = await _scheduleChild(parent, action: 'create');
        final stockEdit = await _pillChild(
          parent,
          suffix: 'stock-edit',
          action: 'update',
          data: const {'name': 'Fictional medication', 'currentStock': 12},
        );
        final unrelatedStable = await _child(
          parent,
          suffix: 'profile-edit',
          component: 'stable',
          operationType: 'profile.update',
          entityType: 'profile',
          entityLocalId: parent.profileId,
          payload: const {
            'action': 'update',
            'data': {'name': 'Fictional person'},
          },
        );
        final differentPill = await _differentMappedPillChild(parent);
        final undo = await _medicationChild(parent, action: 'undo');
        final correction = await _medicationChild(parent, action: 'correct');
        final inventoryChild = await _child(
          parent,
          suffix: 'inventory-child',
          component: 'medication',
          operationType: 'inventory.correct',
          entityType: 'pill',
          entityLocalId: parent.pillId,
          payload: {
            'inventoryCommand': {
              'commandId': 'fictional-inventory-child-$resolution',
              'action': 'correct',
              'pillId': parent.pillId,
              'targetStock': 14,
            },
          },
          effects: [
            PendingOperationEffectDraft(
              kind: 'inventory',
              legacySourceId: parent.pillId,
              requestFingerprint: 'fictional-child-inventory-$resolution',
            ),
          ],
        );

        await _settle(parent, resolution: resolution);

        // The legacy call shape remains committed-only without a workspace.
        final defaultReady = await workspace.db.pendingOperationsDao.getReady(
          workspace.context.ownerUserId,
        );
        expect(defaultReady.map((operation) => operation.id), isEmpty);

        final scopedReady = await workspace.db.pendingOperationsDao.getReady(
          workspace.context.ownerUserId,
          workspaceId: workspace.context.workspaceId,
        );
        expect(scopedReady.map((operation) => operation.id).toSet(), {
          pillUpdate.id,
          scheduleCreate.id,
        });
        expect(
          scopedReady.map((operation) => operation.id),
          isNot(contains(stockEdit.id)),
        );
        expect(
          scopedReady.map((operation) => operation.id),
          isNot(contains(unrelatedStable.id)),
        );
        expect(
          scopedReady.map((operation) => operation.id),
          isNot(contains(differentPill.id)),
        );
        expect(
          scopedReady.map((operation) => operation.id),
          isNot(contains(undo.id)),
        );
        expect(
          scopedReady.map((operation) => operation.id),
          isNot(contains(correction.id)),
        );
        expect(
          scopedReady.map((operation) => operation.id),
          isNot(contains(inventoryChild.id)),
        );

        final parentAfter = (await workspace.db.pendingOperationsDao.getById(
          parent.operation.id,
        ))!;
        expect(parentAfter.state, 'blocked');
        expect(parentAfter.payloadJson, parent.operation.payloadJson);
        final effectsAfter = await workspace.db.pendingOperationsDao.getEffects(
          parent.operation.id,
        );
        expect(effectsAfter, parent.effects);
        expect(effectsAfter.single.state, 'uncertain');
        expect(effectsAfter.single.safeServerId, isNull);
        expect(effectsAfter.single.acknowledgedAt, isNull);
        expect(effectsAfter.single.requestFingerprint, parent.fingerprint);
        final receipt =
            (await workspace.db.select(workspace.db.effectSettlements).get())
                .single;
        expect(receipt.resolution, resolution);
        expect(receipt.disposition, disposition);
      },
    );
  }

  test(
    'bridge mode: a stable edit does not wait for a stock command the ledger defers',
    () async {
      final workspace = await _workspace();
      addTearDown(workspace.db.close);
      final parent = await _inventoryParent(workspace, 'deferred');
      // A stock command that bridge mode holds untouched in the outbox.
      await (workspace.db.update(workspace.db.pendingOperations)
            ..where((row) => row.id.equals(parent.operation.id)))
          .write(const PendingOperationsCompanion(state: Value('queued')));
      final rename = await _pillChild(
        parent,
        suffix: 'rename',
        action: 'update',
        data: const {'name': 'Renamed while stock waits'},
      );
      final stockEdit = await _pillChild(
        parent,
        suffix: 'stock-edit',
        action: 'update',
        data: const {'name': 'Renamed', 'currentStock': 12},
      );
      final dao = workspace.db.pendingOperationsDao;
      final workspaceId = workspace.context.workspaceId;

      Future<Set<String>> ready({bool? ledgerActive}) async =>
          (await dao.getReady(
            _ownerId,
            workspaceId: workspaceId,
            ledgerActive: ledgerActive,
          )).map((op) => op.id).toSet();

      // Ledger active or unknown: the stock command goes first, as before.
      expect(await ready(ledgerActive: true), isNot(contains(rename.id)));
      expect(await ready(), isNot(contains(rename.id)));
      // Ledger inactive: the stock command will not be sent, so the rename
      // must not wait for it. A change that itself carries stock still waits.
      final bridge = await ready(ledgerActive: false);
      expect(bridge, contains(rename.id));
      expect(bridge, isNot(contains(stockEdit.id)));
    },
  );

  test(
    'settled stock review lets metadata publish and clears its pending projection',
    () async {
      final workspace = await _workspace();
      addTearDown(workspace.db.close);
      final parent = await _inventoryParent(workspace, 'publish');
      await workspace.db.pillsDao.markSynced(
        parent.pillId,
        'fictional-server-pill-publish',
        revision: 1,
      );
      final child = await _pillChild(
        parent,
        suffix: 'metadata',
        action: 'update',
        data: const {'name': 'Changed name'},
      );
      final dio = Dio();
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'data': {
                    'id': 'fictional-server-pill-publish',
                    'revision': 2,
                  },
                },
              ),
            );
          },
        ),
      );
      final adapter = V2StableAdapter(
        db: workspace.db,
        dio: dio,
        writeScope: SyncWriteScope(
          access: workspace.access,
          capability: await workspace.access.currentNetworkCapability(),
        ),
      );
      await PillsSyncAdapter(workspace.db).flush(_ownerId, adapter);
      expect(requests, isEmpty);
      await _settle(parent, resolution: 'keep_server_state');
      await PillsSyncAdapter(workspace.db).flush(_ownerId, adapter);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'PATCH');
      expect((requests.single.data as Map)['name'], 'Changed name');
      expect(
        (requests.single.data as Map).containsKey('currentStock'),
        isFalse,
      );
      expect(
        (await workspace.db.pendingOperationsDao.getById(child.id))!.state,
        'committed',
      );
      expect(
        (await workspace.db.pillsDao.getById(parent.pillId))!.syncStatus,
        'synced',
      );
      expect(
        (await workspace.db.pendingOperationsDao.getById(
          parent.operation.id,
        ))!.state,
        'blocked',
      );
      expect(
        await workspace.db.pendingOperationsDao.getEffects(parent.operation.id),
        parent.effects,
      );
    },
  );

  test(
    'acknowledged inventory alone does not release a blocked dependency',
    () async {
      final workspace = await _workspace();
      addTearDown(workspace.db.close);
      final parent = await _inventoryParent(workspace, 'ack-only');
      final child = await _pillChild(
        parent,
        suffix: 'metadata',
        action: 'update',
        data: const {'name': 'Updated fictional medication'},
      );
      final effect = parent.effects.single;
      await (workspace.db.update(
        workspace.db.pendingOperationEffects,
      )..where((row) => row.id.equals(effect.id))).write(
        PendingOperationEffectsCompanion(
          state: const Value('acknowledged'),
          safeServerId: const Value('fictional-server-stock-event'),
          safeResultFingerprint: const Value('fictional-stock-result'),
          acknowledgedAt: Value(_createdAt),
        ),
      );

      final ready = await workspace.db.pendingOperationsDao.getReady(
        workspace.context.ownerUserId,
        workspaceId: workspace.context.workspaceId,
      );
      expect(ready.map((operation) => operation.id), isNot(contains(child.id)));
      expect(
        await workspace.db.select(workspace.db.effectSettlements).get(),
        isEmpty,
      );
      expect(
        (await workspace.db.pendingOperationsDao.getById(
          parent.operation.id,
        ))!.state,
        'blocked',
      );
    },
  );

  test(
    'partial, mixed-effect, mismatched, cross-scope, or unmapped parents stay gated',
    () async {
      final workspace = await _workspace();
      addTearDown(workspace.db.close);

      Future<void> expectGated(
        String suffix, {
        int inventoryEffectCount = 1,
        bool includeDoseEffect = false,
        bool mapPill = true,
        bool mapProfile = true,
        List<int>? settledEffects,
        String? settlementFingerprint,
      }) async {
        final parent = await _inventoryParent(
          workspace,
          suffix,
          inventoryEffectCount: inventoryEffectCount,
          includeDoseEffect: includeDoseEffect,
          mapPill: mapPill,
          mapProfile: mapProfile,
        );
        final child = await _pillChild(
          parent,
          suffix: 'child',
          action: 'update',
          data: const {'name': 'Changed fictional medication'},
        );
        await _settle(
          parent,
          resolution: 'keep_server_state',
          effectIndexes: settledEffects,
          fingerprint: settlementFingerprint,
        );
        final ready = await workspace.db.pendingOperationsDao.getReady(
          workspace.context.ownerUserId,
          workspaceId: workspace.context.workspaceId,
        );
        expect(
          ready.map((operation) => operation.id),
          isNot(contains(child.id)),
          reason: suffix,
        );
      }

      await expectGated(
        'partial',
        inventoryEffectCount: 2,
        settledEffects: [0],
      );
      await expectGated('mixed-parent-effects', includeDoseEffect: true);
      await expectGated(
        'mismatched-fingerprint',
        settlementFingerprint: 'fictional-wrong-fingerprint',
      );
      await expectGated('pill-not-mapped', mapPill: false);
      await expectGated('profile-not-mapped', mapProfile: false);

      // Prepare both valid owner-1 operations before activating the second
      // connected workspace, which intentionally replaces the device grant.
      final wrongWorkspace = await _inventoryParent(
        workspace,
        'wrong-workspace',
      );
      final wrongWorkspaceChild = await _pillChild(
        wrongWorkspace,
        suffix: 'child',
        action: 'update',
        data: const {'name': 'Wrong workspace child'},
      );
      final wrongOwner = await _inventoryParent(workspace, 'wrong-owner');
      final wrongOwnerChild = await _pillChild(
        wrongOwner,
        suffix: 'child',
        action: 'update',
        data: const {'name': 'Wrong owner child'},
      );
      final otherWorkspace = await ProtectedWorkspaceFixture.create(
        ownerId: _otherOwnerId,
        database: workspace.db,
        preferences: workspace.preferences,
      );
      await _settle(
        wrongWorkspace,
        resolution: 'keep_server_state',
        workspaceId: otherWorkspace.context.workspaceId,
      );
      await _settle(
        wrongOwner,
        resolution: 'keep_server_state',
        userId: otherWorkspace.context.ownerUserId,
      );
      final ready = await workspace.db.pendingOperationsDao.getReady(
        workspace.context.ownerUserId,
        workspaceId: workspace.context.workspaceId,
      );
      expect(
        ready.map((operation) => operation.id),
        isNot(contains(wrongWorkspaceChild.id)),
      );
      expect(
        ready.map((operation) => operation.id),
        isNot(contains(wrongOwnerChild.id)),
      );
    },
  );
}

Future<ProtectedWorkspaceFixture> _workspace() =>
    ProtectedWorkspaceFixture.create(ownerId: _ownerId);

class _InventoryParent {
  const _InventoryParent({
    required this.workspace,
    required this.suffix,
    required this.profileId,
    required this.pillId,
    required this.operation,
    required this.effects,
  });

  final ProtectedWorkspaceFixture workspace;
  final String suffix;
  final String profileId;
  final String pillId;
  final PendingOperation operation;
  final List<PendingOperationEffect> effects;
  String get fingerprint => 'fictional-inventory-fingerprint-$suffix-0';
}

Future<_InventoryParent> _inventoryParent(
  ProtectedWorkspaceFixture workspace,
  String suffix, {
  int inventoryEffectCount = 1,
  bool includeDoseEffect = false,
  bool mapPill = true,
  bool mapProfile = true,
}) async {
  final profileId = 'fictional-profile-$suffix';
  final pillId = 'fictional-pill-$suffix';
  await workspace.db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: profileId,
      userId: workspace.context.ownerUserId,
      name: 'Fictional person $suffix',
      createdAt: _createdAt,
      updatedAt: _createdAt,
      serverId: mapProfile
          ? Value('fictional-server-profile-$suffix')
          : const Value.absent(),
      syncStatus: Value(mapProfile ? 'synced' : 'pending'),
    ),
  );
  await workspace.db.pillsDao.upsert(
    PillsCompanion.insert(
      id: pillId,
      profileId: profileId,
      name: 'Fictional medication $suffix',
      currentStock: const Value(10),
      createdAt: _createdAt,
      updatedAt: _createdAt,
      serverId: mapPill
          ? Value('fictional-server-pill-$suffix')
          : const Value.absent(),
      syncStatus: Value(mapPill ? 'synced' : 'pending'),
    ),
  );
  final effects = [
    for (var index = 0; index < inventoryEffectCount; index++)
      PendingOperationEffectDraft(
        kind: 'inventory',
        legacySourceId: pillId,
        requestFingerprint: 'fictional-inventory-fingerprint-$suffix-$index',
      ),
    if (includeDoseEffect)
      PendingOperationEffectDraft(
        kind: 'dose',
        legacySourceId: 'fictional-dose-$suffix',
        requestFingerprint: 'fictional-dose-fingerprint-$suffix',
      ),
  ];
  final repository = PendingOperationRepository(
    workspace.db,
    access: workspace.access,
    context: workspace.context,
  );
  final recorded = await repository.record(
    operation: PendingOperationDraft(
      userId: workspace.context.ownerUserId,
      mutationId: 'fictional-inventory-mutation-$suffix',
      component: 'medication',
      operationType: 'inventory.correct',
      entityType: 'pill',
      entityLocalId: pillId,
      payload: {
        'inventoryCommand': {
          'commandId': 'fictional-inventory-command-$suffix',
          'action': 'correct',
          'pillId': pillId,
          'targetStock': 11,
        },
      },
      effects: effects,
    ),
    applyProjection: () async {},
  );
  await (workspace.db.update(workspace.db.pendingOperations)
        ..where((row) => row.id.equals(recorded.operationId)))
      .write(const PendingOperationsCompanion(state: Value('blocked')));
  final storedEffects = await workspace.db.pendingOperationsDao.getEffects(
    recorded.operationId,
  );
  for (final effect in storedEffects) {
    await (workspace.db.update(
      workspace.db.pendingOperationEffects,
    )..where((row) => row.id.equals(effect.id))).write(
      PendingOperationEffectsCompanion(
        state: const Value('uncertain'),
        attemptedAt: Value(_createdAt),
        safeResultFingerprint: Value(
          'reconciliation-recorded:fictional-issue-$suffix-${effect.ordinal}',
        ),
      ),
    );
  }
  final operation = (await workspace.db.pendingOperationsDao.getById(
    recorded.operationId,
  ))!;
  return _InventoryParent(
    workspace: workspace,
    suffix: suffix,
    profileId: profileId,
    pillId: pillId,
    operation: operation,
    effects: await workspace.db.pendingOperationsDao.getEffects(
      recorded.operationId,
    ),
  );
}

Future<PendingOperation> _pillChild(
  _InventoryParent parent, {
  required String suffix,
  required String action,
  required Map<String, Object?> data,
}) => _child(
  parent,
  suffix: suffix,
  component: 'stable',
  operationType: 'pill.$action',
  entityType: 'pill',
  entityLocalId: parent.pillId,
  parentEntityType: 'profile',
  parentEntityLocalId: parent.profileId,
  payload: {'action': action, 'data': data},
);

Future<PendingOperation> _differentMappedPillChild(
  _InventoryParent parent,
) async {
  final otherPillId = 'fictional-different-pill-${parent.suffix}';
  await parent.workspace.db.pillsDao.upsert(
    PillsCompanion.insert(
      id: otherPillId,
      profileId: parent.profileId,
      name: 'Another fictional medication',
      createdAt: _createdAt,
      updatedAt: _createdAt,
      serverId: Value('fictional-server-different-pill-${parent.suffix}'),
      syncStatus: const Value('synced'),
    ),
  );
  return _child(
    parent,
    suffix: 'different-pill-metadata',
    component: 'stable',
    operationType: 'pill.update',
    entityType: 'pill',
    entityLocalId: otherPillId,
    parentEntityType: 'profile',
    parentEntityLocalId: parent.profileId,
    payload: const {
      'action': 'update',
      'data': {'name': 'Another fictional medication'},
    },
  );
}

Future<PendingOperation> _scheduleChild(
  _InventoryParent parent, {
  required String action,
}) async {
  final scheduleId = 'fictional-schedule-${parent.suffix}-$action';
  await parent.workspace.db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: scheduleId,
      pillId: parent.pillId,
      hour: 8,
      minute: 0,
      frequency: 'daily',
      createdAt: _createdAt,
      updatedAt: _createdAt,
      syncStatus: const Value('pending'),
    ),
  );
  return _child(
    parent,
    suffix: 'schedule-$action',
    component: 'stable',
    operationType: 'schedule.$action',
    entityType: 'schedule',
    entityLocalId: scheduleId,
    parentEntityType: 'pill',
    parentEntityLocalId: parent.pillId,
    payload: {
      'action': action,
      'data': {'hour': 8, 'minute': 0, 'frequency': 'daily'},
    },
  );
}

Future<PendingOperation> _medicationChild(
  _InventoryParent parent, {
  required String action,
}) => _child(
  parent,
  suffix: 'medication-$action',
  component: 'medication',
  operationType: 'medication.command',
  entityType: 'occurrence',
  entityLocalId: 'fictional-occurrence-$action-${parent.suffix}',
  payload: {
    'command': {
      'commandId': 'fictional-medication-$action-${parent.suffix}',
      'action': action,
    },
  },
  effects: [
    PendingOperationEffectDraft(
      kind: 'dose',
      requestFingerprint: 'fictional-medication-$action-${parent.suffix}',
    ),
  ],
);

Future<PendingOperation> _child(
  _InventoryParent parent, {
  required String suffix,
  required String component,
  required String operationType,
  required String entityType,
  required String entityLocalId,
  required Map<String, Object?> payload,
  String? parentEntityType,
  String? parentEntityLocalId,
  List<PendingOperationEffectDraft> effects = const [],
}) async {
  final recorded =
      await PendingOperationRepository(
        parent.workspace.db,
        access: parent.workspace.access,
        context: parent.workspace.context,
      ).record(
        operation: PendingOperationDraft(
          userId: parent.workspace.context.ownerUserId,
          mutationId: 'fictional-${parent.suffix}-$suffix',
          component: component,
          operationType: operationType,
          entityType: entityType,
          entityLocalId: entityLocalId,
          parentEntityType: parentEntityType,
          parentEntityLocalId: parentEntityLocalId,
          dependsOnOperationId: parent.operation.id,
          payload: payload,
          effects: effects,
        ),
        applyProjection: () async {},
      );
  return (await parent.workspace.db.pendingOperationsDao.getById(
    recorded.operationId,
  ))!;
}

Future<void> _settle(
  _InventoryParent parent, {
  required String resolution,
  List<int>? effectIndexes,
  String? fingerprint,
  String? workspaceId,
  String? userId,
}) async {
  final disposition = switch (resolution) {
    'adopt' => 'adopted',
    'apply_residual' => 'residual_applied',
    'keep_server_state' => 'kept_server_state',
    _ => throw ArgumentError.value(resolution, 'resolution'),
  };
  final selected = effectIndexes == null
      ? parent.effects
      : [for (final index in effectIndexes) parent.effects[index]];
  for (final effect in selected) {
    await parent.workspace.db
        .into(parent.workspace.db.effectSettlements)
        .insert(
          EffectSettlementsCompanion.insert(
            effectId: effect.id,
            workspaceId: workspaceId ?? parent.workspace.context.workspaceId,
            userId: userId ?? parent.workspace.context.ownerUserId,
            issueId: 'fictional-issue-${parent.suffix}-${effect.ordinal}',
            resolutionCommandId:
                'fictional-resolution-${parent.suffix}-${effect.ordinal}',
            resolution: resolution,
            disposition: disposition,
            requestFingerprint: fingerprint ?? effect.requestFingerprint,
            resolvedAt: _createdAt,
          ),
        );
  }
}
