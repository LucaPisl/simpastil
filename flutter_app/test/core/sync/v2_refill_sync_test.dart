import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/held_stock.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

// A refill is a delta command: its count needs no rebase (only a stale
// baseRevision is refreshed from the server, never sent to review), it waits
// behind the pill's opening like any stock effect, its acknowledgement adopts
// the pill revision, and a lost response replays the same frozen request under
// the same id.
class _MockDio extends Mock implements Dio {}

const _serverPillId = '30000000-0000-4000-8000-000000000022';
const _refillId = '30000000-0000-4000-8000-0000000000d1';
const _startId = '30000000-0000-4000-8000-0000000000d0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late V2MedicationSyncAdapter adapter;
  late String userId;
  var failNext = 0;
  var revisionAnswer = '4';
  final posts = <Map<String, dynamic>>[];
  var staleUntilRevision = 0;
  String? serverRevision = '9';
  Object? serverMark = false;
  var serverRow = <String, Object?>{};

  setUp(() async {
    serverRow = {};
    posts.clear();
    staleUntilRevision = 0;
    serverRevision = '9';
    serverMark = false;
    failNext = 0;
    revisionAnswer = '4';
    f = await CareRecordingFixture.create(connected: true, legacyStock: 10);
    addTearDown(f.db.close);
    userId = f.workspace.context.ownerUserId;
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
    final dio = _MockDio();
    when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      posts.add(data);
      if (staleUntilRevision > 0 &&
          int.parse(data['baseRevision'] as String) < staleUntilRevision) {
        throw DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.badResponse,
          response: Response(
            statusCode: 409,
            data: {
              'error': {'code': 'CONFLICT_STALE_UPDATE'},
            },
            requestOptions: RequestOptions(path: '/x'),
          ),
        );
      }
      if (failNext > 0) {
        failNext--;
        throw DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.receiveTimeout,
        );
      }
      return Response(
        data: {'commandId': data['commandId'], 'revision': revisionAnswer},
        requestOptions: RequestOptions(path: '/x'),
      );
    });
    when(() => dio.get<dynamic>(any())).thenAnswer((_) async {
      if (serverRevision == null) {
        throw DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        );
      }
      return Response(
        data: {
          'pills': [
            {
              'id': _serverPillId,
              'revision': serverRevision,
              'stockNeedsRecount': serverMark,
              ...serverRow,
            },
          ],
        },
        requestOptions: RequestOptions(path: '/x'),
      );
    });
    adapter = V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope);
  });

  Future<void> enqueue(String id, String action, Map<String, Object?> body) =>
      f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'op-$id',
          userId: userId,
          mutationId: id,
          component: 'medication',
          operationType: 'inventory.$action',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'inventoryCommand': {
              'commandId': id,
              'action': action,
              'pillId': f.pill.id,
              ...body,
              'note': null,
            },
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );

  Future<PendingOperation> op(String id) async =>
      (await f.db.pendingOperationsDao.getById('op-$id'))!;

  test(
    'an acknowledged refill is sent as a delta and adopts the revision',
    () async {
      await enqueue(_refillId, 'refill', {'amount': 5});
      final result = await adapter.send(await op(_refillId));
      expect(result.status, MedicationMutationStatus.acknowledged);
      expect(posts.single, {
        'commandId': _refillId,
        'action': 'refill',
        'pillId': _serverPillId,
        'baseRevision': '3',
        'amount': 5,
        'note': null,
      });
      expect((await op(_refillId)).state, 'committed');
      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.revision, 4);
      // The acknowledgement never rewrites the phone's own count.
      expect(pill.currentStock, 10);
    },
  );

  test('an exact refill keeps its quantity and sends no unit', () async {
    await enqueue(_refillId, 'refill', {'refillQuantity': '2.5'});
    final result = await adapter.send(await op(_refillId));
    expect(result.status, MedicationMutationStatus.acknowledged);
    expect(posts.single['refillQuantity'], '2.5');
    expect(posts.single.containsKey('stockUnit'), isFalse);
    expect(posts.single.containsKey('amount'), isFalse);
  });

  test('a lost response replays the same request under the same id', () async {
    await enqueue(_refillId, 'refill', {'amount': 5});
    failNext = 1;
    final first = await adapter.send(await op(_refillId));
    expect(first.status, isNot(MedicationMutationStatus.acknowledged));
    // Another device moved the pill meanwhile; the replay must not rebase.
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(revision: Value(6)),
    );
    final replay = await adapter.send(await op(_refillId));
    expect(replay.status, MedicationMutationStatus.acknowledged);
    expect(posts, hasLength(2));
    expect(posts[1], posts[0]);
    expect(posts[1]['baseRevision'], '3');
    expect(posts[1]['commandId'], _refillId);
  });

  test('a refill waits behind the opening of the same pill', () async {
    await enqueue(_startId, 'start', {'initialStock': 10});
    await enqueue(_refillId, 'refill', {'amount': 5});
    final result = await adapter.send(await op(_refillId));
    expect(result.status, MedicationMutationStatus.waitingForMapping);
    expect(result.safeErrorCode, inventoryStartPendingCode);
    expect(posts, isEmpty);
    // The opening goes first, then the refill is free to go.
    expect(
      (await adapter.send(await op(_startId))).status,
      MedicationMutationStatus.acknowledged,
    );
    revisionAnswer = '5';
    (await f.db
        .update(f.db.pills)
        .write(const PillsCompanion(revision: Value(4))));
    final after = await adapter.send(await op(_refillId));
    expect(after.status, MedicationMutationStatus.acknowledged);
    expect(posts.last['action'], 'refill');
    expect(posts.last['baseRevision'], '4');
  });

  Future<void> mapProfile() =>
      (f.db.update(f.db.profiles)..where((p) => p.id.equals(f.pill.profileId)))
          .write(const ProfilesCompanion(serverId: Value('prof-server')));

  test('a stale base revision is refreshed and the refill resent', () async {
    await mapProfile();
    staleUntilRevision = 9;
    await enqueue(_refillId, 'refill', {'amount': 5});
    final result = await adapter.send(await op(_refillId));
    expect(result.status, MedicationMutationStatus.acknowledged);
    expect(posts, hasLength(2));
    expect(posts[0]['baseRevision'], '3');
    expect(posts[1]['baseRevision'], '9');
    expect(posts[1]['commandId'], _refillId);
    expect((await op(_refillId)).state, 'committed');
  });

  test('an unreadable server revision retries, never a review', () async {
    await mapProfile();
    staleUntilRevision = 9;
    serverRevision = null;
    await enqueue(_refillId, 'refill', {'amount': 5});
    final result = await adapter.send(await op(_refillId));
    expect(result.status, MedicationMutationStatus.retryable);
    expect(result.status, isNot(MedicationMutationStatus.conflict));
    expect((await op(_refillId)).state, isNot('conflict'));
  });

  group('the recount mark after a stock command settles', () {
    Future<void> markLocal() =>
        (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
          const PillsCompanion(stockNeedsRecount: Value(true)),
        );
    Future<bool> mark() async =>
        (await f.db.pillsDao.getById(f.pill.id))!.stockNeedsRecount;

    test(
      'takes a clear another device made while the command was unsent',
      () async {
        await mapProfile();
        await markLocal();
        await enqueue(_refillId, 'refill', {'amount': 5});
        await adapter.send(await op(_refillId));
        expect(await mark(), isFalse);
      },
    );

    test('keeps a mark the server still holds', () async {
      await mapProfile();
      await markLocal();
      serverMark = true;
      await enqueue(_refillId, 'refill', {'amount': 5});
      await adapter.send(await op(_refillId));
      expect(await mark(), isTrue);
    });

    test('waits while another stock command of the pill is unsent', () async {
      await mapProfile();
      await markLocal();
      await enqueue(_refillId, 'refill', {'amount': 5});
      await enqueue('30000000-0000-4000-8000-0000000000d2', 'refill', {
        'amount': 1,
      });
      await adapter.send(await op(_refillId));
      expect(await mark(), isTrue);
    });

    test('waits while a dose of the pill is unsent', () async {
      await mapProfile();
      await markLocal();
      // A dose whose amount the count could not hold set the mark here; the
      // server has not heard of it, so its "no mark" is not an answer yet.
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'op-dose',
          userId: userId,
          mutationId: '30000000-0000-4000-8000-0000000000f1',
          component: 'medication',
          operationType: 'medication.command',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'command': {
              'commandId': '30000000-0000-4000-8000-0000000000f1',
              'action': 'take',
            },
            'localProjection': {'pillId': f.pill.id},
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await enqueue(_refillId, 'refill', {'amount': 5});
      await adapter.send(await op(_refillId));
      expect(await mark(), isTrue);
    });

    test(
      'an unreadable answer leaves the mark and the command committed',
      () async {
        await mapProfile();
        await markLocal();
        serverRevision = null;
        await enqueue(_refillId, 'refill', {'amount': 5});
        final result = await adapter.send(await op(_refillId));
        expect(result.status, MedicationMutationStatus.acknowledged);
        expect(await mark(), isTrue);
      },
    );
  });

  test('an unsent refill protects the phone count from a pull', () async {
    await enqueue(_refillId, 'refill', {'amount': 5});
    expect(await unsettledInventoryPillIds(f.db, userId), {f.pill.id});
  });

  test('a held opening subtracts the unsent refill and keeps a dose', () async {
    Future<void> event(String id, String command, String kind, String delta) =>
        f.db.medicationLedgerDao.appendInventoryEvent(
          InventoryEventsCompanion.insert(
            id: id,
            userId: userId,
            pillId: f.pill.id,
            commandId: command,
            kind: kind,
            delta: delta,
            origin: 'native',
            recordedAt: DateTime.now().toUtc(),
          ),
        );
    await enqueue(_startId, 'start', {'initialStock': 10});
    await enqueue(_refillId, 'refill', {'amount': 5});
    await event('e-open', _startId, 'opening', '10');
    // A bridge-era dose the server never saw, then the unsent refill.
    await event('e-dose', 'bridge-dose', 'dose', '-1');
    await event('e-refill', _refillId, 'refill', '5');
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(currentStock: Value(14)),
    );
    final result = await adapter.send(await op(_startId));
    expect(result.status, MedicationMutationStatus.acknowledged);
    // 14 on the phone, minus the 5 still to be sent: the dose is folded in.
    expect(posts.single['initialStock'], 9);
  });

  group('an acknowledgement ahead of the phone', () {
    // The fixture's own creates are long since sent in these stories.
    setUp(
      () => f.db
          .update(f.db.pendingOperations)
          .write(const PendingOperationsCompanion(state: Value('committed'))),
    );

    Map<String, Object?> fullRow(String name) => {
      'name': name,
      'dosage': null,
      'notes': null,
      'color': null,
      'currentStock': 15,
      'lowStockThreshold': null,
      'isPrn': false,
      'deletedAt': null,
      'updatedAt': '2026-10-13T08:00:00.000Z',
    };

    test('after a rebase on an older server the server row is taken, so the '
        'next edit carries a current base', () async {
      await mapProfile();
      staleUntilRevision = 9;
      revisionAnswer = '10';
      serverRevision = '10';
      serverRow = fullRow('Renamed elsewhere');
      await enqueue(_refillId, 'refill', {'amount': 5});
      final result = await adapter.send(await op(_refillId));
      expect(result.status, MedicationMutationStatus.acknowledged);
      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      // Revision and content together: the other device's rename is not
      // hidden behind a revision the phone never saw the content of.
      expect(pill.revision, 10);
      expect(pill.name, 'Renamed elsewhere');
      expect(pill.currentStock, 15);
      expect(pill.syncStatus, 'synced');
    });

    test('a pill holding an unsent edit is left for the pull', () async {
      await mapProfile();
      staleUntilRevision = 9;
      revisionAnswer = '10';
      serverRevision = '10';
      serverRow = fullRow('Renamed elsewhere');
      await (f.db.update(
        f.db.pills,
      )..where((p) => p.id.equals(f.pill.id))).write(
        const PillsCompanion(
          name: Value('Edited here'),
          syncStatus: Value('pending'),
        ),
      );
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'op-edit',
          userId: userId,
          mutationId: '30000000-0000-4000-8000-0000000000e1',
          component: 'stable',
          operationType: 'pill.update',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'entityType': 'pill',
            'entityLocalId': f.pill.id,
            'action': 'update',
            'data': {'name': 'Edited here'},
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await enqueue(_refillId, 'refill', {'amount': 5});
      await adapter.send(await op(_refillId));
      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.name, 'Edited here');
      expect(pill.revision, 3);
    });

    test('the refresh keeps a recount mark an unsent dose may have set, and '
        'still takes the rest of the server row', () async {
      await mapProfile();
      staleUntilRevision = 9;
      revisionAnswer = '10';
      serverRevision = '10';
      serverMark = false;
      serverRow = fullRow('Renamed elsewhere');
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(stockNeedsRecount: Value(true)));
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'op-dose',
          userId: userId,
          mutationId: '30000000-0000-4000-8000-0000000000f2',
          component: 'medication',
          operationType: 'medication.command',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'command': {
              'commandId': '30000000-0000-4000-8000-0000000000f2',
              'action': 'take',
            },
            'localProjection': {'pillId': f.pill.id},
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await enqueue(_refillId, 'refill', {'amount': 5});
      final result = await adapter.send(await op(_refillId));
      expect(result.status, MedicationMutationStatus.acknowledged);
      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.revision, 10);
      expect(pill.name, 'Renamed elsewhere');
      expect(pill.stockNeedsRecount, isTrue, reason: 'the dose is unsent');
    });

    test('the refresh leaves a pill with a held stock edit alone', () async {
      await mapProfile();
      staleUntilRevision = 9;
      revisionAnswer = '10';
      serverRevision = '10';
      serverMark = false;
      serverRow = fullRow('Renamed elsewhere');
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(stockNeedsRecount: Value(true)));
      await enqueue(_refillId, 'refill', {'amount': 5});
      // A count saved after the refill, still waiting to go.
      await enqueue('30000000-0000-4000-8000-0000000000c8', 'correct', {
        'targetStock': 7,
      });
      final result = await adapter.send(await op(_refillId));
      expect(result.status, MedicationMutationStatus.acknowledged);
      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.name, isNot('Renamed elsewhere'));
      expect(pill.currentStock, 10);
      expect(pill.stockNeedsRecount, isTrue);
      expect(pill.revision, lessThan(10));
    });

    test('a name edit after a count and before its ack is kept and still '
        'sent', () async {
      await mapProfile();
      const countId = '30000000-0000-4000-8000-0000000000c7';
      await enqueue(countId, 'correct', {'targetStock': 8});
      // The rename is saved after the count and waits behind it.
      await (f.db.update(
        f.db.pills,
      )..where((p) => p.id.equals(f.pill.id))).write(
        const PillsCompanion(
          name: Value('Renamed here'),
          syncStatus: Value('pending'),
        ),
      );
      await f.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'op-rename',
          userId: userId,
          mutationId: '30000000-0000-4000-8000-0000000000e7',
          component: 'stable',
          operationType: 'pill.update',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'entityType': 'pill',
            'entityLocalId': f.pill.id,
            'action': 'update',
            'data': {'name': 'Renamed here'},
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      revisionAnswer = '4';
      serverRow = fullRow('Old name');
      final result = await adapter.send(await op(countId));
      expect(result.status, MedicationMutationStatus.acknowledged);
      var pill = (await f.db.pillsDao.getById(f.pill.id))!;
      // The count's revision is adopted, so the rename goes with base 4.
      expect(pill.revision, 4);
      expect(pill.name, 'Renamed here');
      expect(pill.syncStatus, 'pending', reason: 'the rename is unsent');

      // The pull carries the count's change with the old name: the unsent
      // rename is not overwritten.
      await StableRecordMerger(
        f.db,
        reviews: AccountSettlementMerger(f.db),
      ).mergePill(
        {
          ...fullRow('Old name'),
          'id': _serverPillId,
          'profileId': 'prof-server',
          'revision': '4',
          'createdAt': '2026-10-01T08:00:00.000Z',
        },
        {'prof-server': f.pill.profileId},
        {},
        userId: userId,
      );
      pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.name, 'Renamed here');
      expect(pill.revision, 4);
      expect(pill.syncStatus, 'pending');
    });

    test('a new server answering one step ahead needs no read', () async {
      await mapProfile();
      revisionAnswer = '4';
      serverRow = fullRow('Never read');
      await enqueue(_refillId, 'refill', {'amount': 5});
      await adapter.send(await op(_refillId));
      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.revision, 4);
      expect(pill.name, isNot('Never read'));
    });

    test('a new-server ack with a gap, then a pull, ends on the server '
        'revision and content', () async {
      await mapProfile();
      // Another device moved the pill to 5; the refill made it 6. The row
      // read back is the server's truth at 6, exactly what the pull carries.
      revisionAnswer = '6';
      serverRevision = '6';
      serverRow = fullRow('Renamed on the tablet');
      await enqueue(_refillId, 'refill', {'amount': 5});
      await adapter.send(await op(_refillId));
      var pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.revision, 6);
      // The pull then replays the older stable change (revision 5): it may
      // set its content, but never moves the revision back.
      await StableRecordMerger(
        f.db,
        reviews: AccountSettlementMerger(f.db),
      ).mergePill(
        {
          ...fullRow('Renamed on the tablet'),
          'id': _serverPillId,
          'profileId': 'prof-server',
          'revision': '5',
          'createdAt': '2026-10-01T08:00:00.000Z',
        },
        {'prof-server': f.pill.profileId},
        {},
        userId: userId,
      );
      pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.revision, 6);
      expect(pill.name, 'Renamed on the tablet');
    });
  });

  test('a crash between the rebase write and the resend replays the '
      'rebased request under the same id', () async {
    await mapProfile();
    staleUntilRevision = 9;
    revisionAnswer = '10';
    serverRevision = '9';
    failNext = 1;
    await enqueue(_refillId, 'refill', {'amount': 5});
    final first = await adapter.send(await op(_refillId));
    expect(first.status, isNot(MedicationMutationStatus.acknowledged));
    final frozen =
        (jsonDecode((await op(_refillId)).payloadJson)
            as Map)['resolvedInventoryRequest'];
    expect((frozen as Map)['baseRevision'], '9');
    // The process dies with the operation still marked as sending.
    await (f.db.update(f.db.pendingOperations)
          ..where((row) => row.id.equals('op-$_refillId')))
        .write(const PendingOperationsCompanion(state: Value('sending')));
    await f.db.pendingOperationsDao.recoverInterruptedOperations();
    posts.clear();
    final replay = await adapter.send(await op(_refillId));
    expect(replay.status, MedicationMutationStatus.acknowledged);
    expect(posts, hasLength(1));
    expect(posts.single['baseRevision'], '9');
    expect(posts.single['commandId'], _refillId);
    expect((await op(_refillId)).state, 'committed');
  });
}
