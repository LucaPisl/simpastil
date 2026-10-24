import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';

// An edit saved together with a stock change (or a confirmed count) records a
// pill.update and a stock command. The edit's acknowledgement kept the row
// unsent while the command waited; the command's acknowledgement never
// cleared it, so every later server change to the pill was skipped for good:
// one device kept an old count and missed the other's dosage text.

const _user = 'u1';
const _profile = '10000000-0000-4000-8000-000000000601';
const _pill = '10000000-0000-4000-8000-000000000602';
final _at = DateTime.utc(2026, 10, 22, 22);

Map<String, dynamic> _serverPill(
  String revision, {
  String? dosage = '5mg',
  num stock = 10,
  String? deletedAt,
}) => {
  'id': _pill,
  'profileId': _profile,
  'revision': revision,
  'name': 'Thirdmed',
  'dosage': dosage,
  'notes': null,
  'color': null,
  'currentStock': stock,
  'lowStockThreshold': null,
  'isPrn': false,
  'deletedAt': deletedAt,
  'createdAt': '2026-10-22T19:55:42.260Z',
  'updatedAt': '2026-10-23T04:16:55.252Z',
};

void main() {
  late AppDatabase db;
  late StableRecordMerger merger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({LedgerModeHint.key: true});
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
        name: 'Ana',
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
        name: 'Thirdmed',
        currentStock: const Value(9),
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        revision: const Value(8),
        syncStatus: const Value('pending'),
      ),
    );
  });
  tearDown(() async => db.close());

  Future<void> enqueue(
    String id,
    String component,
    Map<String, Object?> body,
  ) => db.pendingOperationsDao.enqueue(
    PendingOperationsCompanion.insert(
      id: id,
      userId: _user,
      mutationId: 'm-$id',
      component: component,
      operationType: component == 'stable'
          ? 'pill.update'
          : 'inventory.correct',
      contractVersion: 2,
      payloadJson: jsonEncode({
        'entityType': 'pill',
        'entityLocalId': _pill,
        ...body,
      }),
      createdAt: _at,
    ),
  );

  Future<void> editWithCount() async {
    await enqueue('edit', 'stable', {
      'action': 'update',
      'data': {'name': 'Thirdmed'},
    });
    await enqueue('count', 'medication', {
      'inventoryCommand': {
        'commandId': 'c',
        'action': 'correct',
        'pillId': _pill,
        'targetStock': 9,
      },
    });
  }

  Future<void> commit(String id) async {
    await (db.update(db.pendingOperations)..where((o) => o.id.equals(id)))
        .write(const PendingOperationsCompanion(state: Value('committed')));
  }

  Future<void> pull(Map<String, dynamic> item) =>
      merger.mergePill(item, {_profile: _profile}, {}, userId: _user);

  test('an edit saved with a count takes server changes once both '
      'settled', () async {
    await editWithCount();
    final adapter = V2StableAdapter(db: db, dio: Dio());
    final edit = (await db.pendingOperationsDao.getById('edit'))!;
    await adapter.markLocalReceipt(edit, 'pill', _pill, _pill, 9);
    await commit('edit');
    // The edit's receipt keeps the row unsent while the count waits.
    expect((await db.pillsDao.getById(_pill))!.syncStatus, 'pending');
    await commit('count');

    await pull(_serverPill('13'));

    final pill = (await db.pillsDao.getById(_pill))!;
    expect(pill.syncStatus, 'synced');
    expect(pill.revision, 13);
    expect(pill.dosage, '5mg');
    expect(pill.currentStock, 10);
  });

  test('an unsent edit still keeps the server copy out', () async {
    await editWithCount();
    await commit('count');
    await pull(_serverPill('13'));
    final pill = (await db.pillsDao.getById(_pill))!;
    expect(pill.syncStatus, 'pending');
    expect(pill.revision, 8);
    expect(pill.dosage, isNull);
    expect(pill.currentStock, 9);
  });

  test('an unsent stock command still keeps the row as it is', () async {
    await editWithCount();
    await commit('edit');
    await pull(_serverPill('13'));
    final pill = (await db.pillsDao.getById(_pill))!;
    expect(pill.revision, 8);
    expect(pill.dosage, isNull);
    expect(pill.currentStock, 9);
  });

  test('an unsettled effect on the pill keeps the row as it is', () async {
    await db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'legacy',
        userId: _user,
        mutationId: 'm-legacy',
        component: 'medication',
        operationType: 'legacy_stock_write',
        contractVersion: 1,
        payloadJson: jsonEncode({'sourceId': _pill, 'currentStock': 9}),
        state: const Value('blocked'),
        createdAt: _at,
      ),
    );
    await db
        .into(db.pendingOperationEffects)
        .insert(
          PendingOperationEffectsCompanion.insert(
            id: 'effect',
            operationId: 'legacy',
            ordinal: 0,
            kind: 'inventory',
            legacySourceId: const Value(_pill),
            requestFingerprint: 'f',
            state: const Value('uncertain'),
            attemptedAt: Value(_at),
          ),
        );
    await pull(_serverPill('13'));
    expect((await db.pillsDao.getById(_pill))!.currentStock, 9);
  });

  test('a settled row left marked unsent takes a server deletion', () async {
    await editWithCount();
    await commit('edit');
    await commit('count');
    await pull(_serverPill('14', deletedAt: '2026-10-23T05:00:00.000Z'));
    final pill = (await db.pillsDao.getById(_pill))!;
    expect(pill.isDeleted, isTrue);
    expect(pill.syncStatus, 'synced');
  });
}
