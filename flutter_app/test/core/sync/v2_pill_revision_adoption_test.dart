import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

// A ledger stock move bumps pills.revision without a stable sync change. The
// acknowledgement must carry that revision to the phone, or the next pill
// PATCH / inventory command is rejected with CONFLICT_REVISION.
class _MockDio extends Mock implements Dio {}

const _serverOccurrenceId = '30000000-0000-4000-8000-000000000011';
const _serverPillId = '30000000-0000-4000-8000-000000000022';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late V2MedicationSyncAdapter adapter;
  late String takeCommandId;
  Map<String, Object?> Function(Map<String, dynamic>) answer = (_) => {};
  final posts = <Map<String, dynamic>>[];
  final gets = <String>[];
  Object? serverMark = false;

  setUp(() async {
    posts.clear();
    gets.clear();
    serverMark = false;
    f = await CareRecordingFixture.create(connected: true, legacyStock: 10);
    addTearDown(f.db.close);
    await (f.db.update(
      f.db.medicationOccurrences,
    )..where((r) => r.id.equals(f.occurrence.id))).write(
      const MedicationOccurrencesCompanion(
        serverId: Value(_serverOccurrenceId),
      ),
    );
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
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: context,
    );
    final take = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    takeCommandId = take.event.commandId;
    final dio = _MockDio();
    when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      posts.add(data);
      return Response(
        data: {'commandId': data['commandId'], ...answer(data)},
        requestOptions: RequestOptions(path: '/medication/commands'),
      );
    });
    when(() => dio.get<dynamic>(any())).thenAnswer((invocation) async {
      gets.add(invocation.positionalArguments.first as String);
      return Response(
        data: {
          'pills': [
            {
              'id': _serverPillId,
              'revision': '4',
              'stockNeedsRecount': serverMark,
            },
          ],
        },
        requestOptions: RequestOptions(path: '/x'),
      );
    });
    adapter = V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope);
  });

  Future<Pill> pill() async => (await f.db.pillsDao.getById(f.pill.id))!;

  Future<void> sendTake() async {
    final op = (await f.db.pendingOperationsDao.getByMutationId(
      f.workspace.context.ownerUserId,
      takeCommandId,
    ))!;
    final result = await adapter.send(op);
    expect(result.status, MedicationMutationStatus.acknowledged);
  }

  test('a take acknowledgement advances a synced pill revision', () async {
    answer = (_) => {'pillRevision': '4'};
    await sendTake();
    expect((await pill()).revision, 4);
  });

  test('a synced pill does not skip over another device edit', () async {
    // The server is at 5: another device edited (4), then this take (5).
    answer = (_) => {'pillRevision': '5'};
    await sendTake();
    expect((await pill()).revision, 3);
  });

  test('a pending pill edit adopts only its own one-step bump', () async {
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(name: Value('Edited'), syncStatus: Value('pending')),
    );
    answer = (_) => {'pillRevision': '4'};
    await sendTake();
    final row = await pill();
    expect(row.revision, 4);
    expect(row.name, 'Edited');
    expect(row.syncStatus, 'pending');
  });

  test('a pending pill edit does not hide another change', () async {
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(syncStatus: Value('pending')),
    );
    answer = (_) => {'pillRevision': '5'};
    await sendTake();
    expect((await pill()).revision, 3);
  });

  test('an acknowledgement without a revision changes nothing', () async {
    answer = (_) => {};
    await sendTake();
    expect((await pill()).revision, 3);
  });

  test('an inventory acknowledgement advances the pill revision', () async {
    final userId = f.workspace.context.ownerUserId;
    const commandId = '30000000-0000-4000-8000-0000000000c1';
    final command = {
      'commandId': commandId,
      'action': 'correct',
      'pillId': f.pill.id,
      'targetStock': 14,
      'note': null,
    };
    await f.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'op-inventory',
        userId: userId,
        mutationId: commandId,
        component: 'medication',
        operationType: 'inventory.correct',
        contractVersion: 2,
        payloadJson: jsonEncode({'inventoryCommand': command}),
        createdAt: DateTime.now().toUtc(),
      ),
    );
    answer = (_) => {'revision': '4'};
    final op = (await f.db.pendingOperationsDao.getById('op-inventory'))!;
    final result = await adapter.send(op);
    expect(result.status, MedicationMutationStatus.acknowledged);
    expect(posts.single['pillId'], _serverPillId);
    expect(posts.single['baseRevision'], '3');
    expect((await pill()).revision, 4);
  });

  group('the last stock acknowledgement clears a kept unsent flag', () {
    // An edit saved with a stock change: the edit's acknowledgement kept the
    // row unsent while the stock command waited.
    Future<void> enqueue(String id, String type, Object payload) =>
        f.db.pendingOperationsDao.enqueue(
          PendingOperationsCompanion.insert(
            id: id,
            userId: f.workspace.context.ownerUserId,
            mutationId: id == 'op-count'
                ? '30000000-0000-4000-8000-0000000000c2'
                : 'm-$id',
            component: type.startsWith('inventory') ? 'medication' : 'stable',
            operationType: type,
            contractVersion: 2,
            payloadJson: jsonEncode(payload),
            createdAt: DateTime.now().toUtc(),
          ),
        );

    Future<void> editWithCount({required String editState}) async {
      // The fixture's own create and take have been sent already.
      await f.db
          .update(f.db.pendingOperations)
          .write(const PendingOperationsCompanion(state: Value('committed')));
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(syncStatus: Value('pending')));
      await enqueue('op-edit', 'pill.update', {
        'entityType': 'pill',
        'entityLocalId': f.pill.id,
        'action': 'update',
        'data': {'name': 'Edited'},
      });
      await (f.db.update(f.db.pendingOperations)
            ..where((o) => o.id.equals('op-edit')))
          .write(PendingOperationsCompanion(state: Value(editState)));
      await enqueue('op-count', 'inventory.correct', {
        'entityType': 'pill',
        'entityLocalId': f.pill.id,
        'inventoryCommand': {
          'commandId': '30000000-0000-4000-8000-0000000000c2',
          'action': 'correct',
          'pillId': f.pill.id,
          'targetStock': 9,
          'note': null,
        },
      });
      answer = (_) => {'revision': '4'};
      final op = (await f.db.pendingOperationsDao.getById('op-count'))!;
      expect(
        (await adapter.send(op)).status,
        MedicationMutationStatus.acknowledged,
      );
    }

    test('once the edit has settled too', () async {
      await editWithCount(editState: 'committed');
      expect((await pill()).syncStatus, 'synced');
    });

    test('but not while the edit still waits', () async {
      await editWithCount(editState: 'queued');
      expect((await pill()).syncStatus, 'pending');
    });
  });

  group('a recount mark held back by this dose', () {
    Future<void> markLocal() async {
      await (f.db.update(f.db.profiles)
            ..where((p) => p.id.equals(f.pill.profileId)))
          .write(const ProfilesCompanion(serverId: Value('prof-server')));
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(stockNeedsRecount: Value(true)));
    }

    test('settles once the dose is acknowledged and the server has no '
        'mark', () async {
      await markLocal();
      answer = (_) => {'pillRevision': '4'};
      await sendTake();
      expect((await pill()).stockNeedsRecount, isFalse);
      expect(gets, ['/profiles/prof-server/pills']);
    });

    test('stays while the server still holds it', () async {
      await markLocal();
      serverMark = true;
      answer = (_) => {'pillRevision': '4'};
      await sendTake();
      expect((await pill()).stockNeedsRecount, isTrue);
    });

    test('a pill without a mark costs no read', () async {
      answer = (_) => {'pillRevision': '4'};
      await sendTake();
      expect(gets, isEmpty);
    });
  });
}
