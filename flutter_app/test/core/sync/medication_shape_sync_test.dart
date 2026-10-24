import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000801';
const _profileId = '00000000-0000-4000-8000-000000000002';
const _pillId = '00000000-0000-4000-8000-000000000013';
const _mutationId = '10000000-0000-4000-8000-000000000804';
final _at = DateTime.utc(2026, 10, 17, 8);

/// The shared fixture the server tests read too: the same four change rows.
List<Map<String, dynamic>> _fixtureCases() {
  final file = File('../contracts/fixtures/pill-shape-v1.json');
  final document = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final c in document['cases'] as List<dynamic>)
      Map<String, dynamic>.from(c as Map),
  ];
}

Map<String, dynamic> _payloadOf(Map<String, dynamic> fixtureCase) =>
    Map<String, dynamic>.from((fixtureCase['change'] as Map)['payload'] as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pull', () {
    late AppDatabase db;
    late StableRecordMerger merger;

    setUp(() async {
      db = AppDatabase.forTesting();
      merger = StableRecordMerger(db, reviews: AccountSettlementMerger(db));
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: _ownerId,
          email: 'fictional@example.com',
          createdAt: _at,
          updatedAt: _at,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profileId,
          userId: _ownerId,
          name: 'Fictional person',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profileId),
          syncStatus: const Value('synced'),
        ),
      );
    });
    tearDown(() async => db.close());

    Future<void> seed({String? shape, String syncStatus = 'synced'}) =>
        db.pillsDao.upsert(
          PillsCompanion.insert(
            id: _pillId,
            profileId: _profileId,
            name: 'Magnefar',
            createdAt: _at,
            updatedAt: _at,
            serverId: const Value(_pillId),
            revision: const Value(1),
            syncStatus: Value(syncStatus),
            shape: Value(shape),
          ),
        );

    Future<String?> stored() async =>
        (await db.pillsDao.getById(_pillId))!.shape;

    Map<String, dynamic> change(String name) =>
        _payloadOf(_fixtureCases().firstWhere((c) => c['name'] == name));

    test('a pill with a shape is stored with it', () async {
      await seed();
      await merger.mergePill(change('pill-with-shape'), {}, {});
      expect(await stored(), 'softgel');
    });

    test('a server shape wins over the one on this device', () async {
      await seed(shape: 'oval');
      await merger.mergePill(change('pill-with-shape'), {}, {});
      expect(await stored(), 'softgel');
    });

    test('a change without the key leaves the device shape alone', () async {
      await seed(shape: 'oval');
      await merger.mergePill(change('pill-shape-missing'), {}, {});
      expect(await stored(), 'oval');
    });

    test('a null shape clears the stored one', () async {
      await seed(shape: 'oval');
      await merger.mergePill(change('pill-shape-null'), {}, {});
      expect(await stored(), isNull);
    });

    test('a shape from a newer server is kept and the pull succeeds', () async {
      await seed();
      await merger.mergePill(change('pill-shape-unknown-future-value'), {}, {});
      expect(await stored(), 'hexagon');
    });

    test('a pill with an unsent edit keeps its own shape', () async {
      await seed(shape: 'oval', syncStatus: 'pending');
      await merger.mergePill(change('pill-with-shape'), {}, {});
      expect(await stored(), 'oval');
    });
  });

  group('request', () {
    Future<Map<String, dynamic>> sent({
      required bool medicationShapes,
      required String action,
    }) async {
      final workspace = await ProtectedWorkspaceFixture.create(
        ownerId: _ownerId,
      );
      addTearDown(workspace.db.close);
      await workspace.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profileId,
          userId: _ownerId,
          name: 'Fictional person',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profileId),
          syncStatus: const Value('synced'),
        ),
      );
      await workspace.db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pillId,
          profileId: _profileId,
          name: 'Magnefar',
          createdAt: _at,
          updatedAt: _at,
          serverId: action == 'update'
              ? const Value(_pillId)
              : const Value.absent(),
          revision: Value(action == 'update' ? 1 : 0),
          syncStatus: const Value('pending'),
          shape: const Value('softgel'),
        ),
      );
      final recorded =
          await PendingOperationRepository(
            workspace.db,
            access: workspace.access,
            context: workspace.context,
          ).record(
            operation: PendingOperationDraft(
              userId: _ownerId,
              mutationId: _mutationId,
              operationType: 'pill.$action',
              entityType: 'pill',
              entityLocalId: _pillId,
              parentEntityType: 'profile',
              parentEntityLocalId: _profileId,
              payload: {
                'action': action,
                'data': {
                  'name': 'Magnefar',
                  'dosage': null,
                  'notes': null,
                  'color': null,
                  'lowStockThreshold': null,
                  'isPrn': false,
                  'shape': 'softgel',
                },
              },
            ),
            applyProjection: () async {},
          );
      final operation = (await workspace.db.pendingOperationsDao.getById(
        recorded.operationId,
      ))!;
      late Map<String, dynamic> body;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            body = Map<String, dynamic>.of(
              request.data as Map<String, dynamic>,
            );
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {'id': _pillId, 'revision': '2'},
              ),
            );
          },
        ),
      );
      final result = await V2StableAdapter(
        db: workspace.db,
        dio: dio,
        writeScope: SyncWriteScope(
          access: workspace.access,
          capability: await workspace.access.currentNetworkCapability(),
        ),
        medicationShapes: medicationShapes,
      ).send(operation);
      expect(result.status, StableMutationStatus.acknowledged);
      return body;
    }

    test('a server that keeps shapes receives the update with one', () async {
      final body = await sent(medicationShapes: true, action: 'update');
      expect(body['shape'], 'softgel');
    });

    test('a server that keeps shapes receives the create with one', () async {
      final body = await sent(medicationShapes: true, action: 'create');
      expect(body['shape'], 'softgel');
    });

    test('a server without the contract gets the pill without it', () async {
      final update = await sent(medicationShapes: false, action: 'update');
      expect(update.keys, isNot(contains('shape')));
      expect(update['name'], 'Magnefar');
    });

    test('a create to a server without the contract omits it too', () async {
      final create = await sent(medicationShapes: false, action: 'create');
      expect(create.keys, isNot(contains('shape')));
    });
  });
}
