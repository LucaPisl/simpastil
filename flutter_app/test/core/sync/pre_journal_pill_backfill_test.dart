import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/pre_journal_pill_backfill.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _owner = '10000000-0000-4000-8000-000000000801';
const _profile = '10000000-0000-4000-8000-000000000802';
const _pill = '10000000-0000-4000-8000-000000000803';
const _other = '10000000-0000-4000-8000-000000000804';
final _at = DateTime.utc(2026, 10, 23, 8);

/// An edit saved by the older, unjournaled writer whose PATCH failed left the
/// pill flagged unsent with nothing in the journal. On a versioned server only
/// the journal is sent, so the edit has to move into it once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProtectedWorkspaceFixture w;

  setUp(() async {
    w = await ProtectedWorkspaceFixture.create(ownerId: _owner);
    await w.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _owner,
        name: 'Fictional person',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        revision: const Value(2),
        syncStatus: const Value('synced'),
      ),
    );
  });
  tearDown(() async => w.db.close());

  Future<void> pill(
    String id, {
    String name = 'Edited offline',
    String syncStatus = 'pending',
    bool known = true,
    bool deleted = false,
  }) => w.db.pillsDao.upsert(
    PillsCompanion.insert(
      id: id,
      profileId: _profile,
      name: name,
      dosage: const Value('10 mg'),
      createdAt: _at,
      updatedAt: _at,
      serverId: Value(known ? id : null),
      revision: Value(known ? 4 : 0),
      syncStatus: Value(syncStatus),
      isDeleted: Value(deleted),
      shape: const Value('round'),
      expiresOn: const Value('2027-02-01'),
    ),
  );

  Future<PreJournalPillBackfill> backfill({
    Future<void> Function(String pillId)? beforeQueue,
  }) async => PreJournalPillBackfill(
    db: w.db,
    writeScope: SyncWriteScope(
      access: w.access,
      capability: await w.access.currentNetworkCapability(),
    ),
    beforeQueue: beforeQueue,
  );

  Future<List<PendingOperation>> queue() =>
      w.db.pendingOperationsDao.getForUser(_owner);

  Map<String, Object?> payloadOf(PendingOperation operation) =>
      (jsonDecode(operation.payloadJson) as Map).cast<String, Object?>();

  test('an unjournaled unsent pill is queued once as a full update', () async {
    await pill(_pill);
    await pill(_other, name: 'Untouched', syncStatus: 'synced');

    expect(await (await backfill()).run(userId: _owner), 1);
    // The queued update is now the pill's journal history.
    expect(await (await backfill()).run(userId: _owner), 0);

    final operation = (await queue()).single;
    expect(operation.operationType, 'pill.update');
    final payload = payloadOf(operation);
    expect(payload['entityLocalId'], _pill);
    final data = (payload['data']! as Map).cast<String, Object?>();
    expect(data['name'], 'Edited offline');
    expect(data['dosage'], '10 mg');
    expect(data['shape'], 'round');
    expect(data['expiresOn'], '2027-02-01');
    expect((await w.db.pillsDao.getById(_pill))!.syncStatus, 'pending');
  });

  test('a pill the journal already knows is left to the journal', () async {
    await pill(_pill);
    await w.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'earlier',
        userId: _owner,
        mutationId: 'm-earlier',
        component: 'stable',
        operationType: 'pill.update',
        contractVersion: 2,
        state: const Value('committed'),
        payloadJson: jsonEncode({
          'entityType': 'pill',
          'entityLocalId': _pill,
          'action': 'update',
          'data': {'name': 'Edited offline'},
        }),
        createdAt: _at,
      ),
    );

    expect(await (await backfill()).run(userId: _owner), 0);
    expect(await queue(), hasLength(1));
  });

  test('an unreadable journal entry queues nothing', () async {
    await pill(_pill);
    await w.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'garbled',
        userId: _owner,
        mutationId: 'm-garbled',
        component: 'stable',
        operationType: 'pill.update',
        contractVersion: 2,
        payloadJson: '{not json',
        createdAt: _at,
      ),
    );

    expect(await (await backfill()).run(userId: _owner), 0);
    expect(await queue(), hasLength(1));
  });

  test('a pill the server never received is not an edit to resend', () async {
    await pill(_pill, known: false);
    expect(await (await backfill()).run(userId: _owner), 0);
    expect(await queue(), isEmpty);
  });

  test('a deleted unjournaled pill is queued as a delete', () async {
    await pill(_pill, deleted: true);
    expect(await (await backfill()).run(userId: _owner), 1);
    final operation = (await queue()).single;
    expect(operation.operationType, 'pill.delete');
    expect(payloadOf(operation)['action'], 'delete');
  });

  test('on a versioned server the queued edit reaches it and the pill '
      'settles', () async {
    await pill(_pill);
    await (await backfill()).run(userId: _owner);
    final operation = (await queue()).single;

    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {'id': _pill, 'revision': '5'},
            ),
          );
        },
      ),
    );
    final result = await V2StableAdapter(
      db: w.db,
      dio: dio,
      writeScope: SyncWriteScope(
        access: w.access,
        capability: await w.access.currentNetworkCapability(),
      ),
    ).send(operation);
    await result.applyReceipt!();

    final request = requests.single;
    expect(request.method, 'PATCH');
    expect(request.path, contains(_pill));
    expect((request.data as Map)['name'], 'Edited offline');
    final settled = (await w.db.pillsDao.getById(_pill))!;
    expect(settled.syncStatus, 'synced');
    expect(settled.revision, 5);
    expect(settled.name, 'Edited offline');
  });

  test('an edit saved between the read and the queue is never followed by '
      'the older snapshot', () async {
    await pill(_pill);
    final runner = await backfill(
      beforeQueue: (pillId) async {
        // The person saves a newer edit as the sync starts: it is journaled
        // with the newer values and the row now holds them.
        final scope = SyncWriteScope(
          access: w.access,
          capability: await w.access.currentNetworkCapability(),
        );
        await PendingOperationRepository(
          w.db,
          access: scope.access,
          context: await scope.captureContext(),
        ).recordAtomically(
          operations: [
            PendingOperationDraft(
              userId: _owner,
              operationType: 'pill.update',
              entityType: 'pill',
              entityLocalId: pillId,
              parentEntityType: 'profile',
              parentEntityLocalId: _profile,
              payload: const {
                'action': 'update',
                'data': {'name': 'Newer edit'},
              },
            ),
          ],
          applyProjection: () async {
            await (w.db.update(w.db.pills)
                  ..where((row) => row.id.equals(pillId)))
                .write(const PillsCompanion(name: Value('Newer edit')));
          },
        );
      },
    );

    expect(await runner.run(userId: _owner), 0);
    final operation = (await queue()).single;
    final data = (payloadOf(operation)['data']! as Map).cast<String, Object?>();
    expect(data['name'], 'Newer edit');
  });

  test(
    'a pill that settled between the read and the queue is not queued',
    () async {
      await pill(_pill);
      final runner = await backfill(
        beforeQueue: (pillId) async {
          await (w.db.update(w.db.pills)..where((row) => row.id.equals(pillId)))
              .write(const PillsCompanion(syncStatus: Value('synced')));
        },
      );

      expect(await runner.run(userId: _owner), 0);
      expect(await queue(), isEmpty);
    },
  );

  test('the queued snapshot is read in the queuing transaction', () async {
    await pill(_pill);
    final runner = await backfill(
      beforeQueue: (pillId) async {
        // A change that writes no journal entry (for example a local-only
        // field) lands in the gap: the queued update carries it.
        await (w.db.update(w.db.pills)..where((row) => row.id.equals(pillId)))
            .write(const PillsCompanion(dosage: Value('20 mg')));
      },
    );

    expect(await runner.run(userId: _owner), 1);
    final data = (payloadOf((await queue()).single)['data']! as Map)
        .cast<String, Object?>();
    expect(data['dosage'], '20 mg');
  });
}
