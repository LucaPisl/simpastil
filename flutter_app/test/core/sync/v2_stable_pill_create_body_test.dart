import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000101';
const _profileId = '10000000-0000-4000-8000-000000000102';
const _pillId = '10000000-0000-4000-8000-000000000103';
const _mutationId = '10000000-0000-4000-8000-000000000104';
const _profileServerId = '10000000-0000-4000-8000-000000000105';
final _createdAt = DateTime.utc(2026, 10, 12, 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pill create omits unset optional texts and keeps one mutationId across retries',
    () async {
      final workspace = await ProtectedWorkspaceFixture.create(
        ownerId: _ownerId,
      );
      addTearDown(workspace.db.close);
      await workspace.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profileId,
          userId: _ownerId,
          name: 'Fictional person',
          createdAt: _createdAt,
          updatedAt: _createdAt,
          serverId: const Value(_profileServerId),
          syncStatus: const Value('synced'),
        ),
      );
      await workspace.db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pillId,
          profileId: _profileId,
          name: 'Fakeolol',
          dosage: const Value('10 mg'),
          createdAt: _createdAt,
          updatedAt: _createdAt,
        ),
      );
      // The same journal shape PillRepository.create records: unset optional
      // fields are explicit nulls.
      final recorded =
          await PendingOperationRepository(
            workspace.db,
            access: workspace.access,
            context: workspace.context,
          ).record(
            operation: const PendingOperationDraft(
              userId: _ownerId,
              mutationId: _mutationId,
              operationType: 'pill.create',
              entityType: 'pill',
              entityLocalId: _pillId,
              parentEntityType: 'profile',
              parentEntityLocalId: _profileId,
              payload: {
                'action': 'create',
                'data': {
                  'name': 'Fakeolol',
                  'dosage': '10 mg',
                  'notes': null,
                  'color': null,
                  'lowStockThreshold': null,
                  'isPrn': false,
                },
              },
            ),
            applyProjection: () async {},
          );
      final operation = (await workspace.db.pendingOperationsDao.getById(
        recorded.operationId,
      ))!;

      final bodies = <Map<String, dynamic>>[];
      var failFirst = true;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            bodies.add(
              Map<String, dynamic>.of(request.data as Map<String, dynamic>),
            );
            if (failFirst) {
              failFirst = false;
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 201,
                data: {'id': _pillId, 'revision': '1'},
              ),
            );
          },
        ),
      );
      final adapter = V2StableAdapter(
        db: workspace.db,
        dio: dio,
        writeScope: SyncWriteScope(
          access: workspace.access,
          capability: await workspace.access.currentNetworkCapability(),
        ),
      );

      final lost = await adapter.send(operation);
      expect(lost.status, isNot(StableMutationStatus.acknowledged));
      final retried = await adapter.send(operation);
      expect(retried.status, StableMutationStatus.acknowledged);

      expect(bodies, hasLength(2));
      expect(bodies.first, {
        'mutationId': _mutationId,
        'id': _pillId,
        'name': 'Fakeolol',
        'dosage': '10 mg',
        'lowStockThreshold': null,
        'isPrn': false,
      });
      expect(bodies.last, bodies.first);
    },
  );
}
