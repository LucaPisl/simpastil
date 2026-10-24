import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/component_sync_pull_adapter.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  late AppDatabase db;
  late _MockDio dio;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dio = _MockDio();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: 'user-1',
            email: 'user@test.com',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
  });

  tearDown(() => db.close());

  test(
    'restarts component traversal before server tombstone retention ends',
    () {
      final now = DateTime.utc(2026, 9, 25);
      final checkpointAt88Days = now.subtract(const Duration(days: 88));
      final checkpointAt89Days = now.subtract(const Duration(days: 89));

      expect(
        initialComponentAfterSequence(
          contractVersion: 2,
          completedContractVersion: 2,
          completedSequence: '120',
          lastCompletedAt: checkpointAt88Days,
          now: now,
        ),
        '120',
      );
      expect(
        initialComponentAfterSequence(
          contractVersion: 2,
          completedContractVersion: 2,
          completedSequence: '120',
          lastCompletedAt: checkpointAt89Days,
          now: now,
        ),
        '0',
      );
      expect(clientTombstoneReplayWindowDays, lessThan(90));
    },
  );

  test('resets checkpoints when a component contract changes', () {
    expect(
      initialComponentAfterSequence(
        contractVersion: 2,
        completedContractVersion: 1,
        completedSequence: '120',
        lastCompletedAt: DateTime.utc(2026, 9, 24),
        now: DateTime.utc(2026, 9, 25),
      ),
      '0',
    );
  });

  test(
    'page failure discards staged rows and preserves the prior checkpoint',
    () async {
      await _seedStableCheckpoint(db, '5');
      var callCount = 0;
      when(
        () => dio.get<Map<String, dynamic>>(
          '/sync/stable',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return _response(
            _page(
              afterSequence: '5',
              throughSequence: '11',
              items: [_change('profile-1')],
              hasMore: true,
              nextCursor: 'page-2',
            ),
          );
        }
        throw DioException(
          requestOptions: RequestOptions(path: '/sync/stable'),
        );
      });
      var mergeCalls = 0;

      await expectLater(
        ComponentSyncPullAdapter(db: db, dio: dio).pull(
          userId: 'user-1',
          component: SyncComponent.stable,
          contractVersion: 2,
          merge: (component, changes) async {
            mergeCalls++;
          },
        ),
        throwsA(isA<DioException>()),
      );

      expect(mergeCalls, 0);
      expect(
        (await db.syncStateDao.getState(
          'user-1',
          'stable',
        ))?.lastCompletedCursor,
        '5',
      );
      expect(await db.select(db.syncStagingRuns).get(), isEmpty);
    },
  );

  test(
    'merge failure is classified before failing cleanup without publishing data',
    () async {
      await _seedStableCheckpoint(db, '5');
      // A disposable SQLite trigger reproduces cleanup masking the merge error.
      await db.customStatement('''
        CREATE TRIGGER reject_staging_cleanup BEFORE DELETE ON sync_staging_runs
        BEGIN SELECT RAISE(ABORT, 'private-cleanup-message'); END;
      ''');
      when(
        () => dio.get<Map<String, dynamic>>(
          '/sync/stable',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => _response(
          _page(
            afterSequence: '5',
            throughSequence: '11',
            items: [_change('profile-1')],
            hasMore: false,
            nextCursor: null,
          ),
        ),
      );
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);
      const failure = FormatException('private-medication private-owner');

      await expectLater(
        ComponentSyncPullAdapter(db: db, dio: dio).pull(
          userId: 'user-1',
          component: SyncComponent.stable,
          contractVersion: 2,
          merge: (_, changes) async {
            await db
                .into(db.profiles)
                .insert(
                  ProfilesCompanion.insert(
                    id: 'profile-1',
                    userId: 'user-1',
                    name: 'private-medication',
                    createdAt: DateTime.now(),
                    updatedAt: DateTime.now(),
                  ),
                );
            throw failure;
          },
        ),
        throwsA(same(failure)),
      );

      final events = messages
          .where((line) => line.contains('[SyncDiag]'))
          .map((line) => jsonDecode(line.split('[SyncDiag] ').last) as Map)
          .toList();
      expect(events, hasLength(2));
      expect(events.first['phase'], 'merge_apply');
      expect(events.first['category'], 'format');
      expect(events.last['phase'], 'staging_discard');
      expect(events.last['category'], 'sqlite');
      expect(events.last['sqliteCode'], 19);
      expect(events.last['sqliteExtendedCode'], 1811);
      expect(events.toString(), isNot(contains('private')));
      expect(events.toString(), isNot(contains('user-1')));
      expect(await db.select(db.profiles).get(), isEmpty);
      expect(
        (await db.syncStateDao.getState(
          'user-1',
          'stable',
        ))?.lastCompletedCursor,
        '5',
      );
    },
  );

  test(
    'final page merges all staged changes before advancing the checkpoint',
    () async {
      await _seedStableCheckpoint(db, '5');
      when(
        () => dio.get<Map<String, dynamic>>(
          '/sync/stable',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => _response(
          _page(
            afterSequence: '5',
            throughSequence: '11',
            items: [_change('profile-1')],
            hasMore: false,
            nextCursor: null,
          ),
        ),
      );
      List<Map<String, dynamic>>? merged;

      final result = await ComponentSyncPullAdapter(db: db, dio: dio).pull(
        userId: 'user-1',
        component: SyncComponent.stable,
        contractVersion: 2,
        merge: (component, changes) async {
          merged = changes;
        },
      );

      expect(result, '11');
      expect(merged, hasLength(1));
      expect(
        (await db.syncStateDao.getState(
          'user-1',
          'stable',
        ))?.lastCompletedCursor,
        '11',
      );
      expect(await db.select(db.syncStagingRuns).get(), isEmpty);
    },
  );
  test(
    'projection replay publishes marker only with successful atomic merge',
    () async {
      await _seedStableCheckpoint(db, '5');
      final requests = <Map<String, dynamic>>[];
      when(
        () => dio.get<Map<String, dynamic>>(
          '/sync/stable',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((invocation) async {
        final query = Map<String, dynamic>.from(
          invocation.namedArguments[#queryParameters] as Map,
        );
        requests.add(query);
        return _response(
          _page(
            afterSequence: query['afterSequence'] as String? ?? '0',
            throughSequence: '11',
            items: [],
            hasMore: false,
            nextCursor: null,
          ),
        );
      });
      final adapter = ComponentSyncPullAdapter(db: db, dio: dio);
      await expectLater(
        adapter.pull(
          userId: 'user-1',
          component: SyncComponent.stable,
          contractVersion: 2,
          projectionRevision: 'schedule-zone-v1',
          merge: (_, _) async {
            throw const FormatException('fictional refusal');
          },
        ),
        throwsFormatException,
      );
      final refused = await db.syncStateDao.getState('user-1', 'stable');
      expect(refused!.lastCompletedCursor, '5');
      expect(refused.diagnosticMetadataJson, isNull);
      expect(requests.single.containsKey('afterSequence'), isFalse);
      await adapter.pull(
        userId: 'user-1',
        component: SyncComponent.stable,
        contractVersion: 2,
        projectionRevision: 'schedule-zone-v1',
        merge: (_, _) async {},
      );
      final accepted = await db.syncStateDao.getState('user-1', 'stable');
      expect(accepted!.lastCompletedCursor, '11');
      expect(
        jsonDecode(accepted.diagnosticMetadataJson!)['projectionRevision'],
        'schedule-zone-v1',
      );
      await adapter.pull(
        userId: 'user-1',
        component: SyncComponent.stable,
        contractVersion: 2,
        projectionRevision: 'schedule-zone-v1',
        merge: (_, _) async {},
      );
      expect(requests.last['afterSequence'], '11');
    },
  );

  test('a device on the older marker replays and receives details another '
      'device set', () async {
    const profileId = '10000000-0000-4000-8000-000000000a01';
    const pillId = '10000000-0000-4000-8000-000000000a02';
    final at = DateTime.utc(2026, 10, 1);
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: profileId,
        userId: 'user-1',
        name: 'P',
        createdAt: at,
        updatedAt: at,
        serverId: const Value(profileId),
        syncStatus: const Value('synced'),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: pillId,
        profileId: profileId,
        name: 'Alpha',
        createdAt: at,
        updatedAt: at,
        serverId: const Value(pillId),
        revision: const Value(1),
        syncStatus: const Value('synced'),
      ),
    );
    await db.syncStateDao.saveState(
      SyncComponentStatesCompanion.insert(
        userId: 'user-1',
        component: 'stable',
        contractVersion: 2,
        lastCompletedCursor: const Value('9'),
        lastFullSuccessAt: Value(DateTime.now().toUtc()),
        diagnosticMetadataJson: Value(
          jsonEncode({'projectionRevision': 'schedule-zone-v1'}),
        ),
      ),
    );
    final requests = <Map<String, dynamic>>[];
    when(
      () => dio.get<Map<String, dynamic>>(
        '/sync/stable',
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final query = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      requests.add(query);
      return _response(
        _page(
          afterSequence: '0',
          throughSequence: '9',
          hasMore: false,
          nextCursor: null,
          items: [
            {
              'serverSequence': '4',
              'change': {
                'schemaVersion': 2,
                'component': 'stable',
                'entityType': 'pill',
                'entityId': pillId,
                'operation': 'upsert',
                'sourceIdentity': {
                  'sourceKind': 'pill',
                  'sourceId': pillId,
                  'sourceRevision': '2',
                },
                'payload': {
                  'kind': 'pill',
                  'id': pillId,
                  'profileId': profileId,
                  'revision': '2',
                  'name': 'Alpha',
                  'dosage': null,
                  'notes': null,
                  'color': null,
                  'currentStock': null,
                  'lowStockThreshold': null,
                  'isPrn': false,
                  'deletedAt': null,
                  'createdAt': '2026-10-01T00:00:00.000Z',
                  'updatedAt': '2026-10-02T00:00:00.000Z',
                  'shape': 'capsule',
                  'expiresOn': '2027-03-01',
                  'prescriberName': 'Dr Fake',
                  'pharmacyName': 'Fake Pharmacy',
                  'prnMaxPer24h': 3,
                  'stockNeedsRecount': true,
                },
              },
            },
          ],
        ),
      );
    });
    await ComponentSyncPullAdapter(db: db, dio: dio).pull(
      userId: 'user-1',
      component: SyncComponent.stable,
      contractVersion: 2,
      projectionRevision: 'medication-details-v1',
      merge: (_, changes) async {
        final merger = StableRecordMerger(
          db,
          reviews: AccountSettlementMerger(db),
          medicationDetailsExtra: true,
        );
        for (final change in changes) {
          final payload = Map<String, dynamic>.from(
            (change as Map)['payload'] as Map,
          );
          await merger.mergePill(
            payload,
            {profileId: profileId},
            {},
            userId: 'user-1',
          );
        }
      },
    );
    expect(requests.first.containsKey('afterSequence'), isFalse);
    final pill = (await db.pillsDao.getById(pillId))!;
    expect(pill.shape, 'capsule');
    expect(pill.prescriberName, 'Dr Fake');
    expect(pill.pharmacyName, 'Fake Pharmacy');
    expect(pill.prnMaxPer24h, 3);
    expect(pill.stockNeedsRecount, isTrue);
    expect(pill.expiresOn, isNotNull);
    final state = (await db.syncStateDao.getState('user-1', 'stable'))!;
    expect(
      jsonDecode(state.diagnosticMetadataJson!)['projectionRevision'],
      'medication-details-v1',
    );
  });
}

Future<void> _seedStableCheckpoint(AppDatabase db, String sequence) async {
  await db.syncStateDao.saveState(
    SyncComponentStatesCompanion.insert(
      userId: 'user-1',
      component: 'stable',
      contractVersion: 2,
      lastCompletedCursor: Value(sequence),
      lastFullSuccessAt: Value(DateTime.now().toUtc()),
    ),
  );
}

Map<String, dynamic> _page({
  required String afterSequence,
  required String throughSequence,
  required List<Map<String, dynamic>> items,
  required bool hasMore,
  required String? nextCursor,
}) => {
  'component': 'stable',
  'contractVersion': 2,
  'afterSequence': afterSequence,
  'throughSequence': throughSequence,
  'items': items,
  'hasMore': hasMore,
  'nextCursor': nextCursor,
};

Map<String, dynamic> _change(String id) => {
  'serverSequence': id == 'profile-1' ? '6' : '7',
  'change': {
    'schemaVersion': 2,
    'component': 'stable',
    'entityType': 'profile',
    'entityId': id,
    'operation': 'upsert',
    'sourceIdentity': {
      'sourceKind': 'profile',
      'sourceId': id,
      'sourceRevision': '1',
    },
    'payload': {'kind': 'profile', 'id': id},
  },
};

Response<Map<String, dynamic>> _response(Map<String, dynamic> data) =>
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: '/sync/stable'),
      data: data,
    );
