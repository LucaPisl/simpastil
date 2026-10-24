import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/medication_projection_merger.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';

const _user = 'u1';
const _profile = '10000000-0000-4000-8000-000000000501';
const _pill = '10000000-0000-4000-8000-000000000502';
final _at = DateTime.utc(2026, 10, 14, 8);

Map<String, dynamic> _serverPill(String revision, String name) => {
  'id': _pill,
  'profileId': _profile,
  'revision': revision,
  'name': name,
  'dosage': null,
  'notes': null,
  'color': null,
  'currentStock': 10,
  'lowStockThreshold': null,
  'isPrn': false,
  'deletedAt': null,
  'createdAt': '2026-10-14T08:00:00.000Z',
  'updatedAt': '2026-10-14T09:00:00.000Z',
};

void main() {
  late AppDatabase db;
  late StableRecordMerger merger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({LedgerModeHint.key: false});
    db = AppDatabase.forTesting();
    merger = StableRecordMerger(db, reviews: AccountSettlementMerger(db));
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
        name: 'P',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        syncStatus: const Value('synced'),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Alpha',
        currentStock: const Value(7),
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        revision: const Value(4),
        syncStatus: const Value('synced'),
      ),
    );
  });
  tearDown(() async => db.close());

  Future<void> enqueue(
    String id,
    String component,
    Map<String, Object?> body, {
    String? dependsOn,
  }) => db.pendingOperationsDao.enqueue(
    PendingOperationsCompanion.insert(
      id: id,
      userId: _user,
      mutationId: 'm-$id',
      component: component,
      operationType: component == 'stable'
          ? 'pill.update'
          : 'inventory.correct',
      contractVersion: 2,
      dependsOnOperationId: Value(dependsOn),
      payloadJson: jsonEncode({
        'entityType': 'pill',
        'entityLocalId': _pill,
        ...body,
      }),
      createdAt: _at,
    ),
  );

  Future<void> heldStock() => enqueue('stock', 'medication', {
    'inventoryCommand': {
      'commandId': 'c',
      'action': 'correct',
      'pillId': _pill,
      'targetStock': 7,
    },
  });

  Future<void> receipt() => enqueue('receipt', 'stable', {'name': 'Alpha'});

  Future<bool> otherIntent() async {
    final adapter = V2StableAdapter(db: db, dio: Dio());
    final current = (await db.pendingOperationsDao.getById('receipt'))!;
    return adapter.hasOtherIntent(current, 'pill', _pill);
  }

  test('a pill edit is released past a held stock, a delete is not', () async {
    await heldStock();
    await enqueue('edit', 'stable', {
      'action': 'update',
      'data': {'name': 'Edited'},
    }, dependsOn: 'stock');
    await enqueue('del', 'stable', {'action': 'delete'}, dependsOn: 'stock');
    final ready = await db.pendingOperationsDao.getReady(
      _user,
      ledgerActive: false,
    );
    expect(ready.map((o) => o.id), contains('edit'));
    expect(ready.map((o) => o.id), isNot(contains('del')));
  });

  test('a held stock command is not other intent for the pill', () async {
    await receipt();
    await heldStock();
    expect(await otherIntent(), isFalse);
  });

  test('stock is real pending intent once the ledger is active', () async {
    await receipt();
    await heldStock();
    for (final active in [true, null]) {
      SharedPreferences.setMockInitialValues({LedgerModeHint.key: ?active});
      expect(await otherIntent(), isTrue, reason: 'ledger active=$active');
    }
  });

  test('a real pending stable edit still counts beside a held stock', () async {
    await receipt();
    await heldStock();
    await enqueue('edit', 'stable', {'name': 'Edited'});
    expect(await otherIntent(), isTrue);
  });

  test('a server rename is adopted while stock is held, stock kept', () async {
    await heldStock();
    await merger.mergePill(
      _serverPill('5', 'Alpha-Server'),
      {_profile: _profile},
      {},
      userId: _user,
    );
    final pill = (await db.pillsDao.getById(_pill))!;
    expect(pill.name, 'Alpha-Server');
    expect(pill.revision, 5);
    expect(pill.syncStatus, 'synced');
    expect(pill.currentStock, 7, reason: 'stock stays on the phone');
  });

  test('without a held command the server stock is authoritative', () async {
    await merger.mergePill(
      _serverPill('5', 'Alpha-Server'),
      {_profile: _profile},
      {},
      userId: _user,
    );
    expect((await db.pillsDao.getById(_pill))!.currentStock, 10);
  });

  group('the recount mark', () {
    test('a server true is kept while a stock command is unsent', () async {
      await heldStock();
      await merger.mergePill(
        {..._serverPill('5', 'Alpha'), 'stockNeedsRecount': true},
        {_profile: _profile},
        {},
        userId: _user,
      );
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.stockNeedsRecount, isTrue);
      expect(pill.currentStock, 7, reason: 'stock stays on the phone');
    });

    test('a server false is applied when nothing is pending', () async {
      await (db.update(db.pills)..where((p) => p.id.equals(_pill))).write(
        const PillsCompanion(stockNeedsRecount: Value(true)),
      );
      await merger.mergePill(
        {..._serverPill('5', 'Alpha'), 'stockNeedsRecount': false},
        {_profile: _profile},
        {},
        userId: _user,
      );
      expect((await db.pillsDao.getById(_pill))!.stockNeedsRecount, isFalse);
    });

    test(
      'a local true survives a server false while stock is unsent',
      () async {
        await heldStock();
        await (db.update(db.pills)..where((p) => p.id.equals(_pill))).write(
          const PillsCompanion(stockNeedsRecount: Value(true)),
        );
        await merger.mergePill(
          {..._serverPill('5', 'Alpha'), 'stockNeedsRecount': false},
          {_profile: _profile},
          {},
          userId: _user,
        );
        expect((await db.pillsDao.getById(_pill))!.stockNeedsRecount, isTrue);
      },
    );
  });

  group('an unsent dose and the recount mark', () {
    Future<void> unsentDose({String? raw}) => db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'dose',
        userId: _user,
        mutationId: 'm-dose',
        component: 'medication',
        operationType: 'medication.command',
        contractVersion: 2,
        payloadJson:
            raw ??
            jsonEncode({
              'command': {'commandId': 'd', 'action': 'take'},
              'localProjection': {'pillId': _pill},
            }),
        createdAt: _at,
      ),
    );

    Future<void> markLocal() =>
        (db.update(db.pills)..where((p) => p.id.equals(_pill))).write(
          const PillsCompanion(stockNeedsRecount: Value(true)),
        );

    test('a local mark survives a server false; the count is the '
        'server\'s', () async {
      await unsentDose();
      await markLocal();
      await merger.mergePill(
        {..._serverPill('5', 'Alpha'), 'stockNeedsRecount': false},
        {_profile: _profile},
        {},
        userId: _user,
      );
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.stockNeedsRecount, isTrue);
      expect(pill.currentStock, 10, reason: 'only stock commands keep it');
    });

    test('an unreadable medication command holds the mark too', () async {
      await unsentDose(raw: 'not json');
      await markLocal();
      await merger.mergePill(
        {..._serverPill('5', 'Alpha'), 'stockNeedsRecount': false},
        {_profile: _profile},
        {},
        userId: _user,
      );
      expect((await db.pillsDao.getById(_pill))!.stockNeedsRecount, isTrue);
    });

    test('a dose of another pill does not hold this mark', () async {
      await db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'dose-other',
          userId: _user,
          mutationId: 'm-dose-other',
          component: 'medication',
          operationType: 'medication.command',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'command': {'commandId': 'd2', 'action': 'take'},
            'localProjection': {'pillId': 'another-pill'},
          }),
          createdAt: _at,
        ),
      );
      await markLocal();
      await merger.mergePill(
        {..._serverPill('5', 'Alpha'), 'stockNeedsRecount': false},
        {_profile: _profile},
        {},
        userId: _user,
      );
      expect((await db.pillsDao.getById(_pill))!.stockNeedsRecount, isFalse);
    });
  });

  group('a batch of changes reads the journal once', () {
    const second = '10000000-0000-4000-8000-000000000503';
    Map<String, dynamic> change(Map<String, dynamic> payload) => {
      'component': 'stable',
      'payload': {...payload, 'kind': 'pill'},
    };

    setUp(() async {
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: second,
          profileId: _profile,
          name: 'Beta',
          currentStock: const Value(3),
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(second),
          revision: const Value(4),
          syncStatus: const Value('synced'),
        ),
      );
    });

    test('and decides each pill as a single merge would', () async {
      await heldStock(); // keeps Alpha's count
      await (db.update(db.pills)..where((p) => p.id.equals(second))).write(
        const PillsCompanion(
          name: Value('Beta edited here'),
          syncStatus: Value('pending'),
        ),
      );
      await db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'beta-edit',
          userId: _user,
          mutationId: 'm-beta-edit',
          component: 'stable',
          operationType: 'pill.update',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'entityType': 'pill',
            'entityLocalId': second,
            'action': 'update',
            'data': {'name': 'Beta edited here'},
          }),
          createdAt: _at,
        ),
      );
      await ComponentSyncMerger(db).merge(_user, SyncComponent.stable, [
        change(_serverPill('5', 'Alpha from server')),
        change({..._serverPill('5', 'Beta from server'), 'id': second}),
      ]);
      final alpha = (await db.pillsDao.getById(_pill))!;
      expect(alpha.name, 'Alpha from server');
      expect(alpha.currentStock, 7, reason: 'the held stock keeps the count');
      final beta = (await db.pillsDao.getById(second))!;
      expect(beta.name, 'Beta edited here', reason: 'its edit is unsent');
      expect(beta.syncStatus, 'pending');
    });

    test('and an unreadable entry still guards every flagged pill', () async {
      await (db.update(db.pills)..where((p) => p.id.equals(second))).write(
        const PillsCompanion(
          name: Value('Beta edited here'),
          syncStatus: Value('pending'),
        ),
      );
      await db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'unreadable',
          userId: _user,
          mutationId: 'm-unreadable',
          component: 'stable',
          operationType: 'pill.update',
          contractVersion: 2,
          payloadJson: 'not json',
          createdAt: _at,
        ),
      );
      await ComponentSyncMerger(db).merge(_user, SyncComponent.stable, [
        change(_serverPill('5', 'Alpha from server')),
        change({..._serverPill('5', 'Beta from server'), 'id': second}),
      ]);
      expect((await db.pillsDao.getById(_pill))!.name, 'Alpha from server');
      expect((await db.pillsDao.getById(second))!.name, 'Beta edited here');
    });
  });

  test('a genuinely pending pill row is never overwritten', () async {
    await heldStock();
    await (db.update(db.pills)..where((p) => p.id.equals(_pill))).write(
      const PillsCompanion(
        name: Value('Local edit'),
        syncStatus: Value('pending'),
      ),
    );
    await merger.mergePill(
      _serverPill('5', 'Alpha-Server'),
      {_profile: _profile},
      {},
      userId: _user,
    );
    final pill = (await db.pillsDao.getById(_pill))!;
    expect(pill.name, 'Local edit');
    expect(pill.revision, 4);
  });

  test('the server bridge stock does not replace a held correction', () async {
    await heldStock();
    await MedicationProjectionMerger(db).mergeBridgeStock(
      _user,
      {
        'pillId': _pill,
        'currentStock': 10,
        'updatedAt': '2026-10-14T09:00:00.000Z',
      },
      {_pill: _pill},
    );
    expect((await db.pillsDao.getById(_pill))!.currentStock, 7);
  });

  group('an unsent start, ledger active (pull while it waits)', () {
    Future<void> unsentStart() => enqueue('start', 'medication', {
      'inventoryCommand': {
        'commandId': 'c',
        'action': 'start',
        'pillId': _pill,
        'initialStock': 10,
      },
    });

    test('the stable pull keeps the phone count', () async {
      SharedPreferences.setMockInitialValues({LedgerModeHint.key: true});
      await unsentStart();
      await merger.mergePill(
        {..._serverPill('5', 'Alpha-Server'), 'currentStock': null},
        {_profile: _profile},
        {},
        userId: _user,
      );
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.name, 'Alpha-Server');
      expect(pill.currentStock, 7);
    });

    test('the bridge stock projection keeps the phone count', () async {
      SharedPreferences.setMockInitialValues({LedgerModeHint.key: true});
      await unsentStart();
      await MedicationProjectionMerger(db).mergeBridgeStock(
        _user,
        {
          'pillId': _pill,
          'currentStock': null,
          'updatedAt': '2026-10-14T09:00:00.000Z',
        },
        {_pill: _pill},
      );
      expect((await db.pillsDao.getById(_pill))!.currentStock, 7);
    });
  });
}
