import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _owner = '10000000-0000-4000-8000-000000000301';
const _profile = '10000000-0000-4000-8000-000000000302';
const _pill = '10000000-0000-4000-8000-000000000303';
const _schedule = '10000000-0000-4000-8000-000000000304';
final _at = DateTime.utc(2026, 10, 12, 8);

/// Another device deleted the entity; this device edited it offline. The
/// server answers the update with 404 plus the tombstone as `currentEntity`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> tombstone(String type, String id) => {
    'entityType': type,
    'id': id,
    'revision': '5',
    'deletedAt': '2026-10-13T08:00:00.000Z',
    'updatedAt': '2026-10-13T08:00:00.000Z',
    'name': 'Server name',
    'avatarEmoji': 'y',
    'isActive': true,
    'profileId': _profile,
    'isPrn': false,
    'hour': 9,
    'minute': 15,
    'frequency': 'daily',
    'frequencyDays': null,
  };

  Future<(ProtectedWorkspaceFixture, V2StableAdapter, PendingOperation)> setUp(
    String entityType, {
    required Object? currentEntity,
  }) async {
    final w = await ProtectedWorkspaceFixture.create(ownerId: _owner);
    addTearDown(w.db.close);
    await w.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _owner,
        name: 'Fictional person',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        revision: const Value(2),
        syncStatus: Value(entityType == 'profile' ? 'pending' : 'synced'),
      ),
    );
    await w.db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Fictional medication',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        revision: const Value(2),
        syncStatus: Value(entityType == 'pill' ? 'pending' : 'synced'),
      ),
    );
    await w.db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: _schedule,
        pillId: _pill,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_schedule),
        revision: const Value(2),
        syncStatus: Value(entityType == 'schedule' ? 'pending' : 'synced'),
      ),
    );
    final localId = switch (entityType) {
      'profile' => _profile,
      'pill' => _pill,
      _ => _schedule,
    };
    final data = switch (entityType) {
      'profile' => {'name': 'Edited offline'},
      'pill' => {'name': 'Edited offline'},
      _ => {'hour': 10},
    };
    final recorded =
        await PendingOperationRepository(
          w.db,
          access: w.access,
          context: w.context,
        ).record(
          operation: PendingOperationDraft(
            userId: _owner,
            operationType: '$entityType.update',
            entityType: entityType,
            entityLocalId: localId,
            parentEntityType: switch (entityType) {
              'pill' => 'profile',
              'schedule' => 'pill',
              _ => null,
            },
            parentEntityLocalId: switch (entityType) {
              'pill' => _profile,
              'schedule' => _pill,
              _ => null,
            },
            payload: {'action': 'update', 'data': data},
          ),
          applyProjection: () async {},
        );
    final operation = (await w.db.pendingOperationsDao.getById(
      recorded.operationId,
    ))!;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          expect(request.method, 'PATCH');
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: request,
                statusCode: 404,
                data: {
                  'error': {
                    'code': 'RESOURCE_NOT_FOUND',
                    'message': 'Resource not found',
                    'retryable': false,
                    'correlationId': 'corr-1',
                    'details': ?(currentEntity == null
                        ? null
                        : {'currentEntity': currentEntity}),
                  },
                },
              ),
            ),
          );
        },
      ),
    );
    final adapter = V2StableAdapter(
      db: w.db,
      dio: dio,
      writeScope: SyncWriteScope(
        access: w.access,
        capability: await w.access.currentNetworkCapability(),
      ),
    );
    return (w, adapter, operation);
  }

  for (final type in ['profile', 'pill', 'schedule']) {
    test('$type: update of a tombstone adopts it server-wins', () async {
      final id = switch (type) {
        'profile' => _profile,
        'pill' => _pill,
        _ => _schedule,
      };
      final (w, adapter, operation) = await setUp(
        type,
        currentEntity: tombstone('${type}s', id),
      );

      final result = await adapter.send(operation);

      expect(result.status, StableMutationStatus.conflict);
      expect(result.safeErrorCode, 'RESOURCE_NOT_FOUND');
      await result.applyReceipt!();

      final row = switch (type) {
        'profile' => await w.db.profilesDao.getById(id),
        'pill' => await w.db.pillsDao.getById(id),
        _ => await w.db.schedulesDao.getById(id),
      };
      final (isDeleted, syncStatus, rev) = switch (row) {
        Profile p => (p.isDeleted, p.syncStatus, p.revision),
        Pill p => (p.isDeleted, p.syncStatus, p.revision),
        Schedule s => (s.isDeleted, s.syncStatus, s.revision),
        _ => throw StateError('missing row'),
      };
      expect(isDeleted, isTrue);
      expect(syncStatus, 'synced');
      expect(rev, 5);
      final issues = await w.db.migrationIssuesDao.getUnresolved(_owner);
      expect(
        issues.map((i) => i.issueCode),
        contains('stable_revision_conflict_server_wins'),
      );
    });
  }

  test('a 404 without a tombstone stays blocked and edits nothing', () async {
    final (w, adapter, operation) = await setUp('pill', currentEntity: null);

    final result = await adapter.send(operation);

    expect(result.status, StableMutationStatus.blocked);
    expect(result.applyReceipt, isNull);
    final pill = (await w.db.pillsDao.getById(_pill))!;
    expect(pill.isDeleted, isFalse);
    expect(pill.syncStatus, 'pending');
  });
}
