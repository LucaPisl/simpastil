import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
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
