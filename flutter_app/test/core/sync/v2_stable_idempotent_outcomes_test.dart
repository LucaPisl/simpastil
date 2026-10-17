import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000201';
const _profileId = '10000000-0000-4000-8000-000000000202';
const _mutationId = '10000000-0000-4000-8000-000000000203';
final _createdAt = DateTime.utc(2026, 10, 12, 8);

Future<(ProtectedWorkspaceFixture, PendingOperation)> _record({
  required String type,
  required String action,
  required Map<String, Object?> data,
  int? revision,
  String? serverId,
}) async {
  final workspace = await ProtectedWorkspaceFixture.create(ownerId: _ownerId);
  addTearDown(workspace.db.close);
  await workspace.db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: _profileId,
      userId: _ownerId,
      name: 'Fictional person',
      createdAt: _createdAt,
      updatedAt: _createdAt,
      serverId: Value(serverId),
      revision: Value(revision ?? 0),
      syncStatus: Value(serverId == null ? 'pending' : 'synced'),
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
          operationType: type,
          entityType: 'profile',
          entityLocalId: _profileId,
          payload: {'action': action, 'data': data},
        ),
        applyProjection: () async {},
      );
  final operation = (await workspace.db.pendingOperationsDao.getById(
    recorded.operationId,
  ))!;
  return (workspace, operation);
}

Future<V2StableAdapter> _adapter(
  ProtectedWorkspaceFixture workspace,
  void Function(RequestOptions, RequestInterceptorHandler) onRequest,
) async {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return V2StableAdapter(
    db: workspace.db,
    dio: dio,
    writeScope: SyncWriteScope(
      access: workspace.access,
      capability: await workspace.access.currentNetworkCapability(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a 204 delete is a committed delete', () async {
    final (workspace, operation) = await _record(
      type: 'profile.delete',
      action: 'delete',
      data: const {},
      revision: 3,
      serverId: _profileId,
    );
    final adapter = await _adapter(workspace, (request, handler) {
      expect(request.method, 'DELETE');
      handler.resolve(Response(requestOptions: request, statusCode: 204));
    });

    final result = await adapter.send(operation);

    expect(result.status, StableMutationStatus.acknowledged);
    expect(result.acknowledgedMutationId, _mutationId);
  });

  test(
    'CONFLICT_DUPLICATE with currentEntity adopts the existing server row',
    () async {
      final (workspace, operation) = await _record(
        type: 'profile.create',
        action: 'create',
        data: const {'name': 'Fictional person', 'avatarEmoji': 'x'},
      );
      final adapter = await _adapter(workspace, (request, handler) {
        handler.reject(
          DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: request,
              statusCode: 409,
              data: {
                'error': {
                  'code': 'CONFLICT_DUPLICATE',
                  'message': 'Entity identifier is already in use',
                  'retryable': false,
                  'correlationId': 'corr-1',
                  'details': {
                    'existingId': _profileId,
                    'currentEntity': {
                      'entityType': 'profiles',
                      'id': _profileId,
                      'revision': '4',
                      'name': 'Server name',
                      'avatarEmoji': 'y',
                      'isActive': true,
                      'deletedAt': null,
                      'updatedAt': '2026-10-13T08:00:00.000Z',
                    },
                  },
                },
              },
            ),
          ),
        );
      });

      final result = await adapter.send(operation);

      expect(result.status, StableMutationStatus.conflict);
      expect(result.safeErrorCode, 'CONFLICT_DUPLICATE');
      await result.applyReceipt!();
      final adopted = (await workspace.db.profilesDao.getById(_profileId))!;
      expect(adopted.serverId, _profileId);
      expect(adopted.revision, 4);
      expect(adopted.name, 'Server name');
      expect(adopted.syncStatus, 'synced');
      expect(adopted.isDeleted, isFalse);
    },
  );
}
