import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/component_sync_pull_adapter.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/pill_unsent_work.dart';
import 'package:simpastil/core/sync/sync_models.dart';

// Builds before this fix left a pill flagged unsent once an edit and the
// stock command saved with it had both settled. The pull skipped that pill's
// server changes while the stable cursor moved past them, so an upgraded
// device must settle such rows and replay the stable component once.

class _MockDio extends Mock implements Dio {}

const _user = 'u1';
const _profile = '10000000-0000-4000-8000-000000000701';
const _stuck = '10000000-0000-4000-8000-000000000702';
const _busy = '10000000-0000-4000-8000-000000000703';
final _at = DateTime.utc(2026, 10, 22, 22);

Map<String, dynamic> _item(String sequence, String id, String name) => {
  'serverSequence': sequence,
  'change': {
    'schemaVersion': 2,
    'component': 'stable',
    'entityType': 'pill',
    'entityId': id,
    'operation': 'upsert',
    'sourceIdentity': {
      'sourceKind': 'pill',
      'sourceId': id,
      'sourceRevision': '13',
    },
    'payload': {
      'kind': 'pill',
      'id': id,
      'profileId': _profile,
      'revision': '13',
      'name': name,
      'dosage': '5mg',
      'notes': null,
      'color': null,
      'currentStock': 10,
      'lowStockThreshold': null,
      'isPrn': false,
      'deletedAt': null,
      'createdAt': '2026-10-22T19:55:42.260Z',
      'updatedAt': '2026-10-23T04:16:55.252Z',
    },
  },
};

void main() {
  late AppDatabase db;
  late _MockDio dio;
  late List<Map<String, dynamic>> requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({LedgerModeHint.key: true});
    db = AppDatabase.forTesting();
    dio = _MockDio();
    requests = [];
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _user,
        email: 'u@example.invalid',
        createdAt: _at,
        updatedAt: _at,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _user,
        name: 'Ana',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        revision: const Value(1),
        syncStatus: const Value('synced'),
      ),
    );
    for (final (id, name) in [(_stuck, 'Thirdmed'), (_busy, 'Halfmed')]) {
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: id,
          profileId: _profile,
          name: name,
          currentStock: const Value(9),
          createdAt: _at,
          updatedAt: _at,
          serverId: Value(id),
          revision: const Value(9),
          syncStatus: const Value('pending'),
        ),
      );
    }
    // The stuck row's edit and count both settled; the other row still has
    // an edit waiting to be sent.
    for (final (id, pill, state) in [
      ('edit', _stuck, 'committed'),
      ('waiting', _busy, 'queued'),
    ]) {
      await db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: id,
          userId: _user,
          mutationId: 'm-$id',
          component: 'stable',
          operationType: 'pill.update',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'entityType': 'pill',
            'entityLocalId': pill,
            'action': 'update',
            'data': {'name': 'Local'},
          }),
          createdAt: _at,
        ),
      );
      await (db.update(db.pendingOperations)..where((o) => o.id.equals(id)))
          .write(PendingOperationsCompanion(state: Value(state)));
    }
    // The cursor already moved past the server's revisions 10 to 13.
    await db.syncStateDao.saveState(
      SyncComponentStatesCompanion.insert(
        userId: _user,
        component: 'stable',
        contractVersion: 2,
        lastCompletedCursor: const Value('500'),
        lastFullSuccessAt: Value(DateTime.now().toUtc()),
        diagnosticMetadataJson: Value(
          jsonEncode({'projectionRevision': 'medication-details-v1'}),
        ),
      ),
    );
  });
  tearDown(() async => db.close());

  void serverAnswers({bool offline = false}) {
    when(
      () => dio.get<Map<String, dynamic>>(
        '/sync/stable',
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      requests.add(
        Map<String, dynamic>.from(
          invocation.namedArguments[#queryParameters] as Map,
        ),
      );
      if (offline) {
        throw DioException(
          requestOptions: RequestOptions(path: '/sync/stable'),
          type: DioExceptionType.connectionError,
        );
      }
      final after = requests.last['afterSequence'] as String? ?? '0';
      return Response(
        data: {
          'component': 'stable',
          'contractVersion': 2,
          'afterSequence': after,
          'throughSequence': '500',
          'items': [
            if (after == '0') ...[
              _item('480', _stuck, 'Thirdmed'),
              _item('490', _busy, 'Halfmed'),
            ],
          ],
          'hasMore': false,
          'nextCursor': null,
        },
        requestOptions: RequestOptions(path: '/sync/stable'),
      );
    });
  }

  // The stable stage of SyncService. [failAfterSettle] stops the merge after
  // the settle, as a crash inside the commit would.
  Future<void> stableStage({bool failAfterSettle = false}) async {
    final repair = await stablePendingSettleNeeded(db, _user);
    await ComponentSyncPullAdapter(db: db, dio: dio).pull(
      userId: _user,
      component: SyncComponent.stable,
      contractVersion: 2,
      projectionRevision: stablePendingSettleRevision,
      merge: (component, changes) async {
        if (repair) await settleIdlePendingPills(db, _user);
        if (failAfterSettle) throw StateError('interrupted');
        await ComponentSyncMerger(db).merge(_user, component, changes);
      },
    );
  }

  // The stable stage of an older build, which knows only [marker].
  Future<void> olderStableStage(String marker) =>
      ComponentSyncPullAdapter(db: db, dio: dio).pull(
        userId: _user,
        component: SyncComponent.stable,
        contractVersion: 2,
        projectionRevision: marker,
        merge: (component, changes) =>
            ComponentSyncMerger(db).merge(_user, component, changes),
      );

  Future<void> setMarker(String marker) =>
      (db.update(db.syncComponentStates)..where(
            (row) => row.userId.equals(_user) & row.component.equals('stable'),
          ))
          .write(
            SyncComponentStatesCompanion(
              diagnosticMetadataJson: Value(
                jsonEncode({'projectionRevision': marker}),
              ),
            ),
          );

  Future<Pill> pill(String id) async => (await db.pillsDao.getById(id))!;

  test('an upgraded device settles a stuck pill and replays its server '
      'changes once', () async {
    serverAnswers();
    expect(await stablePendingSettleNeeded(db, _user), isTrue);
    await stableStage();

    expect(requests.single.containsKey('afterSequence'), isFalse);
    final stuck = await pill(_stuck);
    expect(stuck.syncStatus, 'synced');
    expect(stuck.revision, 13);
    expect(stuck.dosage, '5mg');
    expect(stuck.currentStock, 10);
    expect(await stablePendingSettleNeeded(db, _user), isFalse);
    final state = (await db.syncStateDao.getState(_user, 'stable'))!;
    expect(state.lastCompletedCursor, '500');

    // The repair runs once: the next pull resumes from the cursor.
    await stableStage();
    expect(requests.last['afterSequence'], '500');
  });

  test('a pill with real unsent work is left untouched', () async {
    serverAnswers();
    await stableStage();

    final busy = await pill(_busy);
    expect(busy.syncStatus, 'pending');
    expect(busy.revision, 9);
    expect(busy.dosage, isNull);
    expect(busy.currentStock, 9);
  });

  test(
    'offline, the repair changes nothing and waits for the next sync',
    () async {
      serverAnswers(offline: true);
      await expectLater(stableStage(), throwsA(isA<DioException>()));

      expect((await pill(_stuck)).syncStatus, 'pending');
      expect(await stablePendingSettleNeeded(db, _user), isTrue);
      final state = (await db.syncStateDao.getState(_user, 'stable'))!;
      expect(state.lastCompletedCursor, '500');
    },
  );

  test('an unreadable journal entry keeps every row as it is', () async {
    await db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'garbled',
        userId: _user,
        mutationId: 'm-garbled',
        component: 'stable',
        operationType: 'pill.update',
        contractVersion: 2,
        payloadJson: '{not json',
        createdAt: _at,
      ),
    );
    expect(await settleIdlePendingPills(db, _user), 0);
    expect((await pill(_stuck)).syncStatus, 'pending');
  });

  test('a pending row the journal never flagged is left for its writer to '
      'send', () async {
    // An edit saved by the unjournaled writer whose legacy PATCH failed and
    // was only logged: the row is unsent, and nothing in the journal says so.
    await (db.delete(
      db.pendingOperations,
    )..where((o) => o.id.equals('edit'))).go();
    await (db.update(db.pills)..where((p) => p.id.equals(_stuck))).write(
      const PillsCompanion(name: Value('Edited offline')),
    );
    serverAnswers();
    await stableStage();

    final stuck = await pill(_stuck);
    expect(stuck.syncStatus, 'pending');
    expect(stuck.name, 'Edited offline');
    expect(stuck.revision, 9);
    expect(await stablePendingSettleNeeded(db, _user), isFalse);
  });

  test('a device on recorded-occurrence-link-v1 replays once', () async {
    await setMarker('recorded-occurrence-link-v1');
    serverAnswers();
    expect(await stablePendingSettleNeeded(db, _user), isTrue);
    await stableStage();

    expect(requests.single.containsKey('afterSequence'), isFalse);
    expect((await pill(_stuck)).syncStatus, 'synced');
    expect((await pill(_stuck)).revision, 13);
    await stableStage();
    expect(requests.last['afterSequence'], '500');
  });

  test('a downgrade then an upgrade replays again and lands the same '
      'way', () async {
    serverAnswers();
    await stableStage();
    expect((await pill(_stuck)).revision, 13);

    // The older build replays under its own marker and leaves it behind.
    await olderStableStage('medication-details-v1');
    expect(requests.last.containsKey('afterSequence'), isFalse);
    expect(await stablePendingSettleNeeded(db, _user), isTrue);

    // Back on this build, the replay runs once more and changes nothing.
    await stableStage();
    expect(requests.last.containsKey('afterSequence'), isFalse);
    final stuck = await pill(_stuck);
    expect(stuck.syncStatus, 'synced');
    expect(stuck.revision, 13);
    expect(stuck.currentStock, 10);
    expect((await pill(_busy)).syncStatus, 'pending');
    expect(await stablePendingSettleNeeded(db, _user), isFalse);
  });

  test('an interrupted replay rolls back the settle and runs again', () async {
    serverAnswers();
    await expectLater(
      stableStage(failAfterSettle: true),
      throwsA(isA<StateError>()),
    );

    expect((await pill(_stuck)).syncStatus, 'pending');
    expect(await stablePendingSettleNeeded(db, _user), isTrue);
    expect(
      (await db.syncStateDao.getState(_user, 'stable'))!.lastCompletedCursor,
      '500',
    );

    await stableStage();
    expect(requests.last.containsKey('afterSequence'), isFalse);
    expect((await pill(_stuck)).syncStatus, 'synced');
    expect((await pill(_stuck)).revision, 13);
    expect(await stablePendingSettleNeeded(db, _user), isFalse);
  });
}
