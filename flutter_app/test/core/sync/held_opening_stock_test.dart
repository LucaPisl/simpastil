import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/held_stock.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/core/sync/sync_retry_policy.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

const _serverPillId = '30000000-0000-4000-8000-000000000022';
const _serverProfileId = '30000000-0000-4000-8000-000000000033';
const _startId = '30000000-0000-4000-8000-0000000000d1';
const _correctId = '30000000-0000-4000-8000-0000000000d2';

final _t0 = DateTime.utc(2026, 9, 1);

// The device sequence (bridge mode): stock tracking is switched on at 10, two
// doses are taken (phone 8; the bridge applies no delta while the server
// count is unset), then the ledger is activated and the held opening is sent.
// Sent as the absolute 10 it wipes the doses out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late V2MedicationSyncAdapter adapter;
  late String userId;
  final posts = <String, List<Map<String, dynamic>>>{};
  DioException? failInventoryPost;
  int serverStock = 8;

  List<Map<String, dynamic>> inventoryPosts() =>
      posts['/medication/inventory/commands'] ?? const [];

  Future<void> setStock(int? stock) =>
      (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
        PillsCompanion(currentStock: Value(stock)),
      );

  Future<void> event(
    String id,
    String command,
    String kind,
    int delta,
    int hours, {
    String? reverses,
  }) => f.db.medicationLedgerDao.appendInventoryEvent(
    InventoryEventsCompanion.insert(
      id: id,
      userId: userId,
      pillId: f.pill.id,
      commandId: command,
      kind: kind,
      delta: delta,
      reversesInventoryEventId: Value(reverses),
      origin: 'native',
      recordedAt: _t0.add(Duration(hours: hours)),
    ),
  );

  /// A real outbox row for a dose or undo command of the pill.
  Future<void> doseOp(
    String id,
    String command,
    int hours, {
    required String state,
    String? code,
    String type = 'medication.command',
  }) async {
    await f.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: id,
        userId: userId,
        mutationId: command,
        component: 'medication',
        operationType: type,
        contractVersion: 2,
        payloadJson: jsonEncode({
          'command': {'commandId': command, 'occurrenceId': f.occurrence.id},
          'localProjection': {'pillId': f.pill.id},
        }),
        createdAt: _t0.add(Duration(hours: hours)),
      ),
    );
    if (state != 'queued') {
      await f.db.customStatement(
        "UPDATE pending_operations SET state = '$state', "
        "safe_error_code = ${code == null ? 'NULL' : "'$code'"} "
        "WHERE id = '$id'",
      );
    }
  }

  Future<void> startOp() => f.db.pendingOperationsDao.enqueue(
    PendingOperationsCompanion.insert(
      id: 'op-start',
      userId: userId,
      mutationId: _startId,
      component: 'medication',
      operationType: 'inventory.start',
      contractVersion: 2,
      payloadJson: jsonEncode({
        'inventoryCommand': {
          'commandId': _startId,
          'action': 'start',
          'pillId': f.pill.id,
          'initialStock': 10,
          'note': null,
        },
      }),
      createdAt: _t0,
    ),
  );

  Future<PendingOperation> op(String id) async =>
      (await f.db.pendingOperationsDao.getById(id))!;

  setUp(() async {
    posts.clear();
    failInventoryPost = null;
    serverStock = 8;
    f = await CareRecordingFixture.create(connected: true, legacyStock: 8);
    addTearDown(f.db.close);
    userId = f.workspace.context.ownerUserId;
    await (f.db.update(f.db.profiles)..where((p) => p.id.equals(f.person.id)))
        .write(const ProfilesCompanion(serverId: Value(_serverProfileId)));
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(
        serverId: Value(_serverPillId),
        revision: Value(3),
        syncStatus: Value('synced'),
      ),
    );
    final context = f.workspace.context;
    final scope = SyncWriteScope(
      access: f.workspace.access,
      capability: NetworkCapability(
        ownerId: context.ownerUserId,
        endpoint: context.endpoint!,
        epoch: context.networkEpoch!,
        generation: context.sessionGeneration!,
      ),
    );
    await startOp();
    await event('ev-open', _startId, 'opening', 10, 0);
    // Two doses delivered through the bridge: committed outbox rows with no
    // server stock effect.
    await doseOp('op-bd1', 'bridge-dose-1', 1, state: 'committed');
    await doseOp('op-bd2', 'bridge-dose-2', 2, state: 'committed');
    await event('ev-dose-1', 'bridge-dose-1', 'dose', -1, 1);
    await event('ev-dose-2', 'bridge-dose-2', 'dose', -1, 2);
    final dio = _MockDio();
    when(() => dio.get<dynamic>(any())).thenAnswer(
      (_) async => Response(
        data: {
          'pills': [
            {'id': _serverPillId, 'currentStock': serverStock, 'revision': '4'},
          ],
        },
        requestOptions: RequestOptions(path: '/profiles/x/pills'),
      ),
    );
    when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
      final path = invocation.positionalArguments.first as String;
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      if (path.contains('inventory') && failInventoryPost != null) {
        throw failInventoryPost!;
      }
      (posts[path] ??= []).add(data);
      return Response(
        data: {'commandId': data['commandId'], 'revision': '4'},
        requestOptions: RequestOptions(path: path),
      );
    });
    adapter = V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope);
  });

  DioException unavailable() => DioException(
    requestOptions: RequestOptions(path: '/medication/inventory/commands'),
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: RequestOptions(path: '/medication/inventory/commands'),
      statusCode: 503,
    ),
  );

  test('the held opening counts the doses taken after it', () async {
    final result = await adapter.send(await op('op-start'));
    expect(result.status, MedicationMutationStatus.acknowledged);
    expect(inventoryPosts().single['initialStock'], 8);
    expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 8);
    final frozen = jsonDecode((await op('op-start')).payloadJson) as Map;
    expect((frozen['resolvedInventoryRequest'] as Map)['initialStock'], 8);
    // The doses are marked as folded into the opening.
    final events = await f.db.medicationLedgerDao.getInventoryEventsForPill(
      f.pill.id,
    );
    expect(
      events.firstWhere((e) => e.id == 'ev-dose-1').provenanceJson,
      contains('foldedIntoOpening'),
    );
  });

  test('a dose still unsent is left to apply after the opening', () async {
    await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
    await event('ev-dose-3', 'unsent-dose-3', 'dose', -1, 3);
    await setStock(7);
    await adapter.send(await op('op-start'));
    // 7 on the phone, minus the unsent dose: the server opens at 8, the dose
    // then takes it to 7.
    expect(inventoryPosts().single['initialStock'], 8);
  });

  test('an opening with no later events is sent as typed', () async {
    await f.db.customStatement(
      "DELETE FROM inventory_events WHERE id LIKE 'ev-dose-%'",
    );
    await setStock(10);
    await adapter.send(await op('op-start'));
    expect(inventoryPosts().single['initialStock'], 10);
  });

  group('ordering after the start (F1, F8)', () {
    test('a failed start keeps the doses behind it, then retries', () async {
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      await event('ev-dose-3', 'unsent-dose-3', 'dose', -1, 3);
      await setStock(7);

      failInventoryPost = unavailable();
      final failed = await adapter.send(await op('op-start'));
      expect(failed.status, MedicationMutationStatus.retryable);
      expect(inventoryPosts(), isEmpty);

      // The dose is held, in the same flush, without spending an attempt.
      final held = await adapter.send(await op('op-d3'));
      expect(held.status, MedicationMutationStatus.waitingForMapping);
      expect(held.safeErrorCode, 'INVENTORY_START_PENDING');
      expect(posts['/medication/commands'], isNull);
      final dose = await op('op-d3');
      expect(dose.state, 'queued');
      expect(dose.attemptCount, 0);

      // The retry replays the frozen opening; only then may the dose go.
      failInventoryPost = null;
      final retry = await adapter.send(await op('op-start'));
      expect(retry.status, MedicationMutationStatus.acknowledged);
      expect(inventoryPosts().single['initialStock'], 8);
      final released = await adapter.send(await op('op-d3'));
      expect(released.safeErrorCode, isNot('INVENTORY_START_PENDING'));
    });

    Future<void> setStart(String state, [String? code]) => f.db.customStatement(
      "UPDATE pending_operations SET state = '$state', "
      "safe_error_code = ${code == null ? 'NULL' : "'$code'"} "
      "WHERE id = 'op-start'",
    );

    test('a start with an uncertain outcome keeps doses waiting', () async {
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      await setStart('blocked', 'MEDICATION_INVENTORY_RESULT_UNCERTAIN');
      final held = await adapter.send(await op('op-d3'));
      expect(held.status, MedicationMutationStatus.waitingForMapping);
      expect(held.safeErrorCode, 'INVENTORY_START_PENDING');
    });

    test(
      'R1: a start in conflict releases doses, undos and corrections',
      () async {
        // The pill was already started on the server: this opening never
        // applies, and nothing may wait for it.
        await setStart('conflict', 'CONFLICT_STALE_UPDATE');
        await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
        await doseOp(
          'op-undo',
          'unsent-undo-3',
          4,
          state: 'queued',
          type: 'medication.undo',
        );
        for (final id in ['op-d3', 'op-undo']) {
          final released = await adapter.send(await op(id));
          expect(released.safeErrorCode, isNot('INVENTORY_START_PENDING'));
        }
      },
    );

    test(
      'R1: a start blocked for review (not uncertain) releases them',
      () async {
        await setStart('blocked', 'MEDICATION_RECONCILIATION_REQUIRED');
        await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
        final released = await adapter.send(await op('op-d3'));
        expect(released.safeErrorCode, isNot('INVENTORY_START_PENDING'));
      },
    );

    test('R1: a discarded start releases them', () async {
      await setStart('discarded');
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      final released = await adapter.send(await op('op-d3'));
      expect(released.safeErrorCode, isNot('INVENTORY_START_PENDING'));
    });

    test(
      'R1: a correction is released when the start is in conflict',
      () async {
        await setStart('conflict', 'CONFLICT_STALE_UPDATE');
        await f.db.pendingOperationsDao.enqueue(
          PendingOperationsCompanion.insert(
            id: 'op-correct',
            userId: userId,
            mutationId: _correctId,
            component: 'medication',
            operationType: 'inventory.correct',
            contractVersion: 2,
            payloadJson: jsonEncode({
              'inventoryCommand': {
                'commandId': _correctId,
                'action': 'correct',
                'pillId': f.pill.id,
                'targetStock': 20,
                'note': null,
              },
            }),
            createdAt: _t0.add(const Duration(hours: 4)),
          ),
        );
        final result = await adapter.send(await op('op-correct'));
        expect(result.safeErrorCode, isNot('INVENTORY_START_PENDING'));
      },
    );

    test('a dose recorded before the start is not held back', () async {
      // Tracking was off then: no count to act on. Recorded before the start
      // in the outbox, whatever the device clock said.
      await f.db.customStatement(
        "DELETE FROM pending_operations "
        "WHERE id = 'op-start'",
      );
      await doseOp('op-early', 'early-dose', 50, state: 'queued');
      await startOp();
      final result = await adapter.send(await op('op-early'));
      expect(result.safeErrorCode, isNot('INVENTORY_START_PENDING'));
    });

    test('a start and a correction held together, end to end', () async {
      // 10, two bridge doses, then a correction to 20 (+12 locally).
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'op-correct',
          userId: userId,
          mutationId: _correctId,
          component: 'medication',
          operationType: 'inventory.correct',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'inventoryCommand': {
              'commandId': _correctId,
              'action': 'correct',
              'pillId': f.pill.id,
              'targetStock': 20,
              'note': null,
            },
          }),
          createdAt: _t0.add(const Duration(hours: 4)),
        ),
      );
      await event('ev-correct', _correctId, 'correction', 12, 4);
      await setStock(20);

      // The correction waits for the start without reading the server or
      // spending an attempt.
      final waiting = await adapter.send(await op('op-correct'));
      expect(waiting.safeErrorCode, 'INVENTORY_START_PENDING');
      expect((await op('op-correct')).attemptCount, 0);

      final start = await adapter.send(await op('op-start'));
      expect(start.status, MedicationMutationStatus.acknowledged);
      expect(inventoryPosts().single['initialStock'], 8);

      serverStock = 8;
      final correct = await adapter.send(await op('op-correct'));
      expect(correct.status, MedicationMutationStatus.acknowledged);
      expect(inventoryPosts().last['targetStock'], 20);
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 20);
    });
  });

  group('undo of a bridge-era dose (F2)', () {
    test('an unsent undo is not subtracted: the server applies 0', () async {
      // The person undid the first bridge dose before the next sync: 9.
      await doseOp(
        'op-undo',
        'unsent-undo-1',
        3,
        state: 'queued',
        type: 'medication.undo',
      );
      await event(
        'ev-undo-1',
        'unsent-undo-1',
        'dose_reversal',
        1,
        3,
        reverses: 'ev-dose-1',
      );
      await setStock(9);
      await adapter.send(await op('op-start'));
      // The server has no inventory event for the bridge dose, so the undo
      // adds nothing there: the opening must already be 9.
      expect(inventoryPosts().single['initialStock'], 9);
    });

    test('an undo of a dose that is itself unsent still applies', () async {
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      await event('ev-dose-3', 'unsent-dose-3', 'dose', -1, 3);
      await doseOp(
        'op-undo',
        'unsent-undo-3',
        4,
        state: 'queued',
        type: 'medication.undo',
      );
      await event(
        'ev-undo-3',
        'unsent-undo-3',
        'dose_reversal',
        1,
        4,
        reverses: 'ev-dose-3',
      );
      await setStock(8);
      await adapter.send(await op('op-start'));
      // Both unsent, both apply after the opening: -1 then +1.
      expect(inventoryPosts().single['initialStock'], 8);
    });
  });

  group('uncertain effects are not guessed (F3, F6)', () {
    test('a blocked dose keeps the start waiting', () async {
      await doseOp(
        'op-d3',
        'uncertain-dose-3',
        3,
        state: 'blocked',
        code: 'MEDICATION_COMMAND_RESULT_UNCERTAIN',
      );
      await event('ev-dose-3', 'uncertain-dose-3', 'dose', -1, 3);
      await setStock(7);
      final result = await adapter.send(await op('op-start'));
      expect(result.status, MedicationMutationStatus.waitingForMapping);
      expect(result.safeErrorCode, 'INVENTORY_START_WAITS_FOR_REVIEW');
      expect(inventoryPosts(), isEmpty);
      final start = await op('op-start');
      expect(start.state, 'queued');
      expect(start.attemptCount, 0);
      expect(start.payloadJson, isNot(contains('resolvedInventoryRequest')));
    });

    test('an unknown phone count is a wait, not the typed value', () async {
      await setStock(null);
      final result = await adapter.send(await op('op-start'));
      // R3: not a silent wait; an item a person can discard or replace with
      // the server's version.
      expect(result.status, MedicationMutationStatus.conflict);
      expect(result.safeErrorCode, 'INVENTORY_START_STOCK_UNKNOWN');
      expect(inventoryPosts(), isEmpty);
      final start = await op('op-start');
      expect(start.state, 'conflict');
      expect(start.safeErrorCode, 'INVENTORY_START_STOCK_UNKNOWN');
    });
  });

  group('folded doses are marked when the opening commits (R5)', () {
    Future<bool> folded(String id) async {
      final events = await f.db.medicationLedgerDao.getInventoryEventsForPill(
        f.pill.id,
      );
      return (events.firstWhere((e) => e.id == id).provenanceJson ?? '')
          .contains('foldedIntoOpening');
    }

    test('a failed opening marks nothing, the retry does', () async {
      failInventoryPost = unavailable();
      await adapter.send(await op('op-start'));
      expect(await folded('ev-dose-1'), isFalse);
      failInventoryPost = null;
      await adapter.send(await op('op-start'));
      expect(await folded('ev-dose-1'), isTrue);
      expect(await folded('ev-dose-2'), isTrue);
    });

    test('a discarded opening leaves the doses unmarked', () async {
      failInventoryPost = unavailable();
      await adapter.send(await op('op-start'));
      await f.db.customStatement(
        "UPDATE pending_operations SET state = 'discarded' "
        "WHERE id = 'op-start'",
      );
      expect(await folded('ev-dose-1'), isFalse);
    });
  });

  group('pull guard follows the commands that can still be sent (R2)', () {
    test(
      'conflict and review-only blocked openings do not hold the count',
      () async {
        expect(await unsettledInventoryPillIds(f.db, userId), {f.pill.id});
        await f.db.customStatement(
          "UPDATE pending_operations SET state = 'conflict' WHERE id = 'op-start'",
        );
        expect(await unsettledInventoryPillIds(f.db, userId), isEmpty);
        await f.db.customStatement(
          "UPDATE pending_operations SET state = 'blocked', "
          "safe_error_code = 'MEDICATION_RECONCILIATION_REQUIRED' "
          "WHERE id = 'op-start'",
        );
        expect(await unsettledInventoryPillIds(f.db, userId), isEmpty);
        await f.db.customStatement(
          "UPDATE pending_operations SET state = 'blocked', "
          "safe_error_code = 'MEDICATION_INVENTORY_RESULT_UNCERTAIN' "
          "WHERE id = 'op-start'",
        );
        expect(await unsettledInventoryPillIds(f.db, userId), {f.pill.id});
      },
    );
  });

  group('the wait is persisted and counted (R1)', () {
    test('setWaitReason marks and clears only queued waiting ops', () async {
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      final dao = f.db.pendingOperationsDao;
      expect(
        await dao.setWaitReason('op-d3', inventoryStartPendingCode),
        isTrue,
      );
      expect((await op('op-d3')).safeErrorCode, inventoryStartPendingCode);
      expect(
        await dao.setWaitReason('op-d3', inventoryStartPendingCode),
        isFalse,
      );
      expect((await op('op-d3')).state, 'queued');
      expect((await op('op-d3')).attemptCount, 0);
      expect(await dao.setWaitReason('op-d3', null), isTrue);
      expect((await op('op-d3')).safeErrorCode, isNull);
      // A blocked op's own code is never overwritten.
      await doseOp(
        'op-b',
        'blocked-cmd',
        4,
        state: 'blocked',
        code: 'SOME_CODE',
      );
      expect(
        await dao.setWaitReason('op-b', inventoryStartPendingCode),
        isFalse,
      );
      expect(await dao.setWaitReason('op-b', null), isFalse);
      expect((await op('op-b')).safeErrorCode, 'SOME_CODE');
    });

    test('tally: stranded only behind a stuck opening', () async {
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      await f.db.pendingOperationsDao.setWaitReason(
        'op-d3',
        inventoryStartPendingCode,
      );
      var ops = await f.db.pendingOperationsDao.getUnsettledForUser(userId);
      expect(SyncService.tallyOperations(ops).stranded, 0);
      await f.db.customStatement(
        "UPDATE pending_operations SET state = 'blocked', "
        "safe_error_code = 'MEDICATION_INVENTORY_RESULT_UNCERTAIN' "
        "WHERE id = 'op-start'",
      );
      ops = await f.db.pendingOperationsDao.getUnsettledForUser(userId);
      expect(SyncService.tallyOperations(ops).stranded, 1);
    });
  });

  group('an exhausted opening still holds what waits behind it (N1)', () {
    test('doses stay held and the count survives until Retry all', () async {
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      await event('ev-dose-3', 'unsent-dose-3', 'dose', -1, 3);
      await setStock(7);

      failInventoryPost = unavailable();
      for (var i = 0; i < 8; i++) {
        await adapter.send(await op('op-start'));
      }
      final start = await op('op-start');
      expect(start.state, 'blocked');
      expect(start.safeErrorCode, SyncRetryPolicy.retryExhaustedCode);
      expect(inventoryPosts(), isEmpty);

      // The dose is not released, and the pull keeps the phone's count.
      final held = await adapter.send(await op('op-d3'));
      expect(held.safeErrorCode, 'INVENTORY_START_PENDING');
      expect(await unsettledInventoryPillIds(f.db, userId), {f.pill.id});

      // Retry all requeues the frozen opening; it replays unchanged.
      failInventoryPost = null;
      final recovery = SyncRecoveryService(
        db: f.db,
        flush: (_) async {},
        pull: (_) async => true,
        write: <T>(_, action) => f.db.transaction(action),
      );
      await recovery.retryAll(userId);
      expect((await op('op-start')).state, 'queued');
      final sent = await adapter.send(await op('op-start'));
      expect(sent.status, MedicationMutationStatus.acknowledged);
      // Server: opening 8, then the held dose -1 = 7. Phone: 7.
      expect(inventoryPosts().single['initialStock'], 8);
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 7);
      expect((inventoryPosts().single['initialStock'] as int) - 1, 7);
    });

    test('a definitive refusal with a frozen request releases (N3)', () async {
      await f.db.customStatement(
        "UPDATE pending_operations SET state = 'blocked', "
        "safe_error_code = 'MEDICATION_INVENTORY_REJECTED', "
        "payload_json = json_set(payload_json, '\$.resolvedInventoryRequest', "
        "json_object('commandId', '$_startId', 'action', 'start')) "
        "WHERE id = 'op-start'",
      );
      expect((await op('op-start')).payloadJson, contains('resolvedInventory'));
      await doseOp('op-d3', 'unsent-dose-3', 3, state: 'queued');
      final r = await adapter.send(await op('op-d3'));
      expect(r.safeErrorCode, isNot('INVENTORY_START_PENDING'));
      expect(await unsettledInventoryPillIds(f.db, userId), isEmpty);
    });
  });

  group('an undo while the opening is retrying (N2)', () {
    test('a dose frozen into an unsent opening counts as folded', () async {
      failInventoryPost = unavailable();
      await adapter.send(await op('op-start'));
      expect(await isPendingFolded(f.db, userId, 'ev-dose-1'), isTrue);
      expect(await isPendingFolded(f.db, userId, 'ev-other'), isFalse);
      // A start in conflict never applies: nothing is folded by it.
      await f.db.customStatement(
        "UPDATE pending_operations SET state = 'conflict' "
        "WHERE id = 'op-start'",
      );
      expect(await isPendingFolded(f.db, userId, 'ev-dose-1'), isFalse);
    });
  });
}
