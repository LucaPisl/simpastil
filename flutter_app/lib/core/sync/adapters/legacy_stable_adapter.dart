import 'package:dio/dio.dart';

import '../../db/database.dart';
import 'stable_record_adapter.dart';

/// Old servers have no mutation receipt. A successful response records the
/// returned mapping but stays uncommitted until a later authenticated read
/// reconciles it; a lost response is never silently replayed.
class LegacyStableAdapter extends StableRecordAdapter {
  const LegacyStableAdapter({
    required super.db,
    required super.dio,
    super.writeScope,
  });

  @override
  bool get replayIsIdempotent => false;

  @override
  Future<StableMutationResult> send(PendingOperation operation) async {
    await writeScope?.requireOperation(operation);
    late final Map<String, Object?> payload;
    late final Map<String, Object?> data;
    try {
      payload = decodeOperation(operation);
      data = dataFrom(payload);
    } on Object {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'INVALID_STABLE_OPERATION',
      );
    }

    final entityType = payload['entityType'];
    final localId = payload['entityLocalId'];
    final action = payload['action'];
    if (entityType is! String || localId is! String || action is! String) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'INVALID_STABLE_IDENTITY',
      );
    }
    final path = await _path(payload, entityType, localId, action);
    if (path == null) {
      return const StableMutationResult(
        StableMutationStatus.blocked,
        safeErrorCode: 'STABLE_PARENT_NOT_RECONCILED',
      );
    }

    try {
      late final Response<Map<String, dynamic>> response;
      switch (action) {
        case 'create':
          response = await dio.post<Map<String, dynamic>>(
            path,
            data: _legacyBody(entityType, data),
          );
        case 'update':
          response = await dio.patch<Map<String, dynamic>>(
            path,
            data: _legacyBody(entityType, data),
          );
        case 'delete':
          response = await dio.delete<Map<String, dynamic>>(path);
        default:
          return const StableMutationResult(
            StableMutationStatus.blocked,
            safeErrorCode: 'UNKNOWN_STABLE_ACTION',
          );
      }
      final responseId = extractServerId(response.data);
      final serverId = responseId ?? await serverIdFor(entityType, localId);
      final revision = extractRevision(response.data);
      if (action != 'delete' && responseId == null) {
        return const StableMutationResult(
          StableMutationStatus.uncertain,
          safeErrorCode: 'LEGACY_RESPONSE_ID_MISSING',
        );
      }
      return StableMutationResult(
        StableMutationStatus.legacyAcceptedAwaitingReconciliation,
        serverId: serverId,
        revision: revision,
        applyReceipt: serverId == null
            ? null
            : () => markLocalReceipt(
                operation,
                entityType,
                localId,
                serverId,
                revision,
              ),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) rethrow;
      // A delete 404 is an authenticated proof that the desired absent state
      // already holds. Other 404s remain a conflict, not a receipt.
      if (action == 'delete' && error.response?.statusCode == 404) {
        final serverId = await serverIdFor(entityType, localId);
        return StableMutationResult(
          StableMutationStatus.acknowledged,
          acknowledgedMutationId: operation.mutationId,
          applyReceipt: serverId == null
              ? null
              : () => markLocalReceipt(
                  operation,
                  entityType,
                  localId,
                  serverId,
                  null,
                ),
        );
      }
      return classifyFailure(error);
    }
  }

  Future<String?> _path(
    Map<String, Object?> payload,
    String entityType,
    String localId,
    String action,
  ) async {
    if (entityType == 'profile') {
      final serverId = await serverIdFor('profile', localId);
      if (action == 'create') return '/profiles';
      if (serverId == null) return null;
      return '/profiles/$serverId';
    }
    final parentId = await parentServerId(payload);
    if (parentId == null) return null;
    if (entityType == 'pill') {
      if (action == 'create') return '/profiles/$parentId/pills';
      final serverId = await serverIdFor('pill', localId);
      return serverId == null ? null : '/profiles/$parentId/pills/$serverId';
    }
    if (entityType == 'schedule') {
      if (action == 'create') return '/pills/$parentId/schedules';
      final serverId = await serverIdFor('schedule', localId);
      return serverId == null ? null : '/pills/$parentId/schedules/$serverId';
    }
    return null;
  }

  Map<String, Object?> _legacyBody(
    String entityType,
    Map<String, Object?> data,
  ) {
    final body = Map<String, Object?>.of(data)
      ..remove('timeZone')
      ..remove('currentStock');
    if (entityType == 'schedule' && body.containsKey('frequencyDays')) {
      body['frequencyDays'] = frequencyDaysToWire(body['frequencyDays']);
    }
    return body;
  }
}
